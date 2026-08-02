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

The development QR flow is compiled only with
`ALGAGUARD_ENABLE_QR_ONBOARDING=true`. In that build, `Scan device QR` remains
available even when the selected organization has no devices. A valid physical
invitation is exchanged once using the authenticated organization-scoped v2
contract; the resulting bootstrap session and binding grant remain in memory
and feed the existing BLE provisioning controller. QR contents, session values,
and Wi-Fi values are never displayed, persisted, or logged. Release builds hide
the entry point, and the older owned-device/manual handoff path remains a
disabled fallback.

The authenticated organization experience includes Algae Profiles with
operator-defined minimum and maximum values for temperature, pH, light,
nitrate, phosphate, and potassium. Profiles use immutable versions and may be
assigned from each device page; assignment also queues the existing guarded
profile-configuration command. The device live-feed page refreshes from
authenticated realtime events and raises deduplicated in-app threshold alerts.
No profile value is presented as a scientific recommendation.

Organization owners and administrators can invite an existing account as an
Admin or Viewer. The recipient accepts or rejects the invitation from the
Organization access screen without copying an invitation token.
