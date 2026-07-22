import 'dart:convert';
import 'package:algaguard_mobile_app/src/onboarding.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBle implements BleProvisioner {
  String? receivedPassword;
  @override
  Future<void> provision({
    required String serviceId,
    required String ssid,
    required String password,
  }) async {
    receivedPassword = password;
  }
}

void main() {
  final raw = jsonEncode({
    'schema': 'algaguard.device.setup',
    'schemaVersion': '1.0.0',
    'deviceId': 'device',
    'claimCode': 'one-time',
    'bootstrapUrl': 'https://api.example/bootstrap',
    'environment': 'development',
    'bleServiceId': 'service',
    'expiresAt': '2030-01-01T00:00:00Z',
  });
  test('QR validation rejects forbidden extra fields and expiration', () {
    expect(QrClaim.parse(raw, now: DateTime.utc(2029)).deviceId, 'device');
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
    final controller = ProvisioningController(FakeBle());
    await controller.provision(
      QrClaim.parse(raw, now: DateTime.utc(2029)),
      'ssid',
      'password',
    );
    expect(controller.retainsPassword, false);
  });
}
