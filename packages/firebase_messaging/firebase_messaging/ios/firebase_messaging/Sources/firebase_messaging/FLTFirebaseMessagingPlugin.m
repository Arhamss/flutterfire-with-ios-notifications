// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#import <TargetConditionals.h>

#import <GoogleUtilities/GULAppDelegateSwizzler.h>
#if __has_include(<firebase_core/FLTFirebasePluginRegistry.h>)
#import <firebase_core/FLTFirebasePluginRegistry.h>
#else
#import <FLTFirebasePluginRegistry.h>
#endif
#import <objc/message.h>

#import "FLTFirebaseMessagingPlugin.h"

#if __has_include(<FirebaseAuth/FirebaseAuth.h>)
@import FirebaseAuth;
#endif

NSString *const kFLTFirebaseMessagingChannelName = @"plugins.flutter.io/firebase_messaging";

NSString *const kMessagingArgumentCode = @"code";
NSString *const kMessagingArgumentMessage = @"message";
NSString *const kMessagingArgumentAdditionalData = @"additionalData";
NSString *const kMessagingPresentationOptionsUserDefaults =
    @"flutter_firebase_messaging_presentation_options";

@implementation FLTFirebaseMessagingPlugin {
  FlutterMethodChannel *_channel;
  NSObject<FlutterPluginRegistrar> *_registrar;
  NSData *_apnsToken;
  NSDictionary *_initialNotification;

  // Used to track if everything as been initialized before answering
  // to the initialNotification request
  BOOL _initialNotificationGathered;
  FLTFirebaseMethodCallResult *_initialNotificationResult;

  NSString *_initialNotificationID;
  NSString *_notificationOpenedAppID;
  NSString *_foregroundUniqueIdentifier;

#ifdef __FF_NOTIFICATIONS_SUPPORTED_PLATFORM
  API_AVAILABLE(ios(10), macosx(10.14))
  __weak id<UNUserNotificationCenterDelegate> _originalNotificationCenterDelegate;
  API_AVAILABLE(ios(10), macosx(10.14))
  struct {
    unsigned int willPresentNotification : 1;
    unsigned int didReceiveNotificationResponse : 1;
    unsigned int openSettingsForNotification : 1;
  } _originalNotificationCenterDelegateRespondsTo;
#endif
}

#pragma mark - FlutterPlugin

- (instancetype)initWithFlutterMethodChannel:(FlutterMethodChannel *)channel
                   andFlutterPluginRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  self = [super init];
  if (self) {
    _initialNotificationGathered = NO;
    _channel = channel;
    _registrar = registrar;
    // Application
    // Dart -> `getInitialNotification`
    // ObjC -> Initialize other delegates & observers
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(application_onDidFinishLaunchingNotification:)
#if TARGET_OS_OSX
               name:NSApplicationDidFinishLaunchingNotification
#else
               name:UIApplicationDidFinishLaunchingNotification
#endif
             object:nil];
  }
  return self;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:kFLTFirebaseMessagingChannelName
                                  binaryMessenger:[registrar messenger]];
  id instance = [[FLTFirebaseMessagingPlugin alloc] initWithFlutterMethodChannel:channel
                                                       andFlutterPluginRegistrar:registrar];
  // Register with internal FlutterFire plugin registry.
  [[FLTFirebasePluginRegistry sharedInstance] registerFirebasePlugin:instance];

  [registrar addMethodCallDelegate:instance channel:channel];
#if !TARGET_OS_OSX
  [registrar publish:instance];  // iOS only supported
#endif
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)flutterResult {
  FLTFirebaseMethodCallErrorBlock errorBlock = ^(
      NSString *_Nullable code, NSString *_Nullable message, NSDictionary *_Nullable details,
      NSError *_Nullable error) {
    if (code == nil) {
      NSDictionary *errorDetails = [self NSDictionaryForNSError:error];
      code = errorDetails[kMessagingArgumentCode];
      message = errorDetails[kMessagingArgumentMessage];
      details = errorDetails;
    } else {
      details = @{
        kMessagingArgumentCode : code,
        kMessagingArgumentMessage : message,
      };
    }

    if ([@"unknown" isEqualToString:code]) {
      NSLog(@"FLTFirebaseMessaging: An error occurred while calling method %@, errorOrNil => %@",
            call.method, [error userInfo]);
    }

    flutterResult([FLTFirebasePlugin createFlutterErrorFromCode:code
                                                        message:message
                                                optionalDetails:details
                                             andOptionalNSError:error]);
  };

  FLTFirebaseMethodCallResult *methodCallResult =
      [FLTFirebaseMethodCallResult createWithSuccess:flutterResult andErrorBlock:errorBlock];

  [self ensureAPNSTokenSetting];

  if ([@"Messaging#getInitialMessage" isEqualToString:call.method]) {
    _initialNotificationResult = methodCallResult;
    [self initialNotificationCallback];

  } else if ([@"Messaging#deleteToken" isEqualToString:call.method]) {
    [self messagingDeleteToken:call.arguments withMethodCallResult:methodCallResult];
  } else if ([@"Messaging#getAPNSToken" isEqualToString:call.method]) {
    [self messagingGetAPNSToken:call.arguments withMethodCallResult:methodCallResult];
  } else if ([@"Messaging#setForegroundNotificationPresentationOptions"
                 isEqualToString:call.method]) {
    [self messagingSetForegroundNotificationPresentationOptions:call.arguments
                                           withMethodCallResult:methodCallResult];
  } else if ([@"Messaging#getToken" isEqualToString:call.method]) {
    [self messagingGetToken:call.arguments withMethodCallResult:methodCallResult];
  } else if ([@"Messaging#getNotificationSettings" isEqualToString:call.method]) {
    if (@available(iOS 10, macOS 10.14, *)) {
      [self messagingGetNotificationSettings:call.arguments withMethodCallResult:methodCallResult];
    } else {
      // Defaults handled in Dart.
      methodCallResult.success(@{});
    }
  } else if ([@"Messaging#requestPermission" isEqualToString:call.method]) {
    if (@available(iOS 10, macOS 10.14, *)) {
      [self messagingRequestPermission:call.arguments withMethodCallResult:methodCallResult];
    } else {
      // Defaults handled in Dart.
      methodCallResult.success(@{});
    }
  } else if ([@"Messaging#setAutoInitEnabled" isEqualToString:call.method]) {
    [self messagingSetAutoInitEnabled:call.arguments withMethodCallResult:methodCallResult];
  } else if ([@"Messaging#subscribeToTopic" isEqualToString:call.method]) {
    [self messagingSubscribeToTopic:call.arguments withMethodCallResult:methodCallResult];
  } else if ([@"Messaging#unsubscribeFromTopic" isEqualToString:call.method]) {
    [self messagingUnsubscribeFromTopic:call.arguments withMethodCallResult:methodCallResult];
  } else if ([@"Messaging#startBackgroundIsolate" isEqualToString:call.method]) {
    methodCallResult.success(nil);
  } else {
    methodCallResult.success(FlutterMethodNotImplemented);
  }
}
- (void)messagingSetForegroundNotificationPresentationOptions:(id)arguments
                                         withMethodCallResult:
                                             (FLTFirebaseMethodCallResult *)result {
  NSMutableDictionary *persistedOptions = [NSMutableDictionary dictionary];
  if ([arguments[@"alert"] isEqual:@(YES)]) {
    persistedOptions[@"alert"] = @YES;
  }
  if ([arguments[@"badge"] isEqual:@(YES)]) {
    persistedOptions[@"badge"] = @YES;
  }
  if ([arguments[@"sound"] isEqual:@(YES)]) {
    persistedOptions[@"sound"] = @YES;
  }

  [[NSUserDefaults standardUserDefaults] setObject:persistedOptions
                                            forKey:kMessagingPresentationOptionsUserDefaults];
  result.success(nil);
}

#pragma mark - Firebase Messaging Delegate

- (void)messaging:(nonnull FIRMessaging *)messaging
    didReceiveRegistrationToken:(nullable NSString *)fcmToken {
  // Don't crash if the token is reset.
  if (fcmToken == nil) {
    return;
  }

  // Send to Dart.
  [_channel invokeMethod:@"Messaging#onTokenRefresh" arguments:fcmToken];

  // If the users AppDelegate implements messaging:didReceiveRegistrationToken: then call it as well
  // so we don't break other libraries.
  SEL messaging_didReceiveRegistrationTokenSelector =
      NSSelectorFromString(@"messaging:didReceiveRegistrationToken:");
  if ([[GULAppDelegateSwizzler sharedApplication].delegate
          respondsToSelector:messaging_didReceiveRegistrationTokenSelector]) {
    void (*usersDidReceiveRegistrationTokenIMP)(id, SEL, FIRMessaging *, NSString *) =
        (typeof(usersDidReceiveRegistrationTokenIMP))&objc_msgSend;
    usersDidReceiveRegistrationTokenIMP([GULAppDelegateSwizzler sharedApplication].delegate,
                                        messaging_didReceiveRegistrationTokenSelector, messaging,
                                        fcmToken);
  }
}

#pragma mark - NSNotificationCenter Observers

- (void)application_onDidFinishLaunchingNotification:(nonnull NSNotification *)notification {
  // Setup UIApplicationDelegate.
#if TARGET_OS_OSX
  NSDictionary *remoteNotification = notification.userInfo[NSApplicationLaunchUserNotificationKey];
#else
  NSDictionary *remoteNotification =
      notification.userInfo[UIApplicationLaunchOptionsRemoteNotificationKey];
#endif
  if (remoteNotification != nil) {
    // If remoteNotification exists, it is the notification that opened the app.
    _initialNotification =
        [FLTFirebaseMessagingPlugin remoteMessageUserInfoToDict:remoteNotification];
    _initialNotificationID = remoteNotification[@"gcm.message_id"];
  }
  _initialNotificationGathered = YES;
  [self initialNotificationCallback];

  [GULAppDelegateSwizzler registerAppDelegateInterceptor:self];
  [GULAppDelegateSwizzler proxyOriginalDelegateIncludingAPNSMethods];

  SEL didReceiveRemoteNotificationWithCompletionSEL =
      NSSelectorFromString(@"application:didReceiveRemoteNotification:fetchCompletionHandler:");
  if ([[GULAppDelegateSwizzler sharedApplication].delegate
          respondsToSelector:didReceiveRemoteNotificationWithCompletionSEL]) {
    // noop - user has own implementation of this method in their AppDelegate, this
    // means GULAppDelegateSwizzler will have already replaced it with a donor method
  } else {
    // add our own donor implementation of
    // application:didReceiveRemoteNotification:fetchCompletionHandler:
    Method donorMethod = class_getInstanceMethod(object_getClass(self),
                                                 didReceiveRemoteNotificationWithCompletionSEL);
    class_addMethod(object_getClass([GULAppDelegateSwizzler sharedApplication].delegate),
                    didReceiveRemoteNotificationWithCompletionSEL,
                    method_getImplementation(donorMethod), method_getTypeEncoding(donorMethod));
  }
#if !TARGET_OS_OSX
  // `[_registrar addApplicationDelegate:self];` alone doesn't work for notifications to be received
  // without the above swizzling This commit:
  // https://github.com/google/GoogleUtilities/pull/162/files#diff-6bb6d1c46632fc66405a524071cc4baca5fc6a1a6c0eefef81d8c3e2c89cbc13L520-L533
  // broke notifications which was released with firebase-ios-sdk v11.0.0
  [_registrar addApplicationDelegate:self];
#endif

  // Set UNUserNotificationCenter but preserve original delegate if necessary.
  if (@available(iOS 10.0, macOS 10.14, *)) {
    BOOL shouldReplaceDelegate = YES;
    UNUserNotificationCenter *notificationCenter =
        [UNUserNotificationCenter currentNotificationCenter];

    if (notificationCenter.delegate != nil) {
#if !TARGET_OS_OSX
      // If a UNUserNotificationCenterDelegate is set and it conforms to
      // FlutterAppLifeCycleProvider then we don't want to replace it on iOS as the earlier
      // call to `[_registrar addApplicationDelegate:self];` will automatically delegate calls
      // to this plugin. If we replace it, it will cause a stack overflow as our original
      // delegate forwarding handler below causes an infinite loop of forwarding. See
      // https://github.com/firebasefire/issues/4026.
      if ([notificationCenter.delegate conformsToProtocol:@protocol(FlutterAppLifeCycleProvider)]) {
        // Note this one only executes if Firebase swizzling is **enabled**.
        shouldReplaceDelegate = NO;
      }
#endif

      if (shouldReplaceDelegate) {
        _originalNotificationCenterDelegate = notificationCenter.delegate;
        _originalNotificationCenterDelegateRespondsTo.openSettingsForNotification =
            (unsigned int)[_originalNotificationCenterDelegate
                respondsToSelector:@selector(userNotificationCenter:openSettingsForNotification:)];
        _originalNotificationCenterDelegateRespondsTo.willPresentNotification =
            (unsigned int)[_originalNotificationCenterDelegate
                respondsToSelector:@selector(userNotificationCenter:
                                            willPresentNotification:withCompletionHandler:)];
        _originalNotificationCenterDelegateRespondsTo.didReceiveNotificationResponse =
            (unsigned int)[_originalNotificationCenterDelegate
                respondsToSelector:@selector(userNotificationCenter:
                                       didReceiveNotificationResponse:withCompletionHandler:)];
      }
    }

    if (shouldReplaceDelegate) {
      __strong FLTFirebasePlugin<UNUserNotificationCenterDelegate> *strongSelf = self;
      notificationCenter.delegate = strongSelf;
    }
  }

  // We automatically register for remote notifications as
  // application:didReceiveRemoteNotification:fetchCompletionHandler: will not get called unless
  // registerForRemoteNotifications is called early on during app initialization, calling this from
  // Dart would be too late.
#if TARGET_OS_OSX
  if (@available(macOS 10.14, *)) {
    [[NSApplication sharedApplication] registerForRemoteNotifications];
  }
#else
  [[UIApplication sharedApplication] registerForRemoteNotifications];
#endif
}

#pragma mark - UNUserNotificationCenter Delegate Methods

#ifdef __FF_NOTIFICATIONS_SUPPORTED_PLATFORM
// Called when a notification is received whilst the app is in the foreground.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:
             (void (^)(UNNotificationPresentationOptions options))completionHandler
    API_AVAILABLE(macos(10.14), ios(10.0)) {
  NSString *notificationIdentifier = notification.request.identifier;


    NSDictionary *notificationDict =
        [FLTFirebaseMessagingPlugin NSDictionaryFromUNNotification:notification];
    [_channel invokeMethod:@"Messaging#onMessage" arguments:notificationDict];


  // Forward on to any other delegates and allow them to control presentation behavior.
  if (_originalNotificationCenterDelegate != nil &&
      _originalNotificationCenterDelegateRespondsTo.willPresentNotification) {
    [_originalNotificationCenterDelegate userNotificationCenter:center
                                        willPresentNotification:notification
                                          withCompletionHandler:completionHandler];
  } else {
    UNNotificationPresentationOptions presentationOptions = UNNotificationPresentationOptionNone;
    NSDictionary *persistedOptions = [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:kMessagingPresentationOptionsUserDefaults];
    if (persistedOptions != nil) {
      if ([persistedOptions[@"alert"] isEqual:@(YES)]) {
        presentationOptions |= UNNotificationPresentationOptionAlert;
      }
      if ([persistedOptions[@"badge"] isEqual:@(YES)]) {
        presentationOptions |= UNNotificationPresentationOptionBadge;
      }
      if ([persistedOptions[@"sound"] isEqual:@(YES)]) {
        presentationOptions |= UNNotificationPresentationOptionSound;
      }
    }
    completionHandler(presentationOptions);
  }
  _foregroundUniqueIdentifier = notificationIdentifier;
}

// Called when a user interacts with a notification.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler
    API_AVAILABLE(macos(10.14), ios(10.0)) {
  NSDictionary *remoteNotification = response.notification.request.content.userInfo;

  // Always store the notification identifier for tap detection
  _notificationOpenedAppID = response.notification.request.identifier;

  // Convert to dictionary and ensure it has a messageId
  NSDictionary *notificationDict =
      [FLTFirebaseMessagingPlugin remoteMessageUserInfoToDict:remoteNotification];

  // Always trigger onMessageOpenedApp for any notification interaction
  [_channel invokeMethod:@"Messaging#onMessageOpenedApp" arguments:notificationDict];

  // Forward on to any other delegates.
  if (_originalNotificationCenterDelegate != nil &&
      _originalNotificationCenterDelegateRespondsTo.didReceiveNotificationResponse) {
    [_originalNotificationCenterDelegate userNotificationCenter:center
                                 didReceiveNotificationResponse:response
                                          withCompletionHandler:completionHandler];
  } else {
    completionHandler();
  }
}

// We don't use this for FlutterFire, but for the purpose of forwarding to any original delegates we
// implement this.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    openSettingsForNotification:(nullable UNNotification *)notification
    API_AVAILABLE(macos(10.14), ios(10.0)) {
  // Forward on to any other delegates.
  if (_originalNotificationCenterDelegate != nil &&
      _originalNotificationCenterDelegateRespondsTo.openSettingsForNotification) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    [_originalNotificationCenterDelegate userNotificationCenter:center
                                    openSettingsForNotification:notification];
#pragma clang diagnostic pop
  }
}

#endif

#pragma mark - AppDelegate Methods

#if TARGET_OS_OSX
// Called when `registerForRemoteNotifications` completes successfully.
- (void)application:(NSApplication *)application
    didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
#else
- (void)application:(UIApplication *)application
    didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
#endif
  if ([FIRMessaging messaging] == nil) {
    _apnsToken = deviceToken;
  }
#ifdef DEBUG
  [[FIRMessaging messaging] setAPNSToken:deviceToken type:FIRMessagingAPNSTokenTypeSandbox];
#else
  [[FIRMessaging messaging] setAPNSToken:deviceToken type:FIRMessagingAPNSTokenTypeProd];
#endif
}

#if TARGET_OS_OSX
// Called when `registerForRemoteNotifications` fails to complete.
- (void)application:(NSApplication *)application
    didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
#else
- (void)application:(UIApplication *)application
    didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
#endif
  NSLog(@"%@", error.localizedDescription);
}

// Called when a remote notification is received via APNs.
#if TARGET_OS_OSX
- (void)application:(NSApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo {
  NSDictionary *notificationDict =
      [FLTFirebaseMessagingPlugin remoteMessageUserInfoToDict:userInfo];

  [_channel invokeMethod:@"Messaging#onMessage" arguments:notificationDict];

  if (![NSApplication sharedApplication].isActive){
    [_channel invokeMethod:@"Messaging#onBackgroundMessage" arguments:notificationDict];
  }
}
#endif

#if !TARGET_OS_OSX
// Called for silent messages (i.e. data only) in the foreground & background
- (BOOL)application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
          fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler {
#if __has_include(<FirebaseAuth/FirebaseAuth.h>)
  if ([FIRApp defaultApp] != nil && [[FIRAuth auth] canHandleNotification:userInfo]) {
    completionHandler(UIBackgroundFetchResultNoData);
    return YES;
  }
#endif
  NSDictionary *notificationDict =
      [FLTFirebaseMessagingPlugin remoteMessageUserInfoToDict:userInfo];

  UIApplicationState state = [UIApplication sharedApplication].applicationState;

  // Handle notification taps for all notification types (FCM, APNS, Sendbird, etc.)
  if (state == UIApplicationStateInactive || state == UIApplicationStateBackground) {
    // Store a unique identifier for this notification
    _notificationOpenedAppID = [[NSUUID UUID] UUIDString];
    // Always trigger onMessageOpenedApp for any notification tap
    [_channel invokeMethod:@"Messaging#onMessageOpenedApp" arguments:notificationDict];
    completionHandler(UIBackgroundFetchResultNewData);
    return YES;
  }

  // Handle messages based on application state
  if (state == UIApplicationStateBackground) {
    [_channel invokeMethod:@"Messaging#onBackgroundMessage" arguments:notificationDict];
    completionHandler(UIBackgroundFetchResultNewData);
  } else {
    [_channel invokeMethod:@"Messaging#onMessage" arguments:notificationDict];
    completionHandler(UIBackgroundFetchResultNoData);
  }

  return YES;
}  // didReceiveRemoteNotification
#endif

#pragma mark - Firebase Messaging API

- (void)messagingUnsubscribeFromTopic:(id)arguments
                 withMethodCallResult:(FLTFirebaseMethodCallResult *)result {
  FIRMessaging *messaging = [FIRMessaging messaging];
  NSString *topic = arguments[@"topic"];
  [messaging unsubscribeFromTopic:topic
                       completion:^(NSError *error) {
                         if (error != nil) {
                           result.error(nil, nil, nil, error);
                         } else {
                           result.success(nil);
                         }
                       }];
}

- (void)messagingSubscribeToTopic:(id)arguments
             withMethodCallResult:(FLTFirebaseMethodCallResult *)result {
  FIRMessaging *messaging = [FIRMessaging messaging];
  NSString *topic = arguments[@"topic"];
  [messaging subscribeToTopic:topic
                   completion:^(NSError *error) {
                     if (error != nil) {
                       result.error(nil, nil, nil, error);
                     } else {
                       result.success(nil);
                     }
                   }];
}

- (void)messagingSetAutoInitEnabled:(id)arguments
               withMethodCallResult:(FLTFirebaseMethodCallResult *)result {
  FIRMessaging *messaging = [FIRMessaging messaging];
  messaging.autoInitEnabled = [arguments[@"enabled"] boolValue];
  result.success(@{
    @"isAutoInitEnabled" : @(messaging.isAutoInitEnabled),
  });
}

- (void)messagingRequestPermission:(id)arguments
              withMethodCallResult:(FLTFirebaseMethodCallResult *)result
    API_AVAILABLE(ios(10), macosx(10.14)) {
  NSDictionary *permissions = arguments[@"permissions"];
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];

  UNAuthorizationOptions options = UNAuthorizationOptionNone;

  if ([permissions[@"alert"] isEqual:@(YES)]) {
    options |= UNAuthorizationOptionAlert;
  }

  if ([permissions[@"badge"] isEqual:@(YES)]) {
    options |= UNAuthorizationOptionBadge;
  }

  if ([permissions[@"sound"] isEqual:@(YES)]) {
    options |= UNAuthorizationOptionSound;
  }

  if ([permissions[@"provisional"] isEqual:@(YES)]) {
    if (@available(iOS 12.0, *)) {
      options |= UNAuthorizationOptionProvisional;
    }
  }

  if ([permissions[@"announcement"] isEqual:@(YES)]) {
    if (@available(iOS 13.0, *)) {
      // TODO not available in iOS9 deployment target - enable once iOS10+ deployment target
      // specified in podspec. options |= UNAuthorizationOptionAnnouncement;
    }
  }

  if ([permissions[@"carPlay"] isEqual:@(YES)]) {
    options |= UNAuthorizationOptionCarPlay;
  }

  if ([permissions[@"criticalAlert"] isEqual:@(YES)]) {
    if (@available(iOS 12.0, *)) {
      options |= UNAuthorizationOptionCriticalAlert;
    }
  }

  id handler = ^(BOOL granted, NSError *_Nullable error) {
    if (error != nil) {
      result.error(nil, nil, nil, error);
    } else {
      [center getNotificationSettingsWithCompletionHandler:^(
                  UNNotificationSettings *_Nonnull settings) {
        result.success(
            [FLTFirebaseMessagingPlugin NSDictionaryFromUNNotificationSettings:settings]);
      }];
    }
  };

  [center requestAuthorizationWithOptions:options completionHandler:handler];
}

- (void)messagingGetNotificationSettings:(id)arguments
                    withMethodCallResult:(FLTFirebaseMethodCallResult *)result
    API_AVAILABLE(ios(10), macos(10.14)) {
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center getNotificationSettingsWithCompletionHandler:^(
              UNNotificationSettings *_Nonnull settings) {
    result.success([FLTFirebaseMessagingPlugin NSDictionaryFromUNNotificationSettings:settings]);
  }];
}

- (void)messagingGetToken:(id)arguments withMethodCallResult:(FLTFirebaseMethodCallResult *)result {
  FIRMessaging *messaging = [FIRMessaging messaging];

  // Keep behavior consistent with android platform, newly retrieved tokens are streamed via
  // onTokenRefresh
  bool refreshToken = messaging.FCMToken == nil ? YES : NO;
  [messaging tokenWithCompletion:^(NSString *_Nullable token, NSError *_Nullable error) {
    if (error != nil) {
      result.error(nil, nil, nil, error);
    } else {
      if (refreshToken) {
        [self->_channel invokeMethod:@"Messaging#onTokenRefresh" arguments:token];
      }

      result.success(@{@"token" : token});
    }
  }];
}

- (void)messagingGetAPNSToken:(id)arguments
         withMethodCallResult:(FLTFirebaseMethodCallResult *)result {
  NSData *apnsToken = [FIRMessaging messaging].APNSToken;
  if (apnsToken) {
    result.success(@{@"token" : [FLTFirebaseMessagingPlugin APNSTokenFromNSData:apnsToken]});
  } else {
    result.success(@{@"token" : [NSNull null]});
  }
}

- (void)messagingDeleteToken:(id)arguments
        withMethodCallResult:(FLTFirebaseMethodCallResult *)result {
  FIRMessaging *messaging = [FIRMessaging messaging];
  [messaging deleteTokenWithCompletion:^(NSError *_Nullable error) {
    if (error != nil) {
      result.error(nil, nil, nil, error);
    } else {
      result.success(nil);
    }
  }];
}

#pragma mark - FLTFirebasePlugin

- (void)didReinitializeFirebaseCore:(void (^)(void))completion {
  completion();
}

- (NSDictionary *_Nonnull)pluginConstantsForFIRApp:(FIRApp *)firebase_app {
  return @{
    @"AUTO_INIT_ENABLED" : @([FIRMessaging messaging].isAutoInitEnabled),
  };
}

- (NSString *_Nonnull)firebaseLibraryName {
  return @LIBRARY_NAME;
}

- (NSString *_Nonnull)firebaseLibraryVersion {
  return @LIBRARY_VERSION;
}

- (NSString *_Nonnull)flutterChannelName {
  return kFLTFirebaseMessagingChannelName;
}

#pragma mark - Utilities

+ (NSDictionary *)NSDictionaryFromUNNotificationSettings:(UNNotificationSettings *_Nonnull)settings
    API_AVAILABLE(ios(10), macos(10.14)) {
  NSMutableDictionary *settingsDictionary = [NSMutableDictionary dictionary];

  // authorizedStatus
  NSNumber *authorizedStatus = @-1;
  if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
    authorizedStatus = @-1;
  } else if (settings.authorizationStatus == UNAuthorizationStatusDenied) {
    authorizedStatus = @0;
  } else if (settings.authorizationStatus == UNAuthorizationStatusAuthorized) {
    authorizedStatus = @1;
  }

  if (@available(iOS 12.0, *)) {
    if (settings.authorizationStatus == UNAuthorizationStatusProvisional) {
      authorizedStatus = @2;
    }
  }

  NSNumber *timeSensitive = @-1;
  if (@available(iOS 15.0, macOS 12.0, *)) {
    if (settings.timeSensitiveSetting == UNNotificationSettingDisabled) {
      timeSensitive = @0;
    }
    if (settings.timeSensitiveSetting == UNNotificationSettingEnabled) {
      timeSensitive = @1;
    }
  }

  NSNumber *showPreviews = @-1;
  if (@available(iOS 11.0, *)) {
    if (settings.showPreviewsSetting == UNShowPreviewsSettingNever) {
      showPreviews = @0;
    } else if (settings.showPreviewsSetting == UNShowPreviewsSettingAlways) {
      showPreviews = @1;
    } else if (settings.showPreviewsSetting == UNShowPreviewsSettingWhenAuthenticated) {
      showPreviews = @2;
    }
  }

#pragma clang diagnostic push
#pragma ide diagnostic ignored "OCSimplifyInspectionLegacy"
  if (@available(iOS 13.0, *)) {
    // TODO not available in iOS9 deployment target - enable once iOS10+ deployment target specified
    // in podspec. settingsDictionary[@"announcement"] =
    //   [FLTFirebaseMessagingPlugin NSNumberForUNNotificationSetting:settings.announcementSetting];
    settingsDictionary[@"announcement"] = @-1;
  } else {
    settingsDictionary[@"announcement"] = @-1;
  }
#pragma clang diagnostic pop

  if (@available(iOS 12.0, *)) {
    settingsDictionary[@"criticalAlert"] =
        [FLTFirebaseMessagingPlugin NSNumberForUNNotificationSetting:settings.criticalAlertSetting];
  } else {
    settingsDictionary[@"criticalAlert"] = @-1;
  }

  settingsDictionary[@"showPreviews"] = showPreviews;
  settingsDictionary[@"authorizationStatus"] = authorizedStatus;
  settingsDictionary[@"alert"] =
      [FLTFirebaseMessagingPlugin NSNumberForUNNotificationSetting:settings.alertSetting];
  settingsDictionary[@"badge"] =
      [FLTFirebaseMessagingPlugin NSNumberForUNNotificationSetting:settings.badgeSetting];
  settingsDictionary[@"sound"] =
      [FLTFirebaseMessagingPlugin NSNumberForUNNotificationSetting:settings.soundSetting];
#if TARGET_OS_OSX
  settingsDictionary[@"carPlay"] = @-1;
#else
  settingsDictionary[@"carPlay"] =
      [FLTFirebaseMessagingPlugin NSNumberForUNNotificationSetting:settings.carPlaySetting];
#endif
  settingsDictionary[@"lockScreen"] =
      [FLTFirebaseMessagingPlugin NSNumberForUNNotificationSetting:settings.lockScreenSetting];
  settingsDictionary[@"notificationCenter"] = [FLTFirebaseMessagingPlugin
      NSNumberForUNNotificationSetting:settings.notificationCenterSetting];
  settingsDictionary[@"timeSensitive"] = timeSensitive;

  return settingsDictionary;
}

+ (NSNumber *)NSNumberForUNNotificationSetting:(UNNotificationSetting)setting
    API_AVAILABLE(ios(10), macos(10.14)) {
  NSNumber *asNumber = @-1;

  if (setting == UNNotificationSettingNotSupported) {
    asNumber = @-1;
  } else if (setting == UNNotificationSettingDisabled) {
    asNumber = @0;
  } else if (setting == UNNotificationSettingEnabled) {
    asNumber = @1;
  }
  return asNumber;
}

+ (NSString *)APNSTokenFromNSData:(NSData *)tokenData {
  const char *data = [tokenData bytes];

  NSMutableString *token = [NSMutableString string];
  for (NSInteger i = 0; i < tokenData.length; i++) {
    [token appendFormat:@"%02.2hhX", data[i]];
  }

  return [token copy];
}

#if TARGET_OS_OSX
+ (NSDictionary *)NSDictionaryFromUNNotification:(UNNotification *)notification
    API_AVAILABLE(macos(10.14)) {
#else
+ (NSDictionary *)NSDictionaryFromUNNotification:(UNNotification *)notification {
#endif
  return [self remoteMessageUserInfoToDict:notification.request.content.userInfo];
}

+ (NSDictionary *)remoteMessageUserInfoToDict:(NSDictionary *)userInfo {
  NSMutableDictionary *message = [[NSMutableDictionary alloc] init];
  NSMutableDictionary *data = [[NSMutableDictionary alloc] init];
  NSMutableDictionary *notification = [[NSMutableDictionary alloc] init];
  NSMutableDictionary *notificationIOS = [[NSMutableDictionary alloc] init];

  // message.messageId - try different possible keys for message ID
  NSString *messageId = userInfo[@"gcm.message_id"] ?:
                       userInfo[@"google.message_id"] ?:
                       userInfo[@"message_id"];

  if (messageId == nil) {
    // Generate a unique ID for non-FCM notifications (like Sendbird APNS)
    messageId = [[NSUUID UUID] UUIDString];
  }
  message[@"messageId"] = messageId;

  // For non-FCM notifications (like Sendbird), copy all data except reserved keys
  NSSet *reservedKeys = [NSSet setWithArray:@[@"aps", @"gcm.message_id", @"google.message_id", @"message_id"]];

  // First copy all data including nested dictionaries
  [userInfo enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
    if (![reservedKeys containsObject:key]) {
      // Ensure the value is JSON serializable
      if ([value isKindOfClass:[NSString class]] ||
          [value isKindOfClass:[NSNumber class]] ||
          [value isKindOfClass:[NSArray class]] ||
          [value isKindOfClass:[NSDictionary class]] ||
          [value isKindOfClass:[NSNull class]]) {
        data[key] = value;
      } else {
        data[key] = [value description];
      }
    }
  }];

  message[@"data"] = data;

  // Handle notification content from aps dictionary
  if (userInfo[@"aps"] != nil) {
    NSDictionary *apsDict = userInfo[@"aps"];

    // Handle alert content
    id alert = apsDict[@"alert"];
    if (alert != nil) {
      if ([alert isKindOfClass:[NSString class]]) {
        notification[@"title"] = alert;
        notification[@"body"] = alert;
      } else if ([alert isKindOfClass:[NSDictionary class]]) {
        NSDictionary *alertDict = (NSDictionary *)alert;
        if (alertDict[@"title"] != nil) notification[@"title"] = alertDict[@"title"];
        if (alertDict[@"body"] != nil) notification[@"body"] = alertDict[@"body"];
        if (alertDict[@"subtitle"] != nil) notificationIOS[@"subtitle"] = alertDict[@"subtitle"];
      }
    }

    // Handle other aps content
    if (apsDict[@"badge"] != nil) notificationIOS[@"badge"] = [NSString stringWithFormat:@"%@", apsDict[@"badge"]];
    if (apsDict[@"sound"] != nil) {
      if ([apsDict[@"sound"] isKindOfClass:[NSString class]]) {
        notificationIOS[@"sound"] = @{
          @"name" : apsDict[@"sound"],
          @"critical" : @NO,
          @"volume" : @1,
        };
      }
    }

    // For data-only notifications (like Sendbird), copy all aps content to data
    [apsDict enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
      if (![key isEqualToString:@"alert"] &&
          ![key isEqualToString:@"badge"] &&
          ![key isEqualToString:@"sound"]) {
        // Add aps_ prefix to avoid conflicts
        data[[@"aps_" stringByAppendingString:key]] = value;
      }
    }];
  }

  notification[@"apple"] = notificationIOS;
  message[@"notification"] = notification;

  // For data-only notifications, ensure we have at least an empty notification object
  if ([notification count] == 0) {
    message[@"notification"] = @{@"apple": @{}};
  }

  return message;
}

- (void)ensureAPNSTokenSetting {
  FIRMessaging *messaging = [FIRMessaging messaging];

  if (messaging.APNSToken == nil && _apnsToken != nil) {
#ifdef DEBUG
    [[FIRMessaging messaging] setAPNSToken:_apnsToken type:FIRMessagingAPNSTokenTypeSandbox];
#else
    [[FIRMessaging messaging] setAPNSToken:_apnsToken type:FIRMessagingAPNSTokenTypeProd];
#endif
    _apnsToken = nil;
  }
}

- (nullable NSDictionary *)copyInitialNotification {
  @synchronized(self) {
    // Only return if initial notification was sent when app is terminated. Also ensure that
    // it was the initial notification that was tapped to open the app.
    if (_initialNotification != nil &&
        [_initialNotificationID isEqualToString:_notificationOpenedAppID]) {
      NSDictionary *initialNotificationCopy = [_initialNotification copy];
      _initialNotification = nil;
      return initialNotificationCopy;
    }
  }

  return nil;
}

- (void)initialNotificationCallback {
  if (_initialNotificationGathered && _initialNotificationResult != nil) {
    _initialNotificationResult.success([self copyInitialNotification]);
    _initialNotificationResult = nil;
  }
}

- (NSDictionary *)NSDictionaryForNSError:(NSError *)error {
  NSString *code = @"unknown";
  NSString *message = @"An unknown error has occurred.";

  if (error == nil) {
    return @{
      kMessagingArgumentCode : code,
      kMessagingArgumentMessage : message,
    };
  }

  // code - codes from taken from NSError+FIRMessaging.h
  if (error.code == 4) {
    code = @"unavailable";
  } else if (error.code == 7) {
    code = @"invalid-request";
  } else if (error.code == 8) {
    code = @"invalid-argument";
  } else if (error.code == 501) {
    code = @"missing-device-id";
  } else if (error.code == 1001) {
    code = @"unavailable";
  } else if (error.code == 1003) {
    code = @"invalid-argument";
  } else if (error.code == 1004) {
    code = @"save-failed";
  } else if (error.code == 1005) {
    code = @"invalid-argument";
  } else if (error.code == 2001) {
    code = @"already-connected";
  } else if (error.code == 3005) {
    code = @"pubsub-operation-cancelled";
  }

  // message
  if ([error userInfo][NSLocalizedDescriptionKey] != nil) {
    message = [error userInfo][NSLocalizedDescriptionKey];
  }

  return @{
    kMessagingArgumentCode : code,
    kMessagingArgumentMessage : message,
  };
}

@end
