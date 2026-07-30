import 'dart:convert';

import 'package:algaguard_mobile_app/src/onboarding.dart';
import 'package:algaguard_mobile_app/src/ble_provisioning_wire.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const reissueDevice = DeviceSummary(
  deviceUuid: '10000000-0000-4000-8000-000000000001',
  deviceId: 'AG-000001',
  lifecycle: 'CLAIMED',
  ownershipVersion: '1',
);

Map<String, Object> repairedBackendResponse({
  String serviceUuid = bleProvisioningServiceUuid,
}) => {
  'schema': 'urn:algaguard:schema:onboarding:bootstrap-session:v1',
  'schemaVersion': '1.0.0',
  'sessionId': '50000000-0000-4000-8000-000000000001',
  'deviceId': 'AG-000001',
  'createdAt': '2029-12-31T23:55:00Z',
  'expiresAt': '2030-01-01T00:00:00Z',
  'serviceUuid': serviceUuid,
  'sessionToken': 'x' * 32,
};

Dio reissueClient(Object response, {int statusCode = 201}) => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response(
          requestOptions: options,
          statusCode: statusCode,
          data: response,
        ),
      ),
    ),
  );

void main() {
  test(
    'claim consume uses the authoritative path, bearer, organization, and typed session',
    () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/services/device/claims/consume');
            expect(options.method, 'POST');
            expect(options.headers['Authorization'], 'Bearer access-token');
            expect(options.data, {
              'organizationId': '10000000-0000-4000-8000-000000000001',
              'deviceId': 'AG-000001',
              'claimCode': 'claim-code',
            });
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'device': {'deviceId': 'AG-000001'},
                  'bootstrap': {
                    'sessionId': '50000000-0000-4000-8000-000000000001',
                    'deviceId': 'AG-000001',
                    'expiresAt': '2030-01-01T00:00:00Z',
                    'sessionToken': 'x' * 32,
                  },
                },
              ),
            );
          },
        ),
      );
      final session =
          await PlatformApi(
            Uri.parse('https://api.example'),
            client: dio,
          ).consumeClaim(
            accessToken: 'access-token',
            organizationId: '10000000-0000-4000-8000-000000000001',
            claim: QrClaim.parse(
              jsonEncode({
                'schema': 'algaguard.device.setup',
                'schemaVersion': '1.0.0',
                'deviceId': 'AG-000001',
                'claimCode': 'claim-code',
                'bootstrapUrl': 'https://unused.example',
                'environment': 'development',
                'bleServiceId': 'a19a0001-7e4d-4b1a-9c2d-000000000001',
                'expiresAt': '2030-01-01T00:00:00Z',
              }),
            ),
          );
      expect(session.deviceId, 'AG-000001');
      expect(session.retainsToken, true);
      session.clear();
      expect(session.retainsToken, false);
    },
  );

  test(
    '1 owned device requests one replacement session without claim or device creation',
    () async {
      final paths = <String>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            paths.add(options.path);
            expect(options.method, 'POST');
            expect(options.data, {
              'schema':
                  'urn:algaguard:schema:onboarding:owned-device-bootstrap-reissue-request:v1',
              'schemaVersion': '1.0.0',
              'ownershipVersion': '1',
              'expiresInSeconds': 300,
            });
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 201,
                data: repairedBackendResponse(),
              ),
            );
          },
        ),
      );
      final prepared =
          await PlatformApi(
            Uri.parse('https://api.example/v1'),
            client: dio,
          ).reissueOwnedDeviceBootstrapSession(
            accessToken: 'access-token',
            device: reissueDevice,
          );
      expect(paths, [
        '/services/device/devices/10000000-0000-4000-8000-000000000001/bootstrap-sessions/reissue',
      ]);
      expect(prepared.claim.claimCode, isEmpty);
      expect(prepared.session.retainsToken, isTrue);
      prepared.session.clear();
    },
  );

  test(
    'repaired Device Service response prepares an in-memory session',
    () async {
      final prepared =
          await PlatformApi(
            Uri.parse('https://api.example/v1'),
            client: reissueClient(repairedBackendResponse()),
          ).reissueOwnedDeviceBootstrapSession(
            accessToken: 'test-access',
            device: reissueDevice,
          );
      expect(prepared.claim.bleServiceId, bleProvisioningServiceUuid);
      expect(prepared.session.retainsToken, isTrue);
      prepared.session.clear();
      expect(prepared.session.retainsToken, isFalse);
    },
  );

  test('previous backend UUID maps to a typed service UUID mismatch', () async {
    final future =
        PlatformApi(
          Uri.parse('https://api.example/v1'),
          client: reissueClient(
            repairedBackendResponse(
              serviceUuid: 'a19a0001-7e4d-4b1a-9c2d-000000000001',
            ),
          ),
        ).reissueOwnedDeviceBootstrapSession(
          accessToken: 'test-access',
          device: reissueDevice,
        );
    await expectLater(
      future,
      throwsA(
        isA<BootstrapReissueException>().having(
          (error) => error.category,
          'category',
          BootstrapReissueFailureCategory.serviceUuidMismatch,
        ),
      ),
    );
  });

  test(
    'response and transport failures retain only safe typed categories',
    () async {
      final invalidResponse =
          PlatformApi(
            Uri.parse('https://api.example/v1'),
            client: reissueClient({'unexpected': true}),
          ).reissueOwnedDeviceBootstrapSession(
            accessToken: 'test-access',
            device: reissueDevice,
          );
      await expectLater(
        invalidResponse,
        throwsA(
          isA<BootstrapReissueException>().having(
            (error) => error.category,
            'category',
            BootstrapReissueFailureCategory.responseSchemaMismatch,
          ),
        ),
      );

      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
              ),
            ),
          ),
        );
      final transportFailure =
          PlatformApi(
            Uri.parse('https://api.example/v1'),
            client: dio,
          ).reissueOwnedDeviceBootstrapSession(
            accessToken: 'test-access',
            device: reissueDevice,
          );
      await expectLater(
        transportFailure,
        throwsA(
          isA<BootstrapReissueException>().having(
            (error) => error.category,
            'category',
            BootstrapReissueFailureCategory.transportFailure,
          ),
        ),
      );
    },
  );

  test('typed diagnostics contain no response or secret material', () {
    const error = BootstrapReissueException(
      BootstrapReissueFailureCategory.serviceUuidMismatch,
    );
    final safe = error.toString();
    expect(safe, 'BootstrapReissueException(serviceUuidMismatch)');
    for (final forbidden in [
      'sessionToken',
      'sessionId',
      'authorization',
      'response',
      'AG-',
    ]) {
      expect(safe, isNot(contains(forbidden)));
    }
  });
}
