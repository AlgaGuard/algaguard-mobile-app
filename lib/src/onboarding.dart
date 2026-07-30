import 'dart:convert';

import 'ble_provisioning_wire.dart';

enum ProvisioningStage {
  connecting,
  discoveringService,
  subscribingStatus,
  sendingCredentials,
  receiving,
  validating,
  joiningWifi,
  requestingCertificate,
  connectingCloud,
  completed,
  failed,
}

class ProvisioningSession {
  ProvisioningSession({
    required this.sessionId,
    required this.deviceId,
    required this.expiresAt,
    required String sessionToken,
    String? bindingGrant,
  }) : _sessionToken = sessionToken,
       _bindingGrant = bindingGrant;
  final String sessionId;
  final String deviceId;
  final DateTime expiresAt;
  String? _sessionToken;
  String? _bindingGrant;
  static const clockSkewTolerance = Duration(seconds: 15);
  Duration remaining({DateTime? now}) {
    final value =
        expiresAt.difference((now ?? DateTime.now()).toUtc()) -
        clockSkewTolerance;
    return value.isNegative ? Duration.zero : value;
  }

  bool isExpiredAt(DateTime now) => remaining(now: now) == Duration.zero;
  bool get isExpired => isExpiredAt(DateTime.now().toUtc());
  String takeToken() {
    final value = _sessionToken;
    if (value == null || isExpired) {
      clear();
      throw const FormatException('Provisioning session is unavailable');
    }
    return value;
  }

  void clear() {
    _sessionToken = null;
    _bindingGrant = null;
  }

  String? takeBindingGrant() {
    final value = _bindingGrant;
    _bindingGrant = null;
    return value;
  }

  bool get retainsToken => _sessionToken != null;
  bool get retainsBindingGrant => _bindingGrant != null;
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
    required String sessionId,
    required String deviceId,
    required String sessionToken,
    required String ssid,
    required String password,
    String? bindingGrant,
    void Function(SafeProvisioningStatus status)? onStatus,
  });
}

class BleProtocol {
  static const schema = 'algaguard.ble.provisioning';
  static const version = '1.0.0';
  static const maxMessageBytes = 1024;

  static List<int> provisioningRequest({
    required String sessionId,
    required String deviceId,
    required String sessionToken,
    required String ssid,
    required String password,
    String? bindingGrant,
  }) {
    try {
      return BleProvisioningWire.canonicalPayload(
        sessionId: sessionId,
        deviceId: deviceId,
        sessionToken: sessionToken,
        ssid: ssid,
        password: password,
        bindingGrant: bindingGrant,
      );
    } on BleProvisioningWireException catch (_) {
      throw const FormatException('BLE provisioning request is invalid');
    }
  }

  static List<int> wifiCredentials(String ssid, String password) =>
      provisioningRequest(
        sessionId: '00000000-0000-4000-8000-000000000000',
        deviceId: 'AG-000000',
        sessionToken: 'x' * 32,
        ssid: ssid,
        password: password,
      );

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
  ProvisioningSession? _session;
  ProvisioningStage stage = ProvisioningStage.connecting;
  bool get retainsPassword => _password != null;
  bool get retainsSessionToken => _session?.retainsToken ?? false;
  void clear() {
    _password = null;
    _session?.clear();
    _session = null;
  }

  Future<void> provision(
    QrClaim claim,
    ProvisioningSession session,
    String ssid,
    String password, {
    void Function(SafeProvisioningStatus status)? onStatus,
  }) async {
    if (session.deviceId != claim.deviceId) {
      throw const FormatException('Claimed device mismatch');
    }
    _session = session;
    _password = password;
    try {
      stage = ProvisioningStage.sendingCredentials;
      await ble.provision(
        serviceId: claim.bleServiceId,
        sessionId: session.sessionId,
        deviceId: session.deviceId,
        sessionToken: session.takeToken(),
        ssid: ssid,
        password: _password!,
        bindingGrant: session.takeBindingGrant(),
        onStatus: onStatus,
      );
      stage = ProvisioningStage.completed;
    } catch (_) {
      stage = ProvisioningStage.failed;
      rethrow;
    } finally {
      clear();
    }
  }
}
