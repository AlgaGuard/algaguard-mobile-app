enum EnvironmentFlavor { development, staging, production }

class AppEnvironment {
  const AppEnvironment({
    required this.flavor,
    required this.apiBaseUrl,
    required this.websocketUrl,
    required this.keycloakIssuer,
    required this.keycloakClientId,
    required this.redirectUri,
  });
  final EnvironmentFlavor flavor;
  final Uri apiBaseUrl;
  final Uri websocketUrl;
  final Uri keycloakIssuer;
  final String keycloakClientId;
  final String redirectUri;
  static AppEnvironment fromDefines() => AppEnvironment(
    flavor: EnvironmentFlavor.values.byName(
      const String.fromEnvironment('FLAVOR', defaultValue: 'development'),
    ),
    apiBaseUrl: Uri.parse(
      const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'http://10.0.2.2:8080/api/v1',
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
  );
}
