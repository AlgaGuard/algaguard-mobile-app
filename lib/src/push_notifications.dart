import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'environment.dart';
import 'platform_clients.dart';

enum PushNotificationState {
  disabled,
  requestingPermission,
  registered,
  permissionDenied,
  unavailable,
}

abstract interface class PushMessaging {
  Future<void> initialize();
  Future<bool> requestPermission();
  Future<String?> token();
  Stream<String> get tokenRefresh;
  Stream<String> get foregroundAlerts;
  Future<void> deleteToken();
}

class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging(this.environment);

  final FcmEnvironment environment;

  @override
  Future<void> initialize() async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  }

  @override
  Future<bool> requestPermission() async {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      announcement: false,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
    );
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<String?> token() => FirebaseMessaging.instance.getToken();

  @override
  Stream<String> get tokenRefresh => FirebaseMessaging.instance.onTokenRefresh;

  @override
  Stream<String> get foregroundAlerts => FirebaseMessaging.onMessage
      .where((message) => message.data['type'] == 'THRESHOLD_ALERT')
      .map((_) => 'An assigned algae profile threshold was breached.');

  @override
  Future<void> deleteToken() => FirebaseMessaging.instance.deleteToken();
}

class PushNotificationController extends ChangeNotifier {
  PushNotificationController({
    required this.enabled,
    required this.messaging,
    required this.store,
    required this.api,
    required this.accessToken,
  });

  final bool enabled;
  final PushMessaging messaging;
  final TokenStore store;
  final PlatformApi api;
  final Future<String?> Function() accessToken;

  PushNotificationState state = PushNotificationState.disabled;
  String? foregroundAlert;
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<String>? _foregroundSubscription;
  bool _working = false;

  Future<void> activate() async {
    if (!enabled || _working || state == PushNotificationState.registered) {
      return;
    }
    _working = true;
    state = PushNotificationState.requestingPermission;
    notifyListeners();
    try {
      await messaging.initialize();
      if (!await messaging.requestPermission()) {
        state = PushNotificationState.permissionDenied;
        return;
      }
      final registrationToken = await messaging.token();
      final bearer = await accessToken();
      if (!_validRegistrationToken(registrationToken) || bearer == null) {
        state = PushNotificationState.unavailable;
        return;
      }
      await _register(registrationToken!, bearer);
      await _tokenSubscription?.cancel();
      _tokenSubscription = messaging.tokenRefresh.listen((token) {
        unawaited(_rotate(token));
      });
      await _foregroundSubscription?.cancel();
      _foregroundSubscription = messaging.foregroundAlerts.listen((message) {
        foregroundAlert = message;
        notifyListeners();
      });
      state = PushNotificationState.registered;
    } catch (_) {
      state = PushNotificationState.unavailable;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  void clearForegroundAlert() {
    foregroundAlert = null;
    notifyListeners();
  }

  Future<void> _rotate(String registrationToken) async {
    if (!_validRegistrationToken(registrationToken)) return;
    final bearer = await accessToken();
    if (bearer == null) return;
    try {
      await _register(registrationToken, bearer);
    } catch (_) {
      state = PushNotificationState.unavailable;
      notifyListeners();
    }
  }

  Future<void> _register(String registrationToken, String bearer) async {
    await api.registerPushInstallation(
      accessToken: bearer,
      installationId: await store.readOrCreatePushInstallationId(),
      registrationToken: registrationToken,
    );
  }

  Future<void> deactivate() async {
    await _tokenSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    final installationId = await store.readPushInstallationId();
    final bearer = await accessToken();
    if (installationId != null && bearer != null) {
      try {
        await api.unregisterPushInstallation(
          accessToken: bearer,
          installationId: installationId,
        );
      } catch (_) {
        // Server registrations expire and are invalidated by FCM; logout must
        // still complete when the network is temporarily unavailable.
      }
    }
    try {
      await messaging.deleteToken();
    } catch (_) {
      // Local authentication cleanup remains authoritative.
    }
    await store.clearPushInstallationId();
    state = enabled
        ? PushNotificationState.unavailable
        : PushNotificationState.disabled;
    foregroundAlert = null;
    notifyListeners();
  }

  bool _validRegistrationToken(String? value) =>
      value != null &&
      value.length >= 32 &&
      value.length <= 4096 &&
      !RegExp(r'\s').hasMatch(value);

  @override
  void dispose() {
    _tokenSubscription?.cancel();
    _foregroundSubscription?.cancel();
    super.dispose();
  }
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final environment = FcmEnvironment.fromDefines();
  if (!environment.enabled) return;
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
  // Notification payload rendering is handled by Android/FCM. Never log data.
}

Future<void> registerFirebaseBackgroundHandler(
  FcmEnvironment environment,
) async {
  if (!environment.enabled) return;
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
}
