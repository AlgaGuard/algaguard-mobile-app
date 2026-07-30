import 'dart:io';

import 'package:algaguard_mobile_app/src/onboarding.dart';
import 'package:algaguard_mobile_app/src/physical_session_handoff.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

ProvisioningSession timedSession(DateTime expiry) => ProvisioningSession(
  sessionId: '50000000-0000-4000-8000-000000000001',
  deviceId: 'AG-000001',
  expiresAt: expiry,
  sessionToken: 'x' * 32,
);

PlatformApi responseApi({int status = 204, void Function()? requested}) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requested?.call();
          if (status == 204) {
            handler.resolve(Response(requestOptions: options, statusCode: 204));
          } else {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: status),
              ),
            );
          }
        },
      ),
    );
  return PlatformApi(Uri.parse('https://safe.example'), client: dio);
}

void main() {
  final now = DateTime.utc(2030, 1, 1);

  test('1 countdown derives from server expiry with a safe skew margin', () {
    final value = timedSession(now.add(const Duration(minutes: 15)));
    expect(value.remaining(now: now), const Duration(minutes: 14, seconds: 45));
    expect(value.isExpiredAt(now), isFalse);
  });

  test('2 reissue v2 contains no mobile-selected TTL', () {
    final source = File('lib/src/platform_clients.dart').readAsStringSync();
    final method = source.substring(
      source.indexOf('reissueOwnedDeviceBootstrapSession'),
      source.indexOf('approvePhysicalSessionHandoff'),
    );
    expect(method, contains('owned-device-bootstrap-reissue-request:v2'));
    expect(method, isNot(contains('expiresInSeconds')));
  });

  test(
    '3 approval is disabled and cleared after authoritative expiry',
    () async {
      var requests = 0;
      final active = timedSession(now.add(const Duration(seconds: 15)));
      final controller = PhysicalSessionApprovalController(
        api: responseApi(requested: () => requests += 1),
        accessToken: 'safe-test',
        session: active,
        enabled: true,
        now: () => now,
      );
      expect(
        await controller.approve('AB2CDE'),
        PhysicalSessionApprovalState.expired,
      );
      expect(requests, 0);
      expect(active.retainsToken, isFalse);
    },
  );

  test('4 server expiry maps to a typed safe state', () async {
    final controller = PhysicalSessionApprovalController(
      api: responseApi(status: 410),
      accessToken: 'safe-test',
      session: timedSession(now.add(const Duration(minutes: 15))),
      enabled: true,
      now: () => now,
    );
    expect(
      await controller.approve('AB2CDE'),
      PhysicalSessionApprovalState.expired,
    );
    expect(controller.session, isNull);
  });

  test('5 a fresh session replaces only expired in-memory state', () {
    final active = timedSession(now.add(const Duration(minutes: 15)));
    final controller = PhysicalSessionApprovalController(
      api: responseApi(),
      accessToken: 'safe-test',
      session: active,
      enabled: true,
      now: () => now,
    );
    final replacement = timedSession(now.add(const Duration(minutes: 20)));
    expect(controller.replaceExpiredSession(replacement), isFalse);
    final expiredController = PhysicalSessionApprovalController(
      api: responseApi(),
      accessToken: 'safe-test',
      session: timedSession(now.add(const Duration(seconds: 15))),
      enabled: true,
      now: () => now,
    );
    expect(expiredController.replaceExpiredSession(replacement), isTrue);
    expect(expiredController.session, same(replacement));
  });

  test('6 logout or restart cleanup clears the authoritative session', () {
    final active = timedSession(now.add(const Duration(minutes: 15)));
    PhysicalSessionApprovalController.clearAuthoritativeSession(active);
    expect(active.retainsToken, isFalse);
  });

  test('7 countdown and errors contain no session or token logging', () {
    final source = File(
      'lib/src/physical_session_handoff.dart',
    ).readAsStringSync();
    expect(source, contains('Expires in'));
    expect(source, contains('Session expired'));
    expect(source, isNot(contains('print(')));
    expect(source, isNot(contains('sessionToken')));
  });

  test('8 release mode keeps development approval unavailable', () {
    expect(physicalSessionApprovalAvailable(releaseMode: true), isFalse);
  });
}
