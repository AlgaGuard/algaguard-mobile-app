import 'dart:convert';

class QrClaim {
  const QrClaim({
    required this.deviceId,
    required this.claimCode,
    required this.bootstrapUrl,
    required this.environment,
    required this.bleServiceId,
    required this.expiresAt,
  });
  final String deviceId;
  final String claimCode;
  final Uri bootstrapUrl;
  final String environment;
  final String bleServiceId;
  final DateTime expiresAt;
  static QrClaim parse(String raw, {DateTime? now}) {
    final value = jsonDecode(raw) as Map<String, dynamic>;
    const allowed = {
      'schema',
      'schemaVersion',
      'deviceId',
      'claimCode',
      'bootstrapUrl',
      'environment',
      'bleServiceId',
      'expiresAt',
    };
    if (value.keys.any((key) => !allowed.contains(key)) ||
        value['schema'] != 'algaguard.device.setup' ||
        value['schemaVersion'] != '1.0.0') {
      throw const FormatException('Unsupported or unsafe QR payload');
    }
    final expiresAt = DateTime.parse(value['expiresAt'] as String).toUtc();
    if (!expiresAt.isAfter((now ?? DateTime.now()).toUtc())) {
      throw const FormatException('Claim expired');
    }
    return QrClaim(
      deviceId: value['deviceId'] as String,
      claimCode: value['claimCode'] as String,
      bootstrapUrl: Uri.parse(value['bootstrapUrl'] as String),
      environment: value['environment'] as String,
      bleServiceId: value['bleServiceId'] as String,
      expiresAt: expiresAt,
    );
  }
}

abstract interface class BleProvisioner {
  Future<void> provision({
    required String serviceId,
    required String ssid,
    required String password,
  });
}

class ProvisioningController {
  ProvisioningController(this.ble);
  final BleProvisioner ble;
  String? _password;
  bool get retainsPassword => _password != null;
  Future<void> provision(QrClaim claim, String ssid, String password) async {
    _password = password;
    try {
      await ble.provision(
        serviceId: claim.bleServiceId,
        ssid: ssid,
        password: _password!,
      );
    } finally {
      _password = null;
    }
  }
}
