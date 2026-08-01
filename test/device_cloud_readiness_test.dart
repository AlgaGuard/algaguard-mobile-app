import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _organizationId = '10000000-0000-4000-8000-000000000001';

Map<String, Object> _device(String lifecycle) => {
  'deviceUuid': '20000000-0000-4000-8000-000000000002',
  'deviceId': 'AG-000001',
  'lifecycle': lifecycle,
  'ownershipVersion': '1',
};

void main() {
  test(
    'cloud readiness becomes ready only after authoritative lifecycle',
    () async {
      final dio = Dio();
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            expect(options.path, '/services/device/devices');
            expect(options.queryParameters, {
              'organizationId': _organizationId,
            });
            expect(options.headers['Authorization'], 'Bearer access');
            handler.resolve(
              Response<Object>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'items': [_device(requests == 1 ? 'CLAIMED' : 'ACTIVE')],
                },
              ),
            );
          },
        ),
      );

      final result =
          await PlatformApi(
            Uri.parse('https://api.example.test'),
            client: dio,
          ).waitForDeviceCloudReadiness(
            accessToken: 'access',
            organizationId: _organizationId,
            deviceId: 'AG-000001',
            timeout: const Duration(seconds: 1),
            pollInterval: const Duration(milliseconds: 1),
            delay: (_) async {},
          );

      expect(result, DeviceCloudReadiness.ready);
      expect(requests, 2);
    },
  );

  test('claimed lifecycle times out without claiming cloud success', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response<Object>(
            requestOptions: options,
            statusCode: 200,
            data: {
              'items': [_device('CLAIMED')],
            },
          ),
        ),
      ),
    );

    final result =
        await PlatformApi(
          Uri.parse('https://api.example.test'),
          client: dio,
        ).waitForDeviceCloudReadiness(
          accessToken: 'access',
          organizationId: _organizationId,
          deviceId: 'AG-000001',
          timeout: const Duration(milliseconds: 2),
          pollInterval: const Duration(milliseconds: 1),
          delay: (_) => Future<void>.delayed(const Duration(milliseconds: 2)),
        );

    expect(result, DeviceCloudReadiness.timedOut);
  });

  test('missing device is unavailable and does not leak identifiers', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response<Object>(
            requestOptions: options,
            statusCode: 200,
            data: const {'items': <Object>[]},
          ),
        ),
      ),
    );

    final result =
        await PlatformApi(
          Uri.parse('https://api.example.test'),
          client: dio,
        ).waitForDeviceCloudReadiness(
          accessToken: 'access',
          organizationId: _organizationId,
          deviceId: 'AG-000001',
        );

    expect(result, DeviceCloudReadiness.unavailable);
    expect(result.name, isNot(contains('AG-')));
  });
}
