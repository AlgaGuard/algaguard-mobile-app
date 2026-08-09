import 'dart:convert';
import 'dart:typed_data';

const qrOnboardingEnabled = bool.fromEnvironment(
  'ALGAGUARD_ENABLE_QR_ONBOARDING',
);

// QR pairing is the product's real device-onboarding flow (not a dev-only
// tool like the physical session approval bootstrap reissue), so unlike
// that one this is available in release builds too -- gated only by the
// build-time flag, never by kReleaseMode.
bool qrOnboardingAvailable({bool enabled = qrOnboardingEnabled}) => enabled;

enum QrOnboardingScanState {
  scanning,
  detected,
  expired,
  unsupported,
  preparing,
  ready,
  failed,
}

enum QrOnboardingExchangeFailure {
  expired,
  replayed,
  deviceNotEligible,
  pairedWithAnotherOrganization,
  authorization,
  unavailable,
}

class QrOnboardingExchangeException implements Exception {
  const QrOnboardingExchangeException(this.failure);

  final QrOnboardingExchangeFailure failure;
}

class QrOnboardingInvitation {
  const QrOnboardingInvitation._({
    required this.uri,
    required this.deviceId,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String uri;
  final String deviceId;
  final DateTime issuedAt;
  final DateTime expiresAt;
}

class QrOnboardingCodec {
  static const uriLength = 49;
  static const maximumLifetime = Duration(minutes: 5);

  static QrOnboardingInvitation decode(String raw, {DateTime? now}) {
    if (raw.length != uriLength ||
        !RegExp(r'^ag://q/[A-Za-z0-9_-]{42}$').hasMatch(raw)) {
      throw const FormatException('UNSUPPORTED_INVITATION');
    }
    Uint8List bytes;
    try {
      bytes = base64Url.decode('${raw.substring(7)}==');
    } on FormatException {
      throw const FormatException('UNSUPPORTED_INVITATION');
    }
    if (bytes.length != 31 || bytes[0] != 1 || bytes[28] != 1) {
      throw const FormatException('UNSUPPORTED_INVITATION');
    }
    final data = ByteData.sublistView(bytes);
    if (_crc16(bytes.sublist(0, 29)) != data.getUint16(29)) {
      throw const FormatException('UNSUPPORTED_INVITATION');
    }
    final numericDevice = (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    final issuedSeconds = data.getUint32(20);
    final expiresSeconds = data.getUint32(24);
    final issuedAt = DateTime.fromMillisecondsSinceEpoch(
      issuedSeconds * 1000,
      isUtc: true,
    );
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      expiresSeconds * 1000,
      isUtc: true,
    );
    if (numericDevice < 1 ||
        numericDevice > 999999 ||
        !expiresAt.isAfter(issuedAt) ||
        expiresAt.difference(issuedAt) > maximumLifetime) {
      throw const FormatException('UNSUPPORTED_INVITATION');
    }
    return QrOnboardingInvitation._(
      uri: raw,
      deviceId: 'AG-${numericDevice.toString().padLeft(6, '0')}',
      issuedAt: issuedAt,
      expiresAt: expiresAt,
    );
  }

  static int _crc16(List<int> bytes) {
    var crc = 0xffff;
    for (final byte in bytes) {
      crc ^= byte << 8;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 0x8000) != 0
            ? ((crc << 1) ^ 0x1021) & 0xffff
            : (crc << 1) & 0xffff;
      }
    }
    return crc;
  }
}
