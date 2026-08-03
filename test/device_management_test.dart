import 'package:algaguard_mobile_app/main.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const device = DeviceSummary(
  deviceUuid: '10000000-0000-4000-8000-000000000001',
  deviceId: 'AG-000001',
  lifecycle: 'ACTIVE',
  ownershipVersion: '1',
  displayName: 'North tank',
);

void main() {
  test('device response accepts a bounded optional display name', () {
    final decoded = DeviceSummary.fromJson({
      'deviceUuid': device.deviceUuid,
      'deviceId': device.deviceId,
      'lifecycle': device.lifecycle,
      'ownershipVersion': device.ownershipVersion,
      'displayName': 'North tank',
    });
    expect(decoded.visibleName, 'North tank');
    expect(
      () => DeviceSummary.fromJson({
        'deviceUuid': device.deviceUuid,
        'deviceId': device.deviceId,
        'lifecycle': device.lifecycle,
        'ownershipVersion': device.ownershipVersion,
        'displayName': 'x' * 65,
      }),
      throwsFormatException,
    );
  });

  test(
    'device setup creates one draft profile and assigns its exact version',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              if (options.method == 'GET') {
                handler.resolve(
                  Response<Object>(
                    requestOptions: options,
                    statusCode: 200,
                    data: const {'items': <Object>[]},
                  ),
                );
                return;
              }
              if (options.method == 'POST' &&
                  options.path == '/services/profile/profiles') {
                handler.resolve(
                  Response<Object>(
                    requestOptions: options,
                    statusCode: 201,
                    data: {
                      'profileId': '20000000-0000-4000-8000-000000000002',
                      'name': 'North tank profile',
                      'current': {'version': 1},
                    },
                  ),
                );
                return;
              }
              if (options.method == 'PUT') {
                handler.resolve(
                  Response<Object>(
                    requestOptions: options,
                    statusCode: 200,
                    data: const {'id': '40000000-0000-4000-8000-000000000004'},
                  ),
                );
                return;
              }
              handler.resolve(
                Response<Object>(requestOptions: options, statusCode: 202),
              );
            },
          ),
        );
      final profile =
          await PlatformApi(
            Uri.parse('https://safe.example/v1'),
            client: dio,
          ).createAndAssignDeviceProfile(
            accessToken: 'redacted-access-token',
            organizationId: '30000000-0000-4000-8000-000000000003',
            deviceId: device.deviceId,
            profileName: 'North tank profile',
          );

      expect(profile.name, 'North tank profile');
      expect(requests.map((value) => value.method), [
        'GET',
        'POST',
        'PUT',
        'POST',
      ]);
      expect(
        requests[2].path,
        '/services/profile/devices/AG-000001/profile-assignment',
      );
      expect(
        requests.last.path,
        '/services/command/devices/AG-000001/commands',
      );
      final command = requests.last.data as Map<String, dynamic>;
      expect(command['commandType'], 'APPLY_PROFILE_CONFIGURATION');
      expect(
        (command['parameters'] as Map<String, dynamic>)['profileVersion'],
        '1.0.0',
      );
      expect((requests[1].data as Map<String, dynamic>)['configuration'], {
        'status': 'DRAFT',
        'thresholds': <String, Object>{},
      });
    },
  );

  test(
    'unpair requires device success before final ownership removal',
    () async {
      final captured = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              captured.add(options);
              if (options.method == 'GET') {
                final commandId = options.path.split('/').last;
                handler.resolve(
                  Response<Object>(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'commandId': commandId,
                      'deviceId': device.deviceId,
                      'commandType': 'REQUEST_PHYSICAL_UNPAIR',
                      'status': 'SUCCEEDED',
                    },
                  ),
                );
                return;
              }
              handler.resolve(
                Response<Object>(
                  requestOptions: options,
                  statusCode: options.path.endsWith('/physical-unpair/finalize')
                      ? 200
                      : 202,
                  data: options.path.endsWith('/physical-unpair/finalize')
                      ? const {'state': 'UNPAIRED', 'lifecycle': 'UNCLAIMED'}
                      : null,
                ),
              );
            },
          ),
        );
      final outcome =
          await PlatformApi(
            Uri.parse('https://safe.example/v1'),
            client: dio,
          ).requestPhysicalUnpair(
            accessToken: 'redacted-access-token',
            device: device,
            delay: (_) async {},
          );
      expect(outcome, PhysicalUnpairOutcome.completed);
      expect(captured.map((request) => request.method), [
        'POST',
        'GET',
        'POST',
      ]);
      expect(
        (captured.first.data as Map)['commandType'],
        'REQUEST_PHYSICAL_UNPAIR',
      );
      expect((captured.first.data as Map)['parameters'], isEmpty);
      expect(
        (captured.last.data as Map)['confirmation'],
        'PHYSICALLY_CONFIRMED',
      );
    },
  );

  testWidgets(
    'device setup asks for a name and directs profile selection to settings',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: DeviceSetupScreen(device: device)),
        ),
      );
      expect(find.byKey(const Key('device-name-field')), findsOneWidget);
      expect(find.byKey(const Key('profile-name-field')), findsNothing);
      expect(find.byKey(const Key('save-device-setup')), findsOneWidget);
      expect(find.textContaining('Algae Profiles menu'), findsOneWidget);
    },
  );
}
