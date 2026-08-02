import 'package:algaguard_mobile_app/src/persistent_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'saved refresh token restores authentication without interactive login',
    () async {
      var refreshes = 0;
      var interactiveLogins = 0;
      final controller = PersistentAuthController(
        hasRefreshToken: () async => true,
        accessTokenExpiry: () async =>
            DateTime.now().toUtc().add(const Duration(hours: 1)),
        refresh: () async {
          refreshes += 1;
          return 'rotated-access-token';
        },
        login: () async => interactiveLogins += 1,
        logout: () async {},
      );
      await controller.restore();
      expect(controller.state, PersistentAuthState.authenticated);
      expect(refreshes, 1);
      expect(interactiveLogins, 0);
      controller.dispose();
    },
  );

  test('missing saved refresh token routes to signed out state', () async {
    final controller = PersistentAuthController(
      hasRefreshToken: () async => false,
      accessTokenExpiry: () async => null,
      refresh: () async => throw StateError('must not refresh'),
      login: () async {},
      logout: () async {},
    );
    await controller.restore();
    expect(controller.state, PersistentAuthState.signedOut);
    controller.dispose();
  });

  test(
    'temporary refresh failure does not perform destructive logout',
    () async {
      var logoutCalls = 0;
      final controller = PersistentAuthController(
        hasRefreshToken: () async => true,
        accessTokenExpiry: () async => null,
        refresh: () async => throw Exception('temporary network outage'),
        login: () async {},
        logout: () async => logoutCalls += 1,
      );
      await controller.restore();
      expect(controller.state, PersistentAuthState.unavailable);
      expect(logoutCalls, 0);
      controller.dispose();
    },
  );

  test('explicit logout is the only path that clears the session', () async {
    var logoutCalls = 0;
    final controller = PersistentAuthController(
      hasRefreshToken: () async => true,
      accessTokenExpiry: () async =>
          DateTime.now().toUtc().add(const Duration(hours: 1)),
      refresh: () async => 'access',
      login: () async {},
      logout: () async => logoutCalls += 1,
    );
    await controller.restore();
    await controller.signOut();
    expect(logoutCalls, 1);
    expect(controller.state, PersistentAuthState.signedOut);
    controller.dispose();
  });
}
