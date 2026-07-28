import 'dart:convert';

const bleProvisioningServiceUuid = '0000a1a0-0000-1000-8000-00805f9b34fb';
const bleProvisioningRequestUuid = '0000a1a1-0000-1000-8000-00805f9b34fb';
const bleProvisioningStatusUuid = '0000a1a2-0000-1000-8000-00805f9b34fb';
const bleProvisioningPayloadSchema =
    'urn:algaguard:schema:onboarding:ble-provisioning-request:v1';
const bleProvisioningPayloadSchemaVersion = '1.0.0';

class BleProvisioningWireException implements Exception {
  const BleProvisioningWireException(this.code);
  final String code;

  @override
  String toString() => code;
}

class BleCharacteristicContract {
  const BleCharacteristicContract({
    required this.uuid,
    required this.canRead,
    required this.canWriteWithResponse,
    required this.canWriteWithoutResponse,
    required this.canNotify,
  });

  final String uuid;
  final bool canRead;
  final bool canWriteWithResponse;
  final bool canWriteWithoutResponse;
  final bool canNotify;
}

class BleServiceContract {
  const BleServiceContract({required this.uuid, required this.characteristics});

  final String uuid;
  final List<BleCharacteristicContract> characteristics;
}

class BleProvisioningGattSelection {
  const BleProvisioningGattSelection({
    required this.request,
    required this.status,
  });

  final BleCharacteristicContract request;
  final BleCharacteristicContract status;
}

class SequentialFrameWriter {
  SequentialFrameWriter(this._frames);

  final List<List<int>> _frames;
  int _nextIndex = 0;

  bool get hasPending => _nextIndex < _frames.length;
  List<int> get current {
    if (!hasPending) {
      throw const BleProvisioningWireException('NO_PENDING_FRAME');
    }
    return _frames[_nextIndex];
  }

  void acknowledgeWrite() {
    if (!hasPending) {
      throw const BleProvisioningWireException('NO_PENDING_FRAME');
    }
    _nextIndex++;
  }

  void clear() {
    for (final frame in _frames) {
      frame.fillRange(0, frame.length, 0);
    }
    _nextIndex = _frames.length;
  }

  bool get cleared =>
      _frames.every((frame) => frame.every((byte) => byte == 0));
}

enum SafeProvisioningState {
  ready,
  receiving,
  complete,
  validating,
  accepted,
  rejected,
  timedOut,
  cancelled,
}

class SafeProvisioningStatus {
  const SafeProvisioningStatus(this.state, this.reason);

  final SafeProvisioningState state;
  final String reason;

  bool get isTerminal =>
      state == SafeProvisioningState.accepted ||
      state == SafeProvisioningState.rejected ||
      state == SafeProvisioningState.timedOut ||
      state == SafeProvisioningState.cancelled;

  bool get isAccepted =>
      state == SafeProvisioningState.accepted && reason == 'OK';

  String get uiText => switch (state) {
    SafeProvisioningState.ready => 'Ready',
    SafeProvisioningState.receiving => 'Receiving',
    SafeProvisioningState.complete => 'Receiving complete',
    SafeProvisioningState.validating => 'Validating',
    SafeProvisioningState.accepted => 'Accepted',
    SafeProvisioningState.rejected => 'Rejected',
    SafeProvisioningState.timedOut => 'Timed out',
    SafeProvisioningState.cancelled => 'Disconnected',
  };
}

class BleProvisioningWire {
  static const protocolVersion = 1;
  static const headerLength = 11;
  static const maxFragmentPayload = 256;
  static const maxFrameBytes = headerLength + maxFragmentPayload;
  static const maxPayloadBytes = 1024;
  static const maxStatusBytes = 96;

  static BleProvisioningGattSelection selectCharacteristics(
    List<BleServiceContract> services,
  ) {
    BleServiceContract? service;
    for (final candidate in services) {
      if (candidate.uuid.toLowerCase() == bleProvisioningServiceUuid) {
        service = candidate;
        break;
      }
    }
    if (service == null) {
      throw const BleProvisioningWireException('SERVICE_NOT_FOUND');
    }
    BleCharacteristicContract? request;
    BleCharacteristicContract? status;
    for (final candidate in service.characteristics) {
      if (candidate.uuid.toLowerCase() == bleProvisioningRequestUuid) {
        request = candidate;
      } else if (candidate.uuid.toLowerCase() == bleProvisioningStatusUuid) {
        status = candidate;
      }
    }
    if (request == null) {
      throw const BleProvisioningWireException(
        'REQUEST_CHARACTERISTIC_NOT_FOUND',
      );
    }
    if (status == null) {
      throw const BleProvisioningWireException(
        'STATUS_CHARACTERISTIC_NOT_FOUND',
      );
    }
    if (!request.canWriteWithResponse ||
        request.canRead ||
        request.canNotify ||
        request.canWriteWithoutResponse ||
        !status.canRead ||
        !status.canNotify ||
        status.canWriteWithResponse ||
        status.canWriteWithoutResponse) {
      throw const BleProvisioningWireException('REQUIRED_PROPERTIES_MISMATCH');
    }
    return BleProvisioningGattSelection(request: request, status: status);
  }

  static List<int> canonicalPayload({
    required String sessionId,
    required String deviceId,
    required String sessionToken,
    required String ssid,
    required String password,
  }) {
    if (!RegExp(
          r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
        ).hasMatch(sessionId) ||
        !RegExp(r'^AG-[0-9]{6}$').hasMatch(deviceId) ||
        !RegExp(r'^[A-Za-z0-9_-]{32,96}$').hasMatch(sessionToken) ||
        ssid.isEmpty ||
        utf8.encode(ssid).length > 32 ||
        utf8.encode(password).length > 63) {
      throw const BleProvisioningWireException('INVALID_PROVISIONING_FIELDS');
    }
    final payload = utf8.encode(
      jsonEncode({
        'schema': bleProvisioningPayloadSchema,
        'schemaVersion': bleProvisioningPayloadSchemaVersion,
        'sessionId': sessionId,
        'deviceId': deviceId,
        'sessionToken': sessionToken,
        'ssid': ssid,
        'password': password,
      }),
    );
    if (payload.length > maxPayloadBytes) {
      throw const BleProvisioningWireException('PAYLOAD_TOO_LARGE');
    }
    return payload;
  }

  static List<List<int>> framePayload(List<int> payload, int messageId) {
    if (payload.isEmpty || payload.length > maxPayloadBytes || messageId <= 0) {
      throw const BleProvisioningWireException('INVALID_FRAME_INPUT');
    }
    final fragmentCount =
        (payload.length + maxFragmentPayload - 1) ~/ maxFragmentPayload;
    if (fragmentCount == 0 || fragmentCount > 0xffff) {
      throw const BleProvisioningWireException('INVALID_FRAME_INPUT');
    }
    final frames = <List<int>>[];
    for (var index = 0; index < fragmentCount; index++) {
      final start = index * maxFragmentPayload;
      final end = start + maxFragmentPayload < payload.length
          ? start + maxFragmentPayload
          : payload.length;
      final fragment = payload.sublist(start, end);
      if (fragment.isEmpty && index + 1 != fragmentCount) {
        throw const BleProvisioningWireException('INVALID_FRAME_INPUT');
      }
      frames.add([
        protocolVersion,
        (messageId >>> 24) & 0xff,
        (messageId >>> 16) & 0xff,
        (messageId >>> 8) & 0xff,
        messageId & 0xff,
        (index >>> 8) & 0xff,
        index & 0xff,
        (fragmentCount >>> 8) & 0xff,
        fragmentCount & 0xff,
        (fragment.length >>> 8) & 0xff,
        fragment.length & 0xff,
        ...fragment,
      ]);
    }
    return frames;
  }

  static SafeProvisioningStatus decodeSafeStatus(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxStatusBytes) {
      throw const BleProvisioningWireException('STATUS_TOO_LARGE');
    }
    final raw = utf8.decode(bytes, allowMalformed: false);
    final match = RegExp(
      r'^status=([A-Z_]+) reason=([A-Z_]+)$',
    ).firstMatch(raw);
    if (match == null || !_safeReasons.contains(match.group(2))) {
      throw const BleProvisioningWireException('UNSAFE_STATUS');
    }
    final state = _safeStates[match.group(1)];
    if (state == null) {
      throw const BleProvisioningWireException('UNSAFE_STATUS');
    }
    return SafeProvisioningStatus(state, match.group(2)!);
  }

  static const Map<String, SafeProvisioningState> _safeStates = {
    'READY': SafeProvisioningState.ready,
    'RECEIVING': SafeProvisioningState.receiving,
    'COMPLETE': SafeProvisioningState.complete,
    'VALIDATING': SafeProvisioningState.validating,
    'ACCEPTED': SafeProvisioningState.accepted,
    'REJECTED': SafeProvisioningState.rejected,
    'TIMED_OUT': SafeProvisioningState.timedOut,
    'CANCELLED': SafeProvisioningState.cancelled,
  };

  static const Set<String> _safeReasons = {
    'OK',
    'MALFORMED_FRAME',
    'MALFORMED_PAYLOAD',
    'UNSUPPORTED_VERSION',
    'DUPLICATE_FRAGMENT',
    'OUT_OF_ORDER_FRAGMENT',
    'MESSAGE_ID_MISMATCH',
    'FRAGMENT_COUNT_MISMATCH',
    'PAYLOAD_TOO_LARGE',
    'TRANSPORT_TIMEOUT',
    'DEVICE_ID_MISMATCH',
    'SESSION_MISMATCH',
    'SESSION_EXPIRED',
    'REPLAY_REJECTED',
    'FIELD_TOO_LONG',
    'INVALID_TRANSITION',
    'DISCONNECTED',
    'CANCELLED',
  };
}
