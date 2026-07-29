import 'package:algaguard_mobile_app/src/environment.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:dio/dio.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

final environment = AppEnvironment(
  flavor: EnvironmentFlavor.development,
  apiBaseUrl: Uri.parse('https://api.algaguard.bosilu.dev/v1'),
  websocketUrl: Uri.parse('wss://realtime.algaguard.bosilu.dev/realtime'),
  keycloakIssuer: Uri.parse(
    'https://auth.algaguard.bosilu.dev/realms/algaguard',
  ),
  keycloakClientId: 'algaguard-mobile',
  redirectUri: 'com.algaguard.mobile:/oauthredirect',
  organizationId: '10000000-0000-4000-8000-000000000001',
);

class RecordingAppAuth extends FlutterAppAuth {
  AuthorizationTokenRequest? request;

  @override
  Future<AuthorizationTokenResponse> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  ) async {
    this.request = request;
    return AuthorizationTokenResponse(
      'access',
      'refresh',
      DateTime.utc(2030),
      'id-token',
      'Bearer',
      const ['openid', 'profile', 'email'],
      null,
      null,
    );
  }
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('Keycloak login always requests explicit account selection', () async {
    final appAuth = RecordingAppAuth();
    final store = const TokenStore(FlutterSecureStorage());
    await OidcClient(environment, store, appAuth: appAuth).login();
    expect(appAuth.request?.promptValues, const ['select_account']);
    expect(await store.readAccessToken(), 'access');
  });

  test('userinfo returns bounded visible account fields only', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(
            options.uri.toString(),
            'https://auth.algaguard.bosilu.dev/realms/algaguard/'
            'protocol/openid-connect/userinfo',
          );
          expect(options.headers['Authorization'], 'Bearer access');
          handler.resolve(
            Response<Object>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'sub': 'not-displayed',
                'name': 'Development User',
                'preferred_username': 'developer',
                'email': 'developer@example.test',
              },
            ),
          );
        },
      ),
    );
    FlutterSecureStorage.setMockInitialValues({'oidc_access_token': 'access'});
    final profile = await OidcClient(
      environment,
      const TokenStore(FlutterSecureStorage()),
      httpClient: dio,
    ).profile();
    expect(profile.primaryLabel, 'Development User');
    expect(profile.username, 'developer');
    expect(profile.email, 'developer@example.test');
  });

  test(
    'organizations can be listed and created through authenticated API',
    () async {
      final dio = Dio();
      var requestCount = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestCount += 1;
            expect(options.headers['Authorization'], 'Bearer access');
            expect(options.path, '/services/access/organizations');
            if (options.method == 'GET') {
              handler.resolve(
                Response<Object>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'items': [
                      {
                        'id': '10000000-0000-4000-8000-000000000001',
                        'name': 'Existing organization',
                      },
                    ],
                  },
                ),
              );
              return;
            }
            expect(options.method, 'POST');
            expect(options.data, {'name': 'New organization'});
            handler.resolve(
              Response<Object>(
                requestOptions: options,
                statusCode: 201,
                data: {
                  'id': '20000000-0000-4000-8000-000000000002',
                  'name': 'New organization',
                },
              ),
            );
          },
        ),
      );
      final api = PlatformApi(environment.apiBaseUrl, client: dio);
      final organizations = await api.listOrganizations(accessToken: 'access');
      final created = await api.createOrganization(
        accessToken: 'access',
        name: ' New organization ',
      );
      expect(organizations.single.name, 'Existing organization');
      expect(created.name, 'New organization');
      expect(requestCount, 2);
    },
  );

  test('selected organization is cleared with the signed-in session', () async {
    final store = const TokenStore(FlutterSecureStorage());
    await store.save(accessToken: 'access');
    await store.selectOrganization('10000000-0000-4000-8000-000000000001');
    expect(await store.readSelectedOrganization(), isNotNull);
    await store.clear();
    expect(await store.readAccessToken(), isNull);
    expect(await store.readSelectedOrganization(), isNull);
  });
}
