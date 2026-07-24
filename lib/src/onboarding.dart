import 'dart:convert';

enum ProvisioningStage {
  connecting,
  sendingCredentials,
  joiningWifi,
  requestingCertificate,
  connectingCloud,
  completed,
  failed,
}

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
    if (value['deviceId'] is! String ||
        !RegExp(r'^AG-[0-9]{6}$').hasMatch(value['deviceId'] as String) ||
        value['claimCode'] is! String ||
        (value['claimCode'] as String).isEmpty ||
        (value['claimCode'] as String).length > 128 ||
        value['bootstrapUrl'] is! String ||
        value['bleServiceId'] is! String) {
      throw const FormatException('Invalid device setup payload');
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

class BleProtocol {
  static const schema = 'algaguard.ble.provisioning';
  static const version = '1.0.0';
  static const maxMessageBytes = 1024;

  static List<int> wifiCredentials(String ssid, String password) {
    if (ssid.isEmpty || ssid.length > 32 || password.length > 63) {
      throw const FormatException(
        'Wi-Fi credentials exceed provisioning bounds',
      );
    }
    final value = utf8.encode(
      jsonEncode({
        'schema': schema,
        'schemaVersion': version,
        'type': 'WIFI_CREDENTIALS',
        'ssid': ssid,
        'password': password,
      }),
    );
    if (value.length > maxMessageBytes) {
      throw const FormatException('BLE provisioning message is too large');
    }
    return value;
  }

  static void validateIncoming(String raw, {String? expectedType}) {
    if (utf8.encode(raw).length > maxMessageBytes) {
      throw const FormatException('BLE message is too large');
    }
    final value = jsonDecode(raw) as Map<String, dynamic>;
    if (value['schema'] != schema ||
        value['schemaVersion'] != version ||
        (expectedType != null && value['type'] != expectedType)) {
      throw const FormatException('Unexpected BLE provisioning message');
    }
  }
}

class ProvisioningController {
  ProvisioningController(this.ble);
  final BleProvisioner ble;
  String? _password;
  ProvisioningStage stage = ProvisioningStage.connecting;
  bool get retainsPassword => _password != null;
  Future<void> provision(QrClaim claim, String ssid, String password) async {
    _password = password;
    try {
      stage = ProvisioningStage.sendingCredentials;
      await ble.provision(
        serviceId: claim.bleServiceId,
        ssid: ssid,
        password: _password!,
      );
      stage = ProvisioningStage.completed;
    } catch (_) {
      stage = ProvisioningStage.failed;
      rethrow;
    } finally {
      _password = null;
    }
  }
}
