import 'package:algaguard_mobile_app/src/onboarding.dart';
import 'package:algaguard_mobile_app/src/physical_session_handoff.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

ProvisioningSession session({String deviceId = 'AG-000001'}) =>
    ProvisioningSession(
      sessionId: '50000000-0000-4000-8000-000000000001',
      deviceId: deviceId,
      expiresAt: DateTime.utc(2099),
      sessionToken: 'x' * 32,
    );

PlatformApi api(void Function(RequestOptions options) inspect) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        inspect(options);
        handler.resolve(Response(requestOptions: options, statusCode: 204));
      },
    ),
  );
  return PlatformApi(Uri.parse('https://safe.example/api/v1'), client: dio);
}

void main() {
  test('1 feature is disabled by default and unavailable in release mode', () {
    expect(physicalSessionApprovalEnabled, isFalse);
    expect(physicalSessionApprovalAvailable(releaseMode: true), isFalse);
  });

  test(
    '2 approval uses exact generated route contract and authenticated client',
    () async {
      final controller = PhysicalSessionApprovalController(
        api: api((options) {
          expect(
            options.path,
            '/services/device/development/physical-session-handoffs/approve',
          );
          expect(options.headers['Authorization'], 'Bearer access');
          expect(options.data, {
            'protocolVersion': 1,
            'userCode': 'AB2CDE',
            'sessionId': '50000000-0000-4000-8000-000000000001',
            'deviceId': 'AG-000001',
            'sessionToken': 'x' * 32,
          });
        }),
        accessToken: 'access',
        session: session(),
        enabled: true,
      );
      expect(
        await controller.approve('ab-2c de'),
        PhysicalSessionApprovalState.approved,
      );
    },
  );

  test('3 active in-memory session and device binding are required', () async {
    final controller = PhysicalSessionApprovalController(
      api: api((_) {}),
      accessToken: 'access',
      session: null,
      enabled: true,
    );
    expect(
      await controller.approve('AB2CDE'),
      PhysicalSessionApprovalState.sessionUnavailable,
    );
    final mismatched = session(deviceId: 'AG-000002');
    expect(mismatched.deviceId, isNot('AG-000001'));
    mismatched.clear();
  });

  test(
    '4 only userCode is accepted and duplicate submission is prevented',
    () async {
      final controller = PhysicalSessionApprovalController(
        api: api((_) {}),
        accessToken: 'access',
        session: session(),
        enabled: true,
      );
      expect(
        await controller.approve('invalid!'),
        PhysicalSessionApprovalState.invalidCode,
      );
      expect(controller.session?.retainsToken, isTrue);
      controller.clear();
    },
  );

  test('5 terminal paths are safe and clear session references', () async {
    final active = session();
    final controller = PhysicalSessionApprovalController(
      api: api((_) {
        throw DioException(requestOptions: RequestOptions());
      }),
      accessToken: 'access',
      session: active,
      enabled: true,
    );
    expect(
      await controller.approve('AB2CDE'),
      PhysicalSessionApprovalState.networkError,
    );
    expect(controller.session, isNull);
    expect(active.retainsToken, isFalse);
  });

  test(
    '6 state and errors never expose session or authorization values',
    () async {
      final controller = PhysicalSessionApprovalController(
        api: api((_) {}),
        accessToken: 'authorization-value',
        session: session(),
        enabled: false,
      );
      final state = await controller.approve('AB2CDE');
      expect(state.name.contains('authorization-value'), isFalse);
      expect(state.name.contains('50000000'), isFalse);
      expect(state.name.contains('x' * 32), isFalse);
    },
  );

  test(
    '7 approval preserves the authoritative session for immediate BLE use',
    () async {
      final active = session();
      final controller = PhysicalSessionApprovalController(
        api: api((_) {}),
        accessToken: 'access',
        session: active,
        enabled: true,
      );
      expect(
        await controller.approve('AB2CDE'),
        PhysicalSessionApprovalState.approved,
      );
      expect(controller.session, same(active));
      final moved = controller.takeApprovedSession();
      expect(moved, same(active));
      expect(controller.session, isNull);
      moved.clear();
    },
  );

  test('8 terminal provisioning cleanup clears the authoritative session', () {
    final active = session();
    PhysicalSessionApprovalController.clearAuthoritativeSession(active);
    expect(active.retainsToken, isFalse);
  });
}
