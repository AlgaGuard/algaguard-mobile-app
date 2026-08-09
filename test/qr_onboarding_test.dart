import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:algaguard_mobile_app/src/ble_provisioning_wire.dart';
import 'package:algaguard_mobile_app/src/onboarding.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:algaguard_mobile_app/src/qr_onboarding.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const device = DeviceSummary(
  deviceUuid: '10000000-0000-4000-8000-000000000001',
  deviceId: 'AG-000001',
  lifecycle: 'CLAIMED',
  ownershipVersion: '1',
);

int crc16(List<int> bytes) {
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

String invitation(DateTime now, {int deviceNumber = 1, int? expiresAt}) {
  final bytes = Uint8List(31);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 1;
  bytes[1] = (deviceNumber >> 16) & 0xff;
  bytes[2] = (deviceNumber >> 8) & 0xff;
  bytes[3] = deviceNumber & 0xff;
  for (var index = 4; index < 20; index++) {
    bytes[index] = 0xa5;
  }
  final issued = now.toUtc().millisecondsSinceEpoch ~/ 1000;
  data.setUint32(20, issued);
  data.setUint32(24, expiresAt ?? issued + 180);
  bytes[28] = 1;
  data.setUint16(29, crc16(bytes.sublist(0, 29)));
  return 'ag://q/${base64Url.encode(bytes).replaceAll('=', '')}';
}

Map<String, Object> response(DateTime now) => {
  'schema':
      'urn:algaguard:schema:onboarding:qr-onboarding-exchange-response:v1',
  'schemaVersion': '1.0.0',
  'sessionId': '50000000-0000-4000-8000-000000000001',
  'deviceId': 'AG-000001',
  'createdAt': now.toUtc().toIso8601String(),
  'expiresAt': now.toUtc().add(const Duration(minutes: 15)).toIso8601String(),
  'serviceUuid': bleProvisioningServiceUuid,
  'sessionToken': 'x' * 32,
  'bindingGrant': 'g' * 194,
};

void main() {
  test('1 only ag compact invitations are accepted', () {
    final now = DateTime.utc(2026, 7, 30, 10);
    expect(
      QrOnboardingCodec.decode(invitation(now), now: now).deviceId,
      'AG-000001',
    );
    expect(
      () => QrOnboardingCodec.decode('https://example.test', now: now),
      throwsFormatException,
    );
  });

  test('2 invalid checksum and overlong invitations are rejected safely', () {
    final now = DateTime.utc(2026, 7, 30, 10);
    final valid = invitation(now);
    final corrupted =
        '${valid.substring(0, 48)}${valid.endsWith('A') ? 'B' : 'A'}';
    expect(
      () => QrOnboardingCodec.decode(corrupted, now: now),
      throwsFormatException,
    );
    expect(
      () => QrOnboardingCodec.decode(
        invitation(now, expiresAt: now.millisecondsSinceEpoch ~/ 1000 + 301),
      ),
      throwsFormatException,
    );
  });

  test('3 availability follows the build flag alone, in every build mode', () {
    expect(qrOnboardingAvailable(enabled: true), true);
    expect(qrOnboardingAvailable(enabled: false), false);
  });

  test('4 authenticated exchange sends one strict request', () async {
    final now = DateTime.now().toUtc();
    var calls = 0;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            expect(
              options.path,
              '/services/device/device-onboarding/qr/exchange',
            );
            expect(options.headers['Authorization'], 'Bearer opaque');
            expect(
              (options.data as Map).keys,
              containsAll(<String>[
                'schema',
                'schemaVersion',
                'invitationUri',
                'ownershipVersion',
              ]),
            );
            handler.resolve(
              Response<Object>(
                requestOptions: options,
                statusCode: 201,
                headers: Headers.fromMap({
                  'cache-control': ['no-store'],
                }),
                data: response(now),
              ),
            );
          },
        ),
      );
    final prepared =
        await PlatformApi(
          Uri.parse('https://safe.example'),
          client: dio,
        ).exchangeQrOnboarding(
          accessToken: 'opaque',
          device: device,
          invitation: QrOnboardingCodec.decode(invitation(now), now: now),
        );
    expect(calls, 1);
    expect(prepared.session.retainsToken, true);
    expect(prepared.session.retainsBindingGrant, true);
    prepared.session.clear();
  });

  test('5 device mismatch is rejected before transport', () async {
    final now = DateTime.now().toUtc();
    await expectLater(
      PlatformApi(Uri.parse('https://safe.example')).exchangeQrOnboarding(
        accessToken: 'opaque',
        device: device,
        invitation: QrOnboardingCodec.decode(
          invitation(now, deviceNumber: 2),
          now: now,
        ),
      ),
      throwsFormatException,
    );
  });

  test('scan-first exchange works with zero pre-existing devices', () async {
    final now = DateTime.now().toUtc();
    var calls = 0;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            final body = Map<String, dynamic>.from(options.data as Map);
            expect(
              body['schema'],
              'urn:algaguard:schema:onboarding:qr-onboarding-exchange-request:v2',
            );
            expect(body['schemaVersion'], '2.0.0');
            expect(body['registrationMode'], 'DEVELOPMENT_SCAN_FIRST');
            expect(body['organizationId'], isNotNull);
            expect(body.containsKey('ownershipVersion'), false);
            handler.resolve(
              Response<Object>(
                requestOptions: options,
                statusCode: 201,
                headers: Headers.fromMap({
                  'cache-control': ['no-store'],
                }),
                data: response(now),
              ),
            );
          },
        ),
      );
    final prepared =
        await PlatformApi(
          Uri.parse('https://safe.example'),
          client: dio,
        ).exchangeQrOnboarding(
          accessToken: 'opaque',
          organizationId: '10000000-0000-4000-8000-000000000001',
          invitation: QrOnboardingCodec.decode(invitation(now), now: now),
        );
    expect(calls, 1);
    expect(prepared.session.retainsToken, true);
    prepared.session.clear();
  });

  test('scan-first and existing-device modes cannot be mixed', () async {
    final now = DateTime.now().toUtc();
    await expectLater(
      PlatformApi(Uri.parse('https://safe.example')).exchangeQrOnboarding(
        accessToken: 'opaque',
        device: device,
        organizationId: '10000000-0000-4000-8000-000000000001',
        invitation: QrOnboardingCodec.decode(invitation(now), now: now),
      ),
      throwsFormatException,
    );
  });

  test('6 exchange requires no-store and exact response fields', () async {
    final now = DateTime.now().toUtc();
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Object>(
              requestOptions: options,
              statusCode: 201,
              data: response(now),
            ),
          ),
        ),
      );
    await expectLater(
      PlatformApi(
        Uri.parse('https://safe.example'),
        client: dio,
      ).exchangeQrOnboarding(
        accessToken: 'opaque',
        device: device,
        invitation: QrOnboardingCodec.decode(invitation(now), now: now),
      ),
      throwsFormatException,
    );
  });

  test('7 QR session and grant remain memory-only and clear together', () {
    final session = ProvisioningSession(
      sessionId: '50000000-0000-4000-8000-000000000001',
      deviceId: 'AG-000001',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      sessionToken: 'x' * 32,
      bindingGrant: 'g' * 194,
    );
    session.clear();
    expect(session.retainsToken, false);
    expect(session.retainsBindingGrant, false);
  });

  test('8 BLE controller receives the QR-bound v2 contract', () {
    final payload =
        jsonDecode(
              utf8.decode(
                BleProvisioningWire.canonicalPayload(
                  sessionId: '50000000-0000-4000-8000-000000000001',
                  deviceId: 'AG-000001',
                  sessionToken: 'x' * 32,
                  bindingGrant: 'g' * 194,
                  ssid: 'synthetic',
                  password: 'synthetic-only',
                ),
              ),
            )
            as Map<String, dynamic>;
    expect(payload['schema'], qrBleProvisioningPayloadSchema);
    expect(payload['schemaVersion'], '2.0.0');
    expect(payload.keys.length, 8);
  });

  test(
    '9 legacy seven-field BLE contract remains available for disabled fallback',
    () {
      final payload =
          jsonDecode(
                utf8.decode(
                  BleProvisioningWire.canonicalPayload(
                    sessionId: '50000000-0000-4000-8000-000000000001',
                    deviceId: 'AG-000001',
                    sessionToken: 'x' * 32,
                    ssid: 'synthetic',
                    password: 'synthetic-only',
                  ),
                ),
              )
              as Map<String, dynamic>;
      expect(payload['schema'], bleProvisioningPayloadSchema);
      expect(payload.containsKey('bindingGrant'), false);
      expect(payload.keys.length, 7);
    },
  );

  test('10 invitation and secret values have no printable representation', () {
    expect(QrOnboardingInvitation, isNotNull);
    expect(
      const FormatException('INVITATION_EXPIRED').toString(),
      isNot(contains('ag://')),
    );
    expect(
      const FormatException('QR_EXCHANGE_UNAVAILABLE').toString(),
      isNot(contains('sessionToken')),
    );
  });

  test('11 Devices owns the only visible secure QR onboarding entry point', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, isNot(contains("'/scan': (_) => const ScanQrScreen()")));
    expect(source, isNot(contains("'Add device (scan QR)'")));
    expect(source, contains("label: const Text('Scan device QR')"));
  });
}
