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

The QR pairing flow is compiled in by default (`ALGAGUARD_ENABLE_QR_ONBOARDING`
defaults to `true`; pass `--dart-define=ALGAGUARD_ENABLE_QR_ONBOARDING=false`
only for a build that must explicitly disable it). The "Pair device" floating
action button on the Devices screen is always available, even when the
selected organization has no devices yet, and stays available after pairing
any number of devices -- there is no per-organization device limit, so a
customer with several tanks scans each one's QR code from the same button in
turn. Each scan exchanges a valid physical invitation once using the
authenticated organization-scoped v2 contract; the resulting bootstrap session
and binding grant remain in memory and feed the existing BLE provisioning
controller. QR contents, session values, and Wi-Fi values are never displayed,
persisted, or logged. Unlike the owned-device bootstrap recovery action above,
this is the product's real device-onboarding flow, not a dev-only tool, so it
is available in release builds too. The older owned-device/manual handoff path
remains a disabled fallback regardless of build mode.

The authenticated organization experience includes Algae Profiles with
operator-defined minimum and maximum values for temperature, pH, light,
and nutrient value percentage. Profiles use immutable versions and may be
assigned from each device page; assignment also queues the existing guarded
profile-configuration command. The device live-feed page refreshes from
authenticated realtime events and raises deduplicated in-app threshold alerts.
No profile value is presented as a scientific recommendation.

Organization owners and administrators can invite an existing account as an
Admin or Viewer. The recipient accepts or rejects the invitation from the
Organization access screen without copying an invitation token.

Authentication persists through app and phone restarts by refreshing the
Keycloak offline session from platform secure storage. A transient network
failure keeps the saved session and presents a safe retry state; only explicit
logout clears it.

Closed-app threshold notifications use an optional FCM integration. Android
uses a local `android/app/google-services.json` file that is intentionally
ignored by Git; it is generated/downloaded from the selected Firebase project.
The build must explicitly enable:

- `ALGAGUARD_ENABLE_FCM=true`

The Firebase Android application file contains public application identifiers,
not the server service account. The service-account private key belongs only in
the deployment secret store. The app registers its FCM token only after
authentication, handles token rotation, and unregisters/deletes it on logout.
