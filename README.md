# AlgaGuard mobile app

Android-first, iOS-compatible Flutter client using Riverpod, Dio, secure token storage, Keycloak OIDC, QR validation, BLE provisioning abstraction, and native WebSocket recovery.

```sh
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
```

Wi-Fi credentials are held only for the active BLE provisioning call and are cleared immediately afterward. No real BLE peripheral or physical device has been validated yet.

The owned-device bootstrap recovery action is available only in a non-release
build compiled with `ALGAGUARD_ENABLE_PHYSICAL_SESSION_APPROVAL=true`. It calls
the authenticated reissue endpoint once for the selected existing claimed
device and moves the returned session directly into the existing in-memory
onboarding abstraction. It creates no claim/device/ownership record, persists
no bootstrap token, and navigates to `Development session approval`. Logout,
restart, terminal failure, and completion discard the in-memory session.
