import 'dart:async';

import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:algaguard_mobile_app/src/push_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMessaging implements PushMessaging {
  FakeMessaging({this.permission = true, this.currentToken = tokenValue});

  static const tokenValue =
      'synthetic-fcm-registration-token-with-safe-test-length';
  final bool permission;
  final String? currentToken;
  final refreshes = StreamController<String>.broadcast();
  final alerts = StreamController<String>.broadcast();
  var initialized = 0;
  var deleted = 0;

  @override
  Future<void> initialize() async => initialized += 1;
  @override
  Future<bool> requestPermission() async => permission;
  @override
  Future<String?> token() async => currentToken;
  @override
  Stream<String> get tokenRefresh => refreshes.stream;
  @override
  Stream<String> get foregroundAlerts => alerts.stream;
  @override
  Future<void> deleteToken() async => deleted += 1;
}

class RecordingPushApi extends PlatformApi {
  RecordingPushApi() : super(Uri.parse('https://api.example.test/v1'));

  final registrations = <String>[];
  final removals = <String>[];

  @override
  Future<void> registerPushInstallation({
    required String accessToken,
    required String installationId,
    required String registrationToken,
  }) async {
    expect(accessToken, 'access');
    expect(registrationToken, isNot(contains(RegExp(r'\s'))));
    registrations.add('$installationId:$registrationToken');
  }

  @override
  Future<void> unregisterPushInstallation({
    required String accessToken,
    required String installationId,
  }) async {
    expect(accessToken, 'access');
    removals.add(installationId);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'permission grant registers and token rotation replaces installation',
    () async {
      final messaging = FakeMessaging();
      final api = RecordingPushApi();
      final controller = PushNotificationController(
        enabled: true,
        messaging: messaging,
        store: const TokenStore(FlutterSecureStorage()),
        api: api,
        accessToken: () async => 'access',
      );
      await controller.activate();
      expect(controller.state, PushNotificationState.registered);
      expect(api.registrations.length, 1);
      final installation = api.registrations.single.split(':').first;

      messaging.refreshes.add(
        'rotated-registration-token-with-safe-test-length',
      );
      await Future<void>.delayed(Duration.zero);
      expect(api.registrations.length, 2);
      expect(api.registrations.last.startsWith('$installation:'), true);

      await controller.deactivate();
      expect(api.removals, [installation]);
      expect(messaging.deleted, 1);
      controller.dispose();
      await messaging.refreshes.close();
      await messaging.alerts.close();
    },
  );

  test('denied notification permission never registers an FCM token', () async {
    final messaging = FakeMessaging(permission: false);
    final api = RecordingPushApi();
    final controller = PushNotificationController(
      enabled: true,
      messaging: messaging,
      store: const TokenStore(FlutterSecureStorage()),
      api: api,
      accessToken: () async => 'access',
    );
    await controller.activate();
    expect(controller.state, PushNotificationState.permissionDenied);
    expect(api.registrations, isEmpty);
    controller.dispose();
    await messaging.refreshes.close();
    await messaging.alerts.close();
  });

  test(
    'compile-time disabled FCM performs no provider or network action',
    () async {
      final messaging = FakeMessaging();
      final api = RecordingPushApi();
      final controller = PushNotificationController(
        enabled: false,
        messaging: messaging,
        store: const TokenStore(FlutterSecureStorage()),
        api: api,
        accessToken: () async => 'access',
      );
      await controller.activate();
      expect(controller.state, PushNotificationState.disabled);
      expect(messaging.initialized, 0);
      expect(api.registrations, isEmpty);
      controller.dispose();
      await messaging.refreshes.close();
      await messaging.alerts.close();
    },
  );
}
