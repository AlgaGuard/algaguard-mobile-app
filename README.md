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
