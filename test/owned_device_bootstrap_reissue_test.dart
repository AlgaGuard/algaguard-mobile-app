import 'dart:io';

import 'package:algaguard_mobile_app/src/physical_session_handoff.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:algaguard_mobile_app/src/onboarding.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const device = DeviceSummary(
  deviceUuid: '10000000-0000-4000-8000-000000000001',
  deviceId: 'AG-000001',
  lifecycle: 'CLAIMED',
  ownershipVersion: '1',
);

void main() {
  test('2 unowned device cannot request reissue', () async {
    var requests = 0;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests += 1;
            handler.reject(DioException(requestOptions: options));
          },
        ),
      );
    await expectLater(
      PlatformApi(
        Uri.parse('https://safe.example'),
        client: dio,
      ).reissueOwnedDeviceBootstrapSession(
        accessToken: 'test-access',
        device: const DeviceSummary(
          deviceUuid: '10000000-0000-4000-8000-000000000001',
          deviceId: 'AG-000001',
          lifecycle: 'UNCLAIMED',
          ownershipVersion: '1',
        ),
      ),
      throwsStateError,
    );
    expect(requests, 0);
  });

  test(
    '3 replacement session has memory-only ownership and clears explicitly',
    () {
      final source = File('lib/src/platform_clients.dart').readAsStringSync();
      final method = source.substring(
        source.indexOf('reissueOwnedDeviceBootstrapSession'),
        source.indexOf('approvePhysicalSessionHandoff'),
      );
      for (final forbidden in [
        'storage.write',
        'clipboard',
        'print(',
        'log(',
      ]) {
        expect(method.contains(forbidden), isFalse);
      }
      expect(method.contains('/claims/consume'), isTrue);
      expect(method.contains("claimCode: ''"), isTrue);
    },
  );

  test('4 restart or logout cleanup clears the in-memory session', () {
    final session = ProvisioningSession(
      sessionId: '50000000-0000-4000-8000-000000000001',
      deviceId: device.deviceId,
      expiresAt: DateTime.utc(2099),
      sessionToken: 'x' * 32,
    );
    expect(session.retainsToken, isTrue);
    PhysicalSessionApprovalController.clearAuthoritativeSession(session);
    expect(session.retainsToken, isFalse);
  });

  test('5 reissue success routes to Development session approval', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('reissueOwnedDeviceBootstrapSession'));
    expect(source, contains('PhysicalSessionApprovalScreen'));
    expect(source, contains('Development session approval available'));
    expect(source, isNot(contains('createAndConsumePhysicalClaim')));
  });

  test('safe UI message is preserved while retaining a typed category', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(
      source,
      contains(
        'Bootstrap session was not prepared. Stop this one-shot attempt.',
      ),
    );
    expect(source, contains('on BootstrapReissueException catch (error)'));
    expect(source, contains('_reissueFailureCategory = error.category'));
    expect(source, isNot(contains('error.response')));
  });

  test('6 release build hides and rejects the reissue action', () {
    expect(physicalSessionApprovalAvailable(releaseMode: true), isFalse);
    final source = File('lib/main.dart').readAsStringSync();
    expect(
      source,
      contains('physicalSessionApprovalAvailable(releaseMode: kReleaseMode)'),
    );
  });
}
