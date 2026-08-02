import 'package:algaguard_mobile_app/src/algae_profiles.dart';
import 'package:algaguard_mobile_app/src/demo_telemetry.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

AlgaeProfileConfiguration configuration() => AlgaeProfileConfiguration({
  for (final parameter in algaeParameters)
    parameter.key: const AlgaeThreshold(minimum: 1, maximum: 10),
});

void main() {
  test('Algae Profile requires all six thresholds and evaluates breaches', () {
    final profile = configuration();
    expect(profile.thresholds.length, 6);
    expect(
      AlgaeProfileConfiguration.fromJson(profile.toJson()).thresholds.length,
      6,
    );
    final alerts = profile.evaluate(
      DemoTelemetryReading(
        sequence: '1',
        generatedAt: DateTime.now().toUtc(),
        temperatureC: 11,
        ph: 7,
        lightLux: 7,
        nitrateMgL: 7,
        phosphateMgL: 7,
        potassiumMgL: 7,
        simulated: true,
      ),
    );
    expect(alerts.single.parameterLabel, 'Temperature');
    expect(alerts.single.safeMessage, isNot(contains('11')));
  });

  test(
    'profile creation and device assignment use authenticated APIs',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              if (options.path.endsWith('/profiles')) {
                handler.resolve(
                  Response<Object>(
                    requestOptions: options,
                    statusCode: 201,
                    data: {
                      'profileId': '30000000-0000-4000-8000-000000000001',
                      'name': 'Spirulina',
                      'current': {
                        'version': 1,
                        'configuration': configuration().toJson(),
                      },
                    },
                  ),
                );
              } else if (options.method == 'PUT') {
                handler.resolve(
                  Response<Object>(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'id': '40000000-0000-4000-8000-000000000001'},
                  ),
                );
              } else {
                handler.resolve(
                  Response<Object>(requestOptions: options, statusCode: 202),
                );
              }
            },
          ),
        );
      final api = PlatformApi(Uri.parse('https://safe.example'), client: dio);
      final profile = await api.createAlgaeProfile(
        accessToken: 'opaque',
        organizationId: '10000000-0000-4000-8000-000000000001',
        name: 'Spirulina',
        configuration: configuration(),
      );
      await api.assignDeviceProfile(
        accessToken: 'opaque',
        organizationId: '10000000-0000-4000-8000-000000000001',
        deviceId: 'AG-000001',
        profile: profile,
      );
      expect(requests, hasLength(3));
      expect(
        (requests.first.data as Map)['configuration']['parameters'],
        hasLength(6),
      );
      expect(requests[1].path, contains('profile-assignment'));
      expect(requests.last.path, contains('/commands'));
    },
  );

  test('incoming invitations support safe accept and reject actions', () async {
    final paths = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            paths.add(options.path);
            if (options.method == 'GET') {
              handler.resolve(
                Response<Object>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'items': [
                      {
                        'id': '50000000-0000-4000-8000-000000000001',
                        'organizationName': 'Research Lab',
                        'role': 'VIEWER',
                        'expiresAt': DateTime.now()
                            .toUtc()
                            .add(const Duration(hours: 1))
                            .toIso8601String(),
                      },
                    ],
                  },
                ),
              );
            } else {
              handler.resolve(
                Response<Object>(
                  requestOptions: options,
                  statusCode: options.path.endsWith('/reject') ? 204 : 200,
                ),
              );
            }
          },
        ),
      );
    final api = PlatformApi(Uri.parse('https://safe.example'), client: dio);
    final pending = await api.listIncomingInvitations(accessToken: 'opaque');
    await api.respondToInvitation(
      accessToken: 'opaque',
      invitationId: pending.single.id,
      accept: true,
    );
    await api.respondToInvitation(
      accessToken: 'opaque',
      invitationId: pending.single.id,
      accept: false,
    );
    expect(paths.any((path) => path.endsWith('/accept')), true);
    expect(paths.any((path) => path.endsWith('/reject')), true);
  });
}
