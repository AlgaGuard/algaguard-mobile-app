import 'dart:convert';

import 'package:algaguard_mobile_app/src/onboarding.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'claim consume uses the authoritative path, bearer, organization, and typed session',
    () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/claims/consume');
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
}
