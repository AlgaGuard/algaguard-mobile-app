import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> sample({double temperatureC = 24.1}) => {
  'sequence': '9',
  'observedAt': DateTime.utc(2026, 7, 30).toIso8601String(),
  'timestampQuality': 'NTP_SYNCED',
  'uptimeMs': '9000',
  'values': {
    'temperatureC': temperatureC,
    'ph': 7.1,
    'lightLux': 900,
    'nitrateMgL': 2.4,
    'phosphateMgL': 0.35,
    'potassiumMgL': 1.8,
  },
  'qualityFlags': ['SIMULATED'],
};

void main() {
  test('alert record decodes a HIGH breach with bounds', () {
    final alert = AlertRecord.fromJson({
      'alertId': '40000000-0000-4000-8000-000000000001',
      'deviceId': 'AG-000001',
      'parameter': 'temperatureC',
      'direction': 'HIGH',
      'value': 34.5,
      'minimum': 20,
      'maximum': 28,
      'occurredAt': '2026-08-01T00:00:00.000Z',
    });
    expect(alert.deviceId, 'AG-000001');
    expect(alert.direction, 'HIGH');
    expect(alert.value, 34.5);
    expect(alert.maximum, 28);
  });

  test('alert record accepts a bound-less breach direction', () {
    final alert = AlertRecord.fromJson({
      'alertId': '40000000-0000-4000-8000-000000000002',
      'deviceId': 'AG-000001',
      'parameter': 'ph',
      'direction': 'LOW',
      'value': 4.2,
      'occurredAt': '2026-08-01T00:00:00.000Z',
    });
    expect(alert.minimum, isNull);
    expect(alert.maximum, isNull);
  });

  test('alert record rejects an unknown direction', () {
    expect(
      () => AlertRecord.fromJson({
        'alertId': '40000000-0000-4000-8000-000000000003',
        'deviceId': 'AG-000001',
        'parameter': 'ph',
        'direction': 'SIDEWAYS',
        'value': 4.2,
        'occurredAt': '2026-08-01T00:00:00.000Z',
      }),
      throwsFormatException,
    );
  });

  test(
    'latest telemetry batch keys readings by device and omits missing ones',
    () async {
      final deviceWithData = '10000000-0000-4000-8000-000000000001';
      final deviceWithoutData = '10000000-0000-4000-8000-000000000002';
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(options.path, '/services/telemetry/devices/latest-batch');
              expect(options.data, {
                'deviceUuids': [deviceWithData, deviceWithoutData],
              });
              handler.resolve(
                Response<Object>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'items': [
                      {'deviceUuid': deviceWithData, 'latest': sample()},
                      {'deviceUuid': deviceWithoutData, 'latest': null},
                    ],
                  },
                ),
              );
            },
          ),
        );
      final readings =
          await PlatformApi(
            Uri.parse('https://safe.example/v1'),
            client: dio,
          ).latestTelemetryBatch(
            accessToken: 'token',
            deviceUuids: [deviceWithData, deviceWithoutData],
          );
      expect(readings.keys, [deviceWithData]);
      expect(readings[deviceWithData]!.temperatureC, 24.1);
    },
  );

  test(
    'latest telemetry batch skips the request for an empty device list',
    () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) =>
                fail('no request should be made for an empty batch'),
          ),
        );
      final readings = await PlatformApi(
        Uri.parse('https://safe.example/v1'),
        client: dio,
      ).latestTelemetryBatch(accessToken: 'token', deviceUuids: const []);
      expect(readings, isEmpty);
    },
  );

  test('organization alerts are fetched by the active organization', () async {
    final organizationId = '20000000-0000-4000-8000-000000000001';
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(
              options.path,
              '/services/realtime/organizations/$organizationId/alerts',
            );
            handler.resolve(
              Response<Object>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'items': [
                    {
                      'alertId': '40000000-0000-4000-8000-000000000001',
                      'deviceId': 'AG-000001',
                      'parameter': 'temperatureC',
                      'direction': 'HIGH',
                      'value': 34.5,
                      'maximum': 28,
                      'occurredAt': '2026-08-01T00:00:00.000Z',
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
    final alerts =
        await PlatformApi(
          Uri.parse('https://safe.example/v1'),
          client: dio,
        ).listOrganizationAlerts(
          accessToken: 'token',
          organizationId: organizationId,
        );
    expect(alerts, hasLength(1));
    expect(alerts.single.parameter, 'temperatureC');
  });
}
