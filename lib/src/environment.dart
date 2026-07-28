import 'package:flutter/foundation.dart';

enum EnvironmentFlavor { development, staging, production }

class AppEnvironment {
  const AppEnvironment({
    required this.flavor,
    required this.apiBaseUrl,
    required this.websocketUrl,
    required this.keycloakIssuer,
    required this.keycloakClientId,
    required this.redirectUri,
    required this.organizationId,
  });
  final EnvironmentFlavor flavor;
  final Uri apiBaseUrl;
  final Uri websocketUrl;
  final Uri keycloakIssuer;
  final String keycloakClientId;
  final String redirectUri;
  final String organizationId;

  void validateForMode({required bool releaseMode, required bool localHttps}) {
    if (releaseMode && localHttps) {
      throw StateError('Local HTTPS development configuration is debug-only');
    }
    if (releaseMode) {
      final endpoints = [apiBaseUrl, keycloakIssuer];
      if (endpoints.any(
        (uri) =>
            uri.scheme != 'https' ||
            uri.host == 'localhost' ||
            uri.host == '127.0.0.1',
      )) {
        throw StateError(
          'Release HTTP endpoints must use trusted public HTTPS',
        );
      }
      if (websocketUrl.scheme != 'wss' ||
          websocketUrl.host == 'localhost' ||
          websocketUrl.host == '127.0.0.1') {
        throw StateError(
          'Release realtime endpoint must use trusted public WSS',
        );
      }
    }
  }

  static AppEnvironment fromDefines() {
    const localHttps = bool.fromEnvironment('ALGAGUARD_LOCAL_HTTPS_DEBUG');
    final environment = AppEnvironment(
      flavor: EnvironmentFlavor.values.byName(
        const String.fromEnvironment('FLAVOR', defaultValue: 'development'),
      ),
      apiBaseUrl: Uri.parse(
        const String.fromEnvironment(
          'API_BASE_URL',
          defaultValue: localHttps
              ? 'https://localhost:8443/api/v1'
              : 'http://10.0.2.2:8080/api/v1',
        ),
      ),
      websocketUrl: Uri.parse(
        const String.fromEnvironment(
          'WEBSOCKET_URL',
          defaultValue: 'ws://10.0.2.2:8080/realtime',
        ),
      ),
      keycloakIssuer: Uri.parse(
        const String.fromEnvironment(
          'KEYCLOAK_ISSUER',
          defaultValue: 'http://10.0.2.2:8080/auth/realms/algaguard',
        ),
      ),
      keycloakClientId: const String.fromEnvironment(
        'KEYCLOAK_CLIENT_ID',
        defaultValue: 'algaguard-mobile',
      ),
      redirectUri: const String.fromEnvironment(
        'OIDC_REDIRECT_URI',
        defaultValue: 'com.algaguard.mobile:/oauthredirect',
      ),
      organizationId: const String.fromEnvironment(
        'ORGANIZATION_ID',
        defaultValue: '10000000-0000-4000-8000-000000000001',
      ),
    );
    environment.validateForMode(
      releaseMode: kReleaseMode,
      localHttps: localHttps,
    );
    return environment;
  }
}
