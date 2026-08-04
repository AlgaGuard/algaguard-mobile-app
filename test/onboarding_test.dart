import 'dart:convert';
import 'package:algaguard_mobile_app/src/ble_provisioning_wire.dart';
import 'package:algaguard_mobile_app/src/onboarding.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBle implements BleProvisioner {
  String? receivedPassword;
  String? receivedSessionToken;
  String? receivedBindingGrant;
  @override
  Future<void> provision({
    required String serviceId,
    required String sessionId,
    required String deviceId,
    required String sessionToken,
    required String ssid,
    required String password,
    String? bindingGrant,
    void Function(SafeProvisioningStatus status)? onStatus,
  }) async {
    receivedPassword = password;
    receivedSessionToken = sessionToken;
    receivedBindingGrant = bindingGrant;
  }
}

class FailingBle implements BleProvisioner {
  @override
  Future<void> provision({
    required String serviceId,
    required String sessionId,
    required String deviceId,
    required String sessionToken,
    required String ssid,
    required String password,
    String? bindingGrant,
    void Function(SafeProvisioningStatus status)? onStatus,
  }) => Future<void>.error(StateError('wrong service UUID'));
}

void main() {
  final raw = jsonEncode({
    'schema': 'algaguard.device.setup',
    'schemaVersion': '1.0.0',
    'deviceId': 'AG-000001',
    'claimCode': 'one-time',
    'bootstrapUrl': 'https://api.example/bootstrap',
    'environment': 'development',
    'bleServiceId': 'service',
    'expiresAt': '2030-01-01T00:00:00Z',
  });
  test('QR validation rejects forbidden extra fields and expiration', () {
    expect(QrClaim.parse(raw, now: DateTime.utc(2029)).deviceId, 'AG-000001');
    final unsafe = jsonEncode({
      ...jsonDecode(raw) as Map<String, dynamic>,
      'wifiPassword': 'secret',
    });
    expect(
      () => QrClaim.parse(unsafe, now: DateTime.utc(2029)),
      throwsFormatException,
    );
    expect(
      () => QrClaim.parse(raw, now: DateTime.utc(2031)),
      throwsFormatException,
    );
  });
  test('Wi-Fi password is cleared after the BLE operation', () async {
    final ble = FakeBle();
    final controller = ProvisioningController(ble);
    await controller.provision(
      QrClaim.parse(raw, now: DateTime.utc(2029)),
      ProvisioningSession(
        sessionId: '50000000-0000-4000-8000-000000000001',
        deviceId: 'AG-000001',
        expiresAt: DateTime.utc(2030),
        sessionToken: 'x' * 32,
      ),
      'ssid',
      'password',
    );
    expect(controller.retainsPassword, false);
    expect(controller.retainsSessionToken, false);
    expect(ble.receivedSessionToken, 'x' * 32);
  });

  test(
    'Wi-Fi password is cleared after BLE failure and messages are bounded',
    () async {
      final controller = ProvisioningController(FailingBle());
      await expectLater(
        controller.provision(
          QrClaim.parse(raw, now: DateTime.utc(2029)),
          ProvisioningSession(
            sessionId: '50000000-0000-4000-8000-000000000001',
            deviceId: 'AG-000001',
            expiresAt: DateTime.utc(2030),
            sessionToken: 'x' * 32,
          ),
          'ssid',
          'password',
        ),
        throwsStateError,
      );
      expect(controller.retainsPassword, false);
      expect(controller.retainsSessionToken, false);
      expect(
        () => BleProtocol.wifiCredentials('s' * 33, 'password'),
        throwsFormatException,
      );
    },
  );

  test(
    'a same-session retry after a failed attempt still presents the '
    'binding grant, not null',
    () async {
      final session = ProvisioningSession(
        sessionId: '50000000-0000-4000-8000-000000000001',
        deviceId: 'AG-000001',
        expiresAt: DateTime.utc(2030),
        sessionToken: 'x' * 32,
        bindingGrant: 'g' * 194,
      );
      await expectLater(
        ProvisioningController(FailingBle()).provision(
          QrClaim.parse(raw, now: DateTime.utc(2029)),
          session,
          'ssid',
          'password',
        ),
        throwsStateError,
      );
      expect(session.retainsBindingGrant, true);

      final retryBle = FakeBle();
      await ProvisioningController(retryBle).provision(
        QrClaim.parse(raw, now: DateTime.utc(2029)),
        session,
        'ssid',
        'password',
      );
      expect(retryBle.receivedBindingGrant, 'g' * 194);
    },
  );
}
