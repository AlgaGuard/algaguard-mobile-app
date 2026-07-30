import 'package:algaguard_mobile_app/src/environment.dart';
import 'package:flutter_test/flutter_test.dart';

AppEnvironment environment({
  String api = 'https://api.algaguard.bosilu.dev/v1',
  String websocket = 'wss://realtime.algaguard.bosilu.dev/realtime',
  String issuer = 'https://auth.algaguard.bosilu.dev/realms/algaguard',
}) => AppEnvironment(
  flavor: EnvironmentFlavor.development,
  apiBaseUrl: Uri.parse(api),
  websocketUrl: Uri.parse(websocket),
  keycloakIssuer: Uri.parse(issuer),
  keycloakClientId: 'algaguard-mobile',
  redirectUri: 'com.algaguard.mobile:/oauthredirect',
  organizationId: '10000000-0000-4000-8000-000000000001',
);

void main() {
  test('trusted cloud HTTPS and WSS are accepted for release', () {
    expect(
      () => environment().validateForMode(releaseMode: true, localHttps: false),
      returnsNormally,
    );
  });

  test('release rejects localhost and plaintext API endpoints', () {
    for (final api in [
      'https://localhost:8443/api/v1',
      'http://example.test',
    ]) {
      expect(
        () => environment(
          api: api,
        ).validateForMode(releaseMode: true, localHttps: false),
        throwsStateError,
      );
    }
  });

  test('release rejects local flag and non-WSS realtime', () {
    expect(
      () => environment().validateForMode(releaseMode: true, localHttps: true),
      throwsStateError,
    );
    expect(
      () => environment(
        websocket: 'ws://realtime.example.test',
      ).validateForMode(releaseMode: true, localHttps: false),
      throwsStateError,
    );
    expect(
      () => environment(
        websocket: 'wss://realtime.algaguard.bosilu.dev',
      ).validateForMode(releaseMode: true, localHttps: false),
      throwsStateError,
    );
  });
}
