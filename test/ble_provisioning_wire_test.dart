import 'dart:convert';
import 'dart:io';

import 'package:algaguard_mobile_app/src/ble_provisioning_wire.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

const _sessionId = '50000000-0000-4000-8000-000000000001';
const _deviceId = 'AG-000001';
final _sessionToken = List<String>.filled(32, 'x').join();

BleCharacteristicContract _request({bool notify = false}) =>
    BleCharacteristicContract(
      uuid: bleProvisioningRequestUuid,
      canRead: false,
      canWriteWithResponse: true,
      canWriteWithoutResponse: false,
      canNotify: notify,
    );

BleCharacteristicContract _status({bool writable = false}) =>
    BleCharacteristicContract(
      uuid: bleProvisioningStatusUuid,
      canRead: true,
      canWriteWithResponse: writable,
      canWriteWithoutResponse: false,
      canNotify: true,
    );

void main() {
  test(
    'normalizes FlutterBluePlus shorthand UUIDs to the canonical contract',
    () {
      expect(Guid('a1a0').toString(), 'a1a0');
      expect(
        canonicalFlutterBlueUuid(Guid('a1a0')),
        bleProvisioningServiceUuid,
      );
      expect(
        canonicalFlutterBlueUuid(Guid('a1a1')),
        bleProvisioningRequestUuid,
      );
      expect(canonicalFlutterBlueUuid(Guid('a1a2')), bleProvisioningStatusUuid);
    },
  );

  test('selects the exact provisioning service and characteristics', () {
    final selection = BleProvisioningWire.selectCharacteristics([
      BleServiceContract(
        uuid: bleProvisioningServiceUuid,
        characteristics: [
          const BleCharacteristicContract(
            uuid: '0000ffff-0000-1000-8000-00805f9b34fb',
            canRead: false,
            canWriteWithResponse: true,
            canWriteWithoutResponse: false,
            canNotify: false,
          ),
          _request(),
          _status(),
        ],
      ),
    ]);

    expect(selection.request.uuid, bleProvisioningRequestUuid);
    expect(selection.status.uuid, bleProvisioningStatusUuid);
    expect(
      () => BleProvisioningWire.selectCharacteristics(const []),
      throwsA(isA<BleProvisioningWireException>()),
    );
  });

  test('requires separated request and status properties', () {
    expect(
      () => BleProvisioningWire.selectCharacteristics([
        BleServiceContract(
          uuid: bleProvisioningServiceUuid,
          characteristics: [_request(notify: true), _status(writable: true)],
        ),
      ]),
      throwsA(isA<BleProvisioningWireException>()),
    );
  });

  test('encodes the canonical seven-field JSON in big-endian frames', () {
    final payload = BleProvisioningWire.canonicalPayload(
      sessionId: _sessionId,
      deviceId: _deviceId,
      sessionToken: _sessionToken,
      ssid: 'test-net',
      password: 'test-pass',
    );
    final object = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
    final frame = BleProvisioningWire.framePayload([
      1,
      2,
      3,
    ], 0x01020304).single;

    expect(object.keys.toSet(), {
      'schema',
      'schemaVersion',
      'sessionId',
      'deviceId',
      'sessionToken',
      'ssid',
      'password',
    });
    expect(object['schema'], bleProvisioningPayloadSchema);
    expect(object['schemaVersion'], bleProvisioningPayloadSchemaVersion);
    expect(frame, [1, 1, 2, 3, 4, 0, 0, 0, 1, 0, 3, 1, 2, 3]);
  });

  test('enforces the fragment and assembled-payload limits', () {
    final frames = BleProvisioningWire.framePayload(
      List<int>.filled(BleProvisioningWire.maxPayloadBytes, 1),
      1,
    );

    expect(frames, hasLength(4));
    expect(
      frames.every(
        (frame) => frame.length <= BleProvisioningWire.maxFrameBytes,
      ),
      isTrue,
    );
    expect(
      () => BleProvisioningWire.framePayload(
        List<int>.filled(BleProvisioningWire.maxPayloadBytes + 1, 1),
        1,
      ),
      throwsA(isA<BleProvisioningWireException>()),
    );

    final mtuBoundFrames = BleProvisioningWire.framePayload(
      List<int>.filled(500, 1),
      2,
      fragmentPayloadLimit: 242,
    );
    expect(mtuBoundFrames, hasLength(3));
    expect(mtuBoundFrames.every((frame) => frame.length <= 253), isTrue);
    expect(
      () => BleProvisioningWire.framePayload(
        [1],
        3,
        fragmentPayloadLimit: BleProvisioningWire.maxFragmentPayload + 1,
      ),
      throwsA(isA<BleProvisioningWireException>()),
    );
  });

  test('advances request frames only after each write acknowledgement', () {
    final writer = SequentialFrameWriter([
      [1],
      [2],
    ]);

    expect(writer.current, [1]);
    writer.acknowledgeWrite();
    expect(writer.current, [2]);
    writer.acknowledgeWrite();
    expect(writer.hasPending, isFalse);
    writer.clear();
    expect(writer.cleared, isTrue);
  });

  test(
    'accepts terminal status only from the safe status characteristic format',
    () {
      final accepted = BleProvisioningWire.decodeSafeStatus(
        utf8.encode('status=ACCEPTED reason=OK'),
      );

      expect(accepted.isAccepted, isTrue);
      expect(
        () => BleProvisioningWire.decodeSafeStatus(
          List<int>.filled(BleProvisioningWire.maxStatusBytes + 1, 65),
        ),
        throwsA(isA<BleProvisioningWireException>()),
      );
    },
  );

  test(
    'observes actual BLE status events without replaying an empty cache',
    () {
      final source = File('lib/src/platform_clients.dart').readAsStringSync();

      expect(source, contains('statusCharacteristic.onValueReceived.listen'));
      expect(
        source,
        isNot(contains('statusCharacteristic.lastValueStream.listen')),
      );
    },
  );

  test('terminal failure clears pending frames without an automatic retry', () {
    final writer = SequentialFrameWriter([
      [1, 2],
      [3, 4],
    ]);
    final rejected = BleProvisioningWire.decodeSafeStatus(
      utf8.encode('status=REJECTED reason=SESSION_MISMATCH'),
    );

    expect(rejected.isTerminal, isTrue);
    expect(rejected.isAccepted, isFalse);
    writer.clear();
    expect(writer.hasPending, isFalse);
    expect(writer.cleared, isTrue);
  });

  test(
    'safe diagnostics do not expose provisioning values or raw payloads',
    () {
      const status = SafeProvisioningStatus(
        SafeProvisioningState.rejected,
        'INVALID_TRANSITION',
      );
      const error = BleProvisioningWireException('SERVICE_NOT_FOUND');

      expect(status.uiText, 'Rejected');
      expect(error.toString(), 'SERVICE_NOT_FOUND');
      expect(status.uiText.contains('test-net'), isFalse);
      expect(error.toString().contains(_sessionToken), isFalse);
    },
  );
}
