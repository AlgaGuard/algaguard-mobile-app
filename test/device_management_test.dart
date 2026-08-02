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

  test('remove device sends only the explicit safe confirmation', () async {
    RequestOptions? captured;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(
              Response<Object>(requestOptions: options, statusCode: 204),
            );
          },
        ),
      );
    await PlatformApi(
      Uri.parse('https://safe.example/v1'),
      client: dio,
    ).removeDevice(
      accessToken: 'redacted-access-token',
      deviceUuid: device.deviceUuid,
    );
    expect(captured?.method, 'DELETE');
    expect(captured?.data, const {'confirmation': 'REMOVE'});
  });

  testWidgets(
    'device setup asks for both names and explains draft thresholds',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: DeviceSetupScreen(device: device)),
        ),
      );
      expect(find.byKey(const Key('device-name-field')), findsOneWidget);
      expect(find.byKey(const Key('profile-name-field')), findsOneWidget);
      expect(find.byKey(const Key('save-device-setup')), findsOneWidget);
      expect(find.textContaining('no scientific thresholds'), findsOneWidget);
    },
  );
}
