import 'dart:async';

import 'package:algaguard_mobile_app/src/app_shell.dart';
import 'package:algaguard_mobile_app/src/environment.dart';
import 'package:algaguard_mobile_app/src/demo_telemetry.dart';
import 'package:algaguard_mobile_app/src/demo_telemetry_view.dart';
import 'package:algaguard_mobile_app/src/onboarding.dart';
import 'package:algaguard_mobile_app/src/physical_session_handoff.dart';
import 'package:algaguard_mobile_app/src/realtime_controller.dart';
import 'package:algaguard_mobile_app/src/secure_transport_preflight.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:algaguard_mobile_app/src/qr_onboarding.dart';
import 'package:algaguard_mobile_app/src/ble_provisioning_wire.dart';
import 'package:algaguard_mobile_app/src/brand_logo.dart';
import 'package:algaguard_mobile_app/src/algae_profiles.dart';
import 'package:algaguard_mobile_app/src/algae_profiles_screen.dart';
import 'package:algaguard_mobile_app/src/organization_access_screen.dart';
import 'package:algaguard_mobile_app/src/persistent_auth.dart';
import 'package:algaguard_mobile_app/src/theme.dart';
import 'package:algaguard_mobile_app/src/push_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

final environmentProvider = Provider<AppEnvironment>(
  (_) => AppEnvironment.fromDefines(),
);

final tokenStoreProvider = Provider<TokenStore>(
  (_) => const TokenStore(FlutterSecureStorage()),
);

final authSessionProvider = ChangeNotifierProvider<PersistentAuthController>((
  ref,
) {
  final environment = ref.watch(environmentProvider);
  final store = ref.watch(tokenStoreProvider);
  final oidc = OidcClient(environment, store);
  final controller = PersistentAuthController(
    hasRefreshToken: () async => await store.readRefreshToken() != null,
    accessTokenExpiry: store.readAccessTokenExpiry,
    refresh: oidc.refresh,
    login: oidc.login,
    logout: oidc.logout,
  );
  return controller;
});

final pushNotificationProvider =
    ChangeNotifierProvider<PushNotificationController>((ref) {
      final environment = ref.watch(environmentProvider);
      final store = ref.watch(tokenStoreProvider);
      final controller = PushNotificationController(
        enabled: environment.fcm.enabled,
        messaging: FirebasePushMessaging(environment.fcm),
        store: store,
        api: PlatformApi(environment.apiBaseUrl),
        accessToken: store.readAccessToken,
      );
      return controller;
    });

final realtimeControllerProvider =
    ChangeNotifierProvider<RealtimeSessionController>((ref) {
      final environment = ref.watch(environmentProvider);
      final store = const TokenStore(FlutterSecureStorage());
      final api = PlatformApi(environment.apiBaseUrl);
      final controller = RealtimeSessionController(
        url: environment.websocketUrl,
        accessToken: store.readAccessToken,
        requestTicket: (accessToken) =>
            api.requestRealtimeTicket(accessToken: accessToken),
        recover: () async {
          // HTTPS remains authoritative whenever the socket is established.
          await OidcClient(environment, store).profile();
        },
        subscriptions: () async {
          final organizationId = await store.readSelectedOrganization();
          if (organizationId == null) {
            return [
              <String, Object>{
                'resourceType': 'current-user',
                'events': <String>['system.notification'],
              },
            ];
          }
          return [
            <String, Object>{
              'resourceType': 'organization',
              'resourceId': organizationId,
              'events': <String>['telemetry.updated'],
            },
            <String, Object>{
              'resourceType': 'current-user',
              'events': <String>['system.notification'],
            },
          ];
        },
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

final rootNavigatorKey = GlobalKey<NavigatorState>();
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await registerFirebaseBackgroundHandler(AppEnvironment.fromDefines().fcm);
  runApp(const ProviderScope(child: AlgaGuardApp()));
}

class AlgaGuardApp extends ConsumerStatefulWidget {
  const AlgaGuardApp({super.key});

  @override
  ConsumerState<AlgaGuardApp> createState() => _AlgaGuardAppState();
}

class _AlgaGuardAppState extends ConsumerState<AlgaGuardApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(() async {
        await ref.read(authSessionProvider).resumed();
        if (ref.read(authSessionProvider).state ==
            PersistentAuthState.authenticated) {
          await ref.read(pushNotificationProvider).activate();
        }
      }());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pushNotificationProvider, (_, controller) {
      final message = controller.foregroundAlert;
      if (message == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(message)),
        );
        controller.clearForegroundAlert();
      });
    });
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      title: 'AlgaGuard',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routes: {
        '/': (_) => const SplashScreen(),
        '/login': (_) => const LoginScreen(),
        '/organizations': (_) => const OrganizationScreen(),
        '/home': (_) => const AppShell(),
        '/overview': (_) => const OverviewScreen(),
        '/alerts': (_) => const AlertsScreen(),
        '/devices': (_) => const DevicesScreen(),
        '/device': (_) => const DeviceDetailsScreen(),
        '/readings': (_) => const DeviceReadingsScreen(),
        '/profiles': (_) => AlgaeProfilesScreen(
          apiBaseUrl: ref.read(environmentProvider).apiBaseUrl,
        ),
        '/organization-access': (_) => OrganizationAccessScreen(
          apiBaseUrl: ref.read(environmentProvider).apiBaseUrl,
        ),
        '/ota': (_) => const OtaScreen(),
        '/account': (_) => const AccountScreen(),
        if (secureTransportPreflightAvailable())
          '/secure-transport': (_) => SecureTransportPreflightScreen(
            controller: SecureTransportPreflightController(
              PlatformApi(ref.read(environmentProvider).apiBaseUrl),
            ),
          ),
      },
    );
  }
}

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  bool _navigationScheduled = false;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() => ref.read(authSessionProvider).restore());
  }

  void _navigate(String route) {
    if (_navigationScheduled) return;
    _navigationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      var destination = route;
      if (route == '/organizations') {
        unawaited(ref.read(pushNotificationProvider).activate());
        final store = ref.read(tokenStoreProvider);
        final selected = await store.readSelectedOrganization();
        if (selected != null) {
          // A previously-selected organization can vanish server-side
          // (deleted, membership revoked) while it stays cached locally --
          // without this check we'd silently keep sending requests scoped
          // to a dead organization forever, with no path back to the
          // picker. Validate it against the user's actual memberships
          // before trusting it.
          var stillValid = false;
          try {
            final token = await store.readAccessToken();
            if (token != null) {
              final organizations = await PlatformApi(
                ref.read(environmentProvider).apiBaseUrl,
              ).listOrganizations(accessToken: token);
              stillValid = organizations.any((org) => org.id == selected);
            }
          } catch (_) {
            // Network/API failure: keep the cached selection rather than
            // bouncing the user to the picker on a transient error.
            stillValid = true;
          }
          if (stillValid) {
            destination = '/home';
          } else {
            await store.clearSelectedOrganization();
          }
        }
      }
      if (mounted) Navigator.of(context).pushReplacementNamed(destination);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authSessionProvider).state;
    if (state == PersistentAuthState.authenticated) {
      _navigate('/organizations');
    } else if (state == PersistentAuthState.signedOut) {
      _navigate('/login');
    }
    // The wordmark's artwork is dark ink on transparent, so the splash
    // screen stays on the light theme regardless of the system setting.
    return Theme(
      data: AppTheme.light,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AlgaGuardBrandLogo(size: 180, withWordmark: true),
              const SizedBox(height: 20),
              if (state == PersistentAuthState.checking)
                const CircularProgressIndicator()
              else if (state == PersistentAuthState.unavailable) ...[
                const Text('Your saved session could not be refreshed yet.'),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () {
                    _navigationScheduled = false;
                    ref.read(authSessionProvider).restore();
                  },
                  child: const Text('Retry securely'),
                ),
                TextButton(
                  onPressed: () => _navigate('/login'),
                  child: const Text('Sign in again'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _working = false;
  String? _error;
  Future<void> _login() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await ref.read(authSessionProvider).signIn();
      unawaited(ref.read(pushNotificationProvider).activate());
      if (mounted) Navigator.of(context).pushReplacementNamed('/organizations');
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Keycloak sign-in did not complete. Confirm local redirect settings and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AlgaGuard sign in')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Use the configured Keycloak account. Tokens are stored only in platform secure storage.',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _working ? null : _login,
            icon: const Icon(Icons.login),
            label: Text(
              _working ? 'Opening Keycloak…' : 'Sign in with Keycloak',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );
}

class OrganizationScreen extends ConsumerStatefulWidget {
  const OrganizationScreen({super.key});

  @override
  ConsumerState<OrganizationScreen> createState() => _OrganizationScreenState();
}

class _OrganizationScreenState extends ConsumerState<OrganizationScreen> {
  final _store = const TokenStore(FlutterSecureStorage());
  List<OrganizationSummary> _organizations = const [];
  OidcUserProfile? _profile;
  bool _loading = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final environment = ref.read(environmentProvider);
      final token = await _store.readAccessToken();
      if (token == null) throw StateError('Sign in is required');
      final results = await Future.wait<Object>([
        OidcClient(environment, _store).profile(),
        PlatformApi(
          environment.apiBaseUrl,
        ).listOrganizations(accessToken: token),
      ]);
      if (!mounted) return;
      setState(() {
        _profile = results[0] as OidcUserProfile;
        _organizations = results[1] as List<OrganizationSummary>;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Account or organizations could not be loaded securely.';
      });
    }
  }

  Future<void> _createOrganization() async {
    var proposedName = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create organization'),
        content: TextField(
          autofocus: true,
          maxLength: 120,
          onChanged: (value) => proposedName = value,
          onSubmitted: (value) => Navigator.pop(context, value),
          decoration: const InputDecoration(labelText: 'Organization name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, proposedName),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final environment = ref.read(environmentProvider);
      final token = await _store.readAccessToken();
      if (token == null) throw StateError('Sign in is required');
      final created = await PlatformApi(
        environment.apiBaseUrl,
      ).createOrganization(accessToken: token, name: name);
      if (!mounted) return;
      setState(() {
        _organizations = [..._organizations, created];
        _creating = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = 'Organization could not be created.';
      });
    }
  }

  Future<void> _select(OrganizationSummary organization) async {
    await _store.selectOrganization(organization.id);
    if (mounted) Navigator.of(context).pushReplacementNamed('/home');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Select organization'),
      actions: [
        IconButton(
          tooltip: 'Account',
          onPressed: () => Navigator.of(context).pushNamed('/account'),
          icon: const Icon(Icons.account_circle),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_profile != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(_profile!.primaryLabel),
              subtitle: _profile!.email == null
                  ? const Text('Signed in with Keycloak')
                  : Text(_profile!.email!),
            ),
          ),
        if (_loading) const Center(child: CircularProgressIndicator()),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        for (final organization in _organizations)
          Card(
            child: ListTile(
              leading: const Icon(Icons.business_outlined),
              title: Text(organization.name),
              subtitle: organization.currentUserRole == null
                  ? null
                  : Text(organization.currentUserRole!),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _select(organization),
            ),
          ),
        if (!_loading && _organizations.isEmpty)
          const Card(
            child: ListTile(
              title: Text('No organizations yet'),
              subtitle: Text('Create one to begin adding devices.'),
            ),
          ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _loading || _creating ? null : _createOrganization,
          icon: const Icon(Icons.add_business),
          label: Text(
            _creating ? 'Creating organization...' : 'Create organization',
          ),
        ),
        const SizedBox(height: 12),
        const Card(
          child: ListTile(
            title: Text('Secure organization access'),
            subtitle: Text(
              'Only organizations authorized for the signed-in account are shown.',
            ),
          ),
        ),
      ],
    ),
  );
}

class OverviewScreen extends ConsumerStatefulWidget {
  const OverviewScreen({super.key});

  @override
  ConsumerState<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends ConsumerState<OverviewScreen> {
  final _store = const TokenStore(FlutterSecureStorage());
  bool _loading = true;
  String? _error;
  List<(OrganizationSummary, List<DeviceSummary>)> _groups = const [];
  Map<String, DemoTelemetryReading> _latest = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final environment = ref.read(environmentProvider);
      final token = await _store.readAccessToken();
      if (token == null) throw StateError('Sign in is required');
      final api = PlatformApi(environment.apiBaseUrl);
      final organizations = await api.listOrganizations(accessToken: token);
      final groups = <(OrganizationSummary, List<DeviceSummary>)>[];
      for (final organization in organizations) {
        final devices = await api.listDevices(
          accessToken: token,
          organizationId: organization.id,
        );
        groups.add((organization, devices));
      }
      final deviceUuids = groups
          .expand((group) => group.$2.map((device) => device.deviceUuid))
          .toList(growable: false);
      final latest = await api.latestTelemetryBatch(
        accessToken: token,
        deviceUuids: deviceUuids,
      );
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _latest = latest;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Devices across organizations could not be loaded.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _summaryFor(String deviceUuid) {
    final reading = _latest[deviceUuid];
    if (reading == null) return 'No data yet';
    return '${reading.temperatureC.toStringAsFixed(1)} °C · pH ${reading.ph.toStringAsFixed(1)}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Overview')),
    body: RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          for (final group in _groups) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                group.$1.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final device in group.$2)
              ListTile(
                leading: const Icon(Icons.memory),
                title: Text(device.visibleName),
                subtitle: Text(_summaryFor(device.deviceUuid)),
              ),
            if (group.$2.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('No devices yet.'),
              ),
          ],
          if (!_loading && _groups.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No authorized organizations are available.'),
            ),
        ],
      ),
    ),
  );
}

class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  final _store = const TokenStore(FlutterSecureStorage());
  bool _loading = true;
  String? _error;
  List<AlertRecord> _alerts = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final environment = ref.read(environmentProvider);
      final token = await _store.readAccessToken();
      final organizationId = await _store.readSelectedOrganization();
      if (token == null || organizationId == null) {
        throw StateError('Authenticated organization is required');
      }
      final alerts = await PlatformApi(environment.apiBaseUrl)
          .listOrganizationAlerts(
            accessToken: token,
            organizationId: organizationId,
          );
      if (mounted) setState(() => _alerts = alerts);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Alert history could not be loaded.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _occurredLabel(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$month/$day $hour:$minute';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Alerts')),
    body: ListView(
      children: [
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        for (final alert in _alerts)
          ListTile(
            leading: Icon(
              Icons.warning_amber_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text('${alert.deviceId} · ${alert.parameter}'),
            subtitle: Text(
              alert.direction == 'HIGH'
                  ? '${alert.value} above maximum ${alert.maximum ?? '—'}'
                  : '${alert.value} below minimum ${alert.minimum ?? '—'}',
            ),
            trailing: Text(_occurredLabel(alert.occurredAt)),
          ),
        if (!_loading && _alerts.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No alerts recorded yet.'),
          ),
      ],
    ),
  );
}

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  final _store = const TokenStore(FlutterSecureStorage());
  List<DeviceSummary> _devices = const [];
  bool _loading = true;
  bool _preparing = false;
  bool _attempted = false;
  String? _error;
  BootstrapReissueFailureCategory? _reissueFailureCategory;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<(PlatformApi, String, String)> _authorizedContext() async {
    final token = await _store.readAccessToken();
    final organizationId = await _store.readSelectedOrganization();
    if (token == null || organizationId == null) {
      throw StateError('Authenticated organization is required');
    }
    return (
      PlatformApi(ref.read(environmentProvider).apiBaseUrl),
      token,
      organizationId,
    );
  }

  Future<void> _load() async {
    try {
      final authorized = await _authorizedContext();
      final devices = await authorized.$1.listDevices(
        accessToken: authorized.$2,
        organizationId: authorized.$3,
      );
      if (mounted) setState(() => _devices = devices);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Authorized devices could not be loaded.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  DeviceSummary? get _expectedOwnedPhysicalDevice {
    final matches = _devices
        .where(
          (device) =>
              device.deviceId == 'AG-000001' && device.lifecycle == 'CLAIMED',
        )
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  Future<void> _preparePhysicalOnboarding(DeviceSummary device) async {
    if (_preparing || _attempted) return;
    PreparedPhysicalOnboarding? pending;
    setState(() {
      _preparing = true;
      _attempted = true;
      _error = null;
      _reissueFailureCategory = null;
    });
    try {
      final authorized = await _authorizedContext();
      final prepared = await authorized.$1.reissueOwnedDeviceBootstrapSession(
        accessToken: authorized.$2,
        device: device,
      );
      pending = prepared;
      if (!mounted) {
        prepared.session.clear();
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PhysicalSessionApprovalScreen(
            controller: PhysicalSessionApprovalController(
              api: authorized.$1,
              accessToken: authorized.$2,
              session: prepared.session,
              enabled: true,
            ),
            onApproved: (approvalContext, session) {
              Navigator.of(approvalContext).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => BleProvisioningScreen(
                    claim: prepared.claim,
                    session: session,
                  ),
                ),
              );
            },
          ),
        ),
      );
      pending = null;
    } on BootstrapReissueException catch (error) {
      pending?.session.clear();
      if (mounted) {
        setState(() {
          _reissueFailureCategory = error.category;
          _error =
              'Bootstrap session was not prepared. Stop this one-shot attempt.';
        });
      }
    } catch (_) {
      pending?.session.clear();
      if (mounted) {
        setState(() {
          _reissueFailureCategory =
              BootstrapReissueFailureCategory.unexpectedFailure;
          _error =
              'Bootstrap session was not prepared. Stop this one-shot attempt.';
        });
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Devices')),
    body: ListView(
      children: [
        if (_loading) const LinearProgressIndicator(),
        for (final device in _devices)
          ListTile(
            title: Text(device.visibleName),
            subtitle: Text('${device.lifecycle} · authorized HTTPS state'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DeviceDetailsScreen(device: device),
              ),
            ),
          ),
        if (!_loading && _devices.isEmpty)
          const ListTile(title: Text('No devices in this organization')),
        if (qrOnboardingAvailable(releaseMode: kReleaseMode))
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: () async {
                final authorized = await _authorizedContext();
                if (!context.mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => QrOnboardingScanScreen(
                      api: authorized.$1,
                      accessToken: authorized.$2,
                      organizationId: authorized.$3,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan device QR'),
            ),
          ),
        if (!qrOnboardingAvailable(releaseMode: kReleaseMode) &&
            physicalSessionApprovalAvailable(releaseMode: kReleaseMode))
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed:
                  _preparing ||
                      _attempted ||
                      _expectedOwnedPhysicalDevice == null
                  ? null
                  : () => _preparePhysicalOnboarding(
                      _expectedOwnedPhysicalDevice!,
                    ),
              icon: const Icon(Icons.developer_board),
              label: Text(
                _preparing
                    ? 'Reissuing bootstrap session…'
                    : 'Reissue development bootstrap session',
              ),
            ),
          ),
        if (!qrOnboardingAvailable(releaseMode: kReleaseMode) &&
            physicalSessionApprovalAvailable(releaseMode: kReleaseMode) &&
            _expectedOwnedPhysicalDevice != null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Development session approval available'),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              key: ValueKey(_reissueFailureCategory),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Devices shown here come only from the authorized platform API.',
          ),
        ),
      ],
    ),
  );
}

class QrOnboardingScanScreen extends StatefulWidget {
  const QrOnboardingScanScreen({
    super.key,
    required this.api,
    required this.accessToken,
    required this.organizationId,
  });

  final PlatformApi api;
  final String accessToken;
  final String organizationId;

  @override
  State<QrOnboardingScanScreen> createState() => _QrOnboardingScanScreenState();
}

class _QrOnboardingScanScreenState extends State<QrOnboardingScanScreen> {
  QrOnboardingScanState _state = QrOnboardingScanState.scanning;
  QrOnboardingExchangeFailure? _exchangeFailure;
  bool _handled = false;
  bool get _canScanAgain =>
      _state == QrOnboardingScanState.expired ||
      _state == QrOnboardingScanState.unsupported ||
      _state == QrOnboardingScanState.failed;

  String get _safeStateText => switch (_state) {
    QrOnboardingScanState.scanning => 'Scanning',
    QrOnboardingScanState.detected => 'Device invitation detected',
    QrOnboardingScanState.expired => 'Invitation expired',
    QrOnboardingScanState.unsupported => 'Unsupported invitation',
    QrOnboardingScanState.preparing => 'Preparing secure onboarding',
    QrOnboardingScanState.ready => 'Connect to AlgaGuard-Setup',
    QrOnboardingScanState.failed => switch (_exchangeFailure) {
      QrOnboardingExchangeFailure.replayed =>
        'This setup QR was already used. Show a fresh QR on the device.',
      QrOnboardingExchangeFailure.deviceNotEligible =>
        'This device cannot be set up in its current state.',
      QrOnboardingExchangeFailure.pairedWithAnotherOrganization =>
        'This device is currently paired with another organization.',
      QrOnboardingExchangeFailure.authorization =>
        'Your account is not allowed to set up this device.',
      _ =>
        'Secure onboarding is temporarily unavailable. Scan a fresh QR and try again.',
    },
  };

  Future<void> _accept(String raw) async {
    if (_handled) return;
    _handled = true;
    QrOnboardingInvitation invitation;
    try {
      invitation = QrOnboardingCodec.decode(raw);
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _state = error.message == 'INVITATION_EXPIRED'
              ? QrOnboardingScanState.expired
              : QrOnboardingScanState.unsupported;
          _handled = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _state = QrOnboardingScanState.detected);
    try {
      if (mounted) setState(() => _state = QrOnboardingScanState.preparing);
      final devices = await widget.api.listDevices(
        accessToken: widget.accessToken,
        organizationId: widget.organizationId,
      );
      final matches = devices
          .where((device) => device.deviceId == invitation.deviceId)
          .toList(growable: false);
      if (matches.length > 1) throw StateError('Duplicate device binding');
      final prepared = await widget.api.exchangeQrOnboarding(
        accessToken: widget.accessToken,
        device: matches.isEmpty ? null : matches.single,
        organizationId: matches.isEmpty ? widget.organizationId : null,
        invitation: invitation,
      );
      if (!mounted) {
        prepared.session.clear();
        return;
      }
      setState(() => _state = QrOnboardingScanState.ready);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => BleProvisioningScreen(
            claim: prepared.claim,
            session: prepared.session,
            retryScreenBuilder: (_) => QrOnboardingScanScreen(
              api: widget.api,
              accessToken: widget.accessToken,
              organizationId: widget.organizationId,
            ),
          ),
        ),
      );
    } on QrOnboardingExchangeException catch (error) {
      if (mounted) {
        setState(() {
          _exchangeFailure = error.failure;
          _state = error.failure == QrOnboardingExchangeFailure.expired
              ? QrOnboardingScanState.expired
              : QrOnboardingScanState.failed;
          _handled = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _state = QrOnboardingScanState.failed;
          _handled = false;
        });
      }
    }
  }

  void _scanFreshQr() {
    setState(() {
      _handled = false;
      _exchangeFailure = null;
      _state = QrOnboardingScanState.scanning;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan device QR')),
    body: Column(
      children: [
        Expanded(
          child: _handled
              ? const Center(
                  child: Icon(Icons.verified_user_outlined, size: 72),
                )
              : MobileScanner(
                  onDetect: (capture) {
                    final raw = capture.barcodes.isEmpty
                        ? null
                        : capture.barcodes.first.rawValue;
                    if (raw != null) _accept(raw);
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_safeStateText, key: const Key('qr-onboarding-state')),
              if (_canScanAgain) ...[
                const SizedBox(height: 12),
                const Text(
                  'Press Select on the ESP32 for a fresh QR, then scan again.',
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _scanFreshQr,
                  child: const Text('Scan fresh QR'),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class ScanQrScreen extends StatefulWidget {
  const ScanQrScreen({super.key});
  @override
  State<ScanQrScreen> createState() => _ScanQrScreenState();
}

class _ScanQrScreenState extends State<ScanQrScreen> {
  final _fallback = TextEditingController();
  String? _message;
  bool _handled = false;
  void _accept(String raw) {
    if (_handled) return;
    try {
      final claim = QrClaim.parse(raw);
      _handled = true;
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ClaimScreen(claim: claim)),
      );
    } on FormatException {
      setState(
        () => _message =
            'This setup QR is invalid, expired, used, or not for AlgaGuard.',
      );
    }
  }

  @override
  void dispose() {
    _fallback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Add device')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Scan the short-lived QR displayed by the AlgaGuard device. '
              'It identifies the device invitation; it does not contain Wi-Fi credentials.',
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 260,
          child: MobileScanner(
            onDetect: (capture) {
              final raw = capture.barcodes.isEmpty
                  ? null
                  : capture.barcodes.first.rawValue;
              if (raw != null) _accept(raw);
            },
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _fallback,
          decoration: const InputDecoration(
            labelText: 'Fallback setup payload',
          ),
          minLines: 2,
          maxLines: 4,
        ),
        FilledButton(
          onPressed: () => _accept(_fallback.text),
          child: const Text('Validate fallback code'),
        ),
        if (_message != null)
          Text(
            _message!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}

class ClaimScreen extends ConsumerStatefulWidget {
  const ClaimScreen({super.key, required this.claim});
  final QrClaim claim;
  @override
  ConsumerState<ClaimScreen> createState() => _ClaimScreenState();
}

class _ClaimScreenState extends ConsumerState<ClaimScreen> {
  bool _working = false;
  String? _error;
  Future<void> _claim() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final environment = ref.read(environmentProvider);
      final token = await const TokenStore(
        FlutterSecureStorage(),
      ).readAccessToken();
      if (token == null) throw StateError('Sign in is required');
      final organizationId = await const TokenStore(
        FlutterSecureStorage(),
      ).readSelectedOrganization();
      if (organizationId == null) {
        throw StateError('Organization selection is required');
      }
      final api = PlatformApi(environment.apiBaseUrl);
      final session = await api.consumeClaim(
        accessToken: token,
        organizationId: organizationId,
        claim: widget.claim,
      );
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) =>
                physicalSessionApprovalAvailable(releaseMode: kReleaseMode)
                ? PhysicalSessionApprovalScreen(
                    controller: PhysicalSessionApprovalController(
                      api: api,
                      accessToken: token,
                      session: session,
                      enabled: true,
                    ),
                    onApproved: (approvalContext, approvedSession) {
                      Navigator.of(approvalContext).pushReplacement(
                        MaterialPageRoute<void>(
                          builder: (_) => BleProvisioningScreen(
                            claim: widget.claim,
                            session: approvedSession,
                          ),
                        ),
                      );
                    },
                  )
                : BleProvisioningScreen(claim: widget.claim, session: session),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Claim was not accepted. It may be expired, used, or unauthorized.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Confirm device claim')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Claim ${widget.claim.deviceId}?'),
          const SizedBox(height: 8),
          const Text(
            'The one-time claim code is sent only to HTTPS and is never retained or displayed.',
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _working ? null : _claim,
            child: Text(_working ? 'Claiming…' : 'Claim device'),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
  );
}

class BleProvisioningScreen extends ConsumerStatefulWidget {
  const BleProvisioningScreen({
    super.key,
    required this.claim,
    required this.session,
    this.retryScreenBuilder,
    this.cloudReadinessProbe,
  });
  final QrClaim claim;
  final ProvisioningSession session;
  final WidgetBuilder? retryScreenBuilder;
  final Future<DeviceCloudReadiness> Function()? cloudReadinessProbe;
  @override
  ConsumerState<BleProvisioningScreen> createState() =>
      _BleProvisioningScreenState();
}

class _BleProvisioningScreenState extends ConsumerState<BleProvisioningScreen> {
  final _ssid = TextEditingController();
  final _password = TextEditingController();
  String _state = 'Ready to discover the matching AlgaGuard BLE service.';
  bool _working = false;
  bool _freshAttemptRequested = false;
  bool _cloudReady = false;
  Future<void> _provision() async {
    setState(() {
      _working = true;
      _state = 'Connecting to matching BLE device…';
    });
    final controller = ProvisioningController(FlutterBlueProvisioner());
    try {
      await controller.provision(
        widget.claim,
        widget.session,
        _ssid.text,
        _password.text,
        onStatus: (status) {
          if (mounted) setState(() => _state = status.uiText);
        },
      );
      if (mounted) {
        setState(() => _state = 'Accepted by device. Verifying cloud setup...');
      }
      final readiness = await _waitForCloudReadiness();
      if (mounted) {
        setState(() {
          _cloudReady = readiness == DeviceCloudReadiness.ready;
          _state = switch (readiness) {
            DeviceCloudReadiness.ready => 'Device connected to cloud.',
            DeviceCloudReadiness.timedOut =>
              'Wi-Fi was accepted, but cloud setup did not finish in time.',
            DeviceCloudReadiness.unavailable =>
              'Wi-Fi was accepted, but cloud setup could not be verified.',
          };
        });
      }
    } on BleProvisioningWireException catch (error) {
      if (mounted) {
        setState(
          () => _state =
              'Provisioning failed safely: ${_safeBleFailureText(error.code)}.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _state =
              'Provisioning failed safely: ${_safeUnexpectedProvisioningFailure(error)}.',
        );
      }
    } finally {
      _password.clear();
      if (mounted) setState(() => _working = false);
    }
  }

  Future<DeviceCloudReadiness> _waitForCloudReadiness() async {
    if (widget.cloudReadinessProbe != null) {
      return widget.cloudReadinessProbe!();
    }
    final store = const TokenStore(FlutterSecureStorage());
    final token = await store.readAccessToken();
    final organizationId = await store.readSelectedOrganization();
    if (token == null || organizationId == null) {
      return DeviceCloudReadiness.unavailable;
    }
    return PlatformApi(
      ref.read(environmentProvider).apiBaseUrl,
    ).waitForDeviceCloudReadiness(
      accessToken: token,
      organizationId: organizationId,
      deviceId: widget.claim.deviceId,
    );
  }

  String _safeBleFailureText(String code) => switch (code) {
    'SERVICE_NOT_FOUND' => 'BLE service not found',
    'REQUEST_CHARACTERISTIC_NOT_FOUND' => 'request characteristic missing',
    'STATUS_CHARACTERISTIC_NOT_FOUND' => 'status characteristic missing',
    'REQUIRED_PROPERTIES_MISMATCH' => 'BLE service shape mismatch',
    'DISCONNECTED' => 'device disconnected',
    'STATUS_TOO_LARGE' || 'UNSAFE_STATUS' => 'unsafe device status',
    'INVALID_PROVISIONING_FIELDS' => 'invalid local input',
    'PAYLOAD_TOO_LARGE' => 'request too large',
    'INVALID_FRAME_INPUT' => 'BLE frame preparation failed',
    'MESSAGE_ID_UNAVAILABLE' => 'message identifier unavailable',
    'EXPIRED' => 'session expired',
    'REPLAYED' => 'session replay rejected',
    'DEVICE_MISMATCH' => 'device mismatch',
    'SESSION_REJECTED' => 'session rejected',
    'TIMED_OUT' => 'device timed out',
    'CANCELLED' => 'device cancelled',
    _ => 'device rejected provisioning',
  };

  String _safeUnexpectedProvisioningFailure(Object error) {
    if (error is FlutterBluePlusException) {
      return switch (error.function) {
        'scan' => 'Bluetooth scan failed',
        'connect' => 'BLE connection failed',
        'discoverServices' => 'BLE service discovery failed',
        'readCharacteristic' => 'BLE status read failed',
        'writeCharacteristic' => 'BLE frame write failed',
        'setNotifyValue' => 'BLE notifications failed',
        _ => 'Bluetooth operation failed',
      };
    }
    if (error is TimeoutException) return 'BLE operation timed out';
    if (error is FormatException) return 'local provisioning data invalid';
    if (error is PlatformException) {
      // Covers native BLE stack failures flutter_blue_plus doesn't wrap
      // itself, most commonly Android GATT status 133 (a well-known,
      // usually transient radio/stack-level connection failure). Naming it
      // instead of falling into the generic bucket makes "just retry" the
      // obviously correct next step rather than looking like a protocol bug.
      return 'Bluetooth connection failed at the device level (code '
          '${error.code}) — this is usually transient, try again';
    }
    return 'unexpected BLE operation failure';
  }

  void _startOverWithFreshQr() {
    widget.session.clear();
    _ssid.clear();
    _password.clear();
    if (widget.retryScreenBuilder != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: widget.retryScreenBuilder!),
      );
      return;
    }
    setState(() {
      _freshAttemptRequested = true;
      _state =
          'Current onboarding session cleared. Press Select on the ESP32 for a fresh QR, then scan again from Devices.';
    });
  }

  @override
  void dispose() {
    widget.session.clear();
    _ssid.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('BLE Wi-Fi provisioning')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_state),
        const SizedBox(height: 12),
        TextField(
          controller: _ssid,
          decoration: const InputDecoration(labelText: 'Wi-Fi SSID'),
        ),
        TextField(
          controller: _password,
          decoration: const InputDecoration(labelText: 'Wi-Fi password'),
          obscureText: true,
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _working ? null : _provision,
          child: Text(_working ? 'Provisioning…' : 'Send credentials over BLE'),
        ),
        if (_cloudReady) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _working ? null : _openDeviceSetup,
            icon: const Icon(Icons.tune),
            label: const Text('Name device and create profile'),
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _working ? null : _startOverWithFreshQr,
          child: const Text('Start over with fresh QR'),
        ),
        if (_freshAttemptRequested)
          const Text(
            'The previous session was cleared locally and cannot be reused.',
          ),
        const SizedBox(height: 12),
        const Text(
          'Password remains only in this form for the active BLE call and is cleared after success or failure. Real BLE requires a phone and ESP32-S3.',
        ),
      ],
    ),
  );

  Future<void> _openDeviceSetup() async {
    final store = const TokenStore(FlutterSecureStorage());
    final token = await store.readAccessToken();
    final organizationId = await store.readSelectedOrganization();
    if (token == null || organizationId == null || !mounted) return;
    try {
      final devices = await PlatformApi(
        ref.read(environmentProvider).apiBaseUrl,
      ).listDevices(accessToken: token, organizationId: organizationId);
      final device = devices.singleWhere(
        (candidate) => candidate.deviceId == widget.claim.deviceId,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => DeviceSetupScreen(device: device),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _state = 'Device setup is temporarily unavailable.');
      }
    }
  }
}

class DeviceSetupScreen extends ConsumerStatefulWidget {
  const DeviceSetupScreen({super.key, required this.device});

  final DeviceSummary device;

  @override
  ConsumerState<DeviceSetupScreen> createState() => _DeviceSetupScreenState();
}

class _DeviceSetupScreenState extends ConsumerState<DeviceSetupScreen> {
  final _store = const TokenStore(FlutterSecureStorage());
  late final TextEditingController _deviceName;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _deviceName = TextEditingController(text: widget.device.displayName ?? '');
  }

  Future<void> _save() async {
    if (_saving) return;
    final deviceName = _deviceName.text.trim();
    if (deviceName.isEmpty) {
      setState(() => _error = 'Enter a device name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final token = await _store.readAccessToken();
      final organizationId = await _store.readSelectedOrganization();
      if (token == null || organizationId == null) {
        throw StateError('Authentication required');
      }
      final api = PlatformApi(ref.read(environmentProvider).apiBaseUrl);
      await api.updateDeviceName(
        accessToken: token,
        deviceUuid: widget.device.deviceUuid,
        displayName: deviceName,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Device name saved. Select its Algae Profile from device settings.',
          ),
        ),
      );
      Navigator.of(context).pushNamedAndRemoveUntil('/devices', (_) => false);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Device setup was not saved. Check your owner/admin access and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _deviceName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Set up device')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          key: const Key('device-name-field'),
          controller: _deviceName,
          maxLength: 64,
          decoration: const InputDecoration(labelText: 'Device name'),
        ),
        const Text(
          'After saving, select an existing Algae Profile from the device page. Create profiles from the Algae Profiles menu.',
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('save-device-setup'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save device setup'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );
}

class DeviceReadingsScreen extends ConsumerStatefulWidget {
  const DeviceReadingsScreen({super.key});

  @override
  ConsumerState<DeviceReadingsScreen> createState() =>
      _DeviceReadingsScreenState();
}

class _DeviceReadingsScreenState extends ConsumerState<DeviceReadingsScreen> {
  final _store = const TokenStore(FlutterSecureStorage());
  List<DeviceSummary> _devices = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final token = await _store.readAccessToken();
      final organizationId = await _store.readSelectedOrganization();
      if (token == null || organizationId == null) {
        throw StateError('Authentication required');
      }
      final devices = await PlatformApi(
        ref.read(environmentProvider).apiBaseUrl,
      ).listDevices(accessToken: token, organizationId: organizationId);
      if (mounted) {
        setState(
          () => _devices = devices
              .where(
                (device) =>
                    device.lifecycle != 'UNCLAIMED' &&
                    device.lifecycle != 'REVOKED',
              )
              .toList(growable: false),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Device readings are unavailable.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Live device readings')),
    body: ListView(
      children: [
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) ListTile(title: Text(_error!)),
        if (!_loading && _devices.isEmpty)
          const ListTile(title: Text('No connected devices.')),
        for (final device in _devices)
          ListTile(
            leading: const Icon(Icons.sensors),
            title: Text(device.visibleName),
            subtitle: const Text('Open live real-time data feed'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DeviceDetailsScreen(device: device),
              ),
            ),
          ),
      ],
    ),
  );
}

class DeviceDetailsScreen extends ConsumerStatefulWidget {
  const DeviceDetailsScreen({super.key, this.device});
  final DeviceSummary? device;
  @override
  ConsumerState<DeviceDetailsScreen> createState() =>
      _DeviceDetailsScreenState();
}

class _DeviceDetailsScreenState extends ConsumerState<DeviceDetailsScreen> {
  final _store = const TokenStore(FlutterSecureStorage());
  DemoTelemetryReading? _reading;
  DeviceSummary? _device;
  List<ProfileSummary> _profiles = const [];
  String? _selectedProfileId;
  String? _activeProfileId;
  List<AlgaeAlert> _alerts = const [];
  String? _lastAlertSignature;
  bool _assigningProfile = false;
  bool _unpairing = false;
  bool _loading = true;
  String? _error;
  int _observedEventRevision = -1;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // The realtime WebSocket push is the primary update path, but this
    // periodic refresh guarantees readings keep advancing even if that
    // connection has silently dropped or its reconnect stalled -- the user
    // shouldn't have to leave and re-enter the screen to see fresh data.
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_assigningProfile) _load();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<DeviceSummary> _resolveDevice(
    PlatformApi api,
    String token,
    String organizationId,
  ) async {
    if (widget.device != null) return widget.device!;
    final devices = await api.listDevices(
      accessToken: token,
      organizationId: organizationId,
    );
    final owned = devices.where((value) => value.lifecycle != 'UNCLAIMED');
    if (owned.length != 1) throw StateError('Demo device unavailable');
    return owned.single;
  }

  Future<void> _load() async {
    final token = await _store.readAccessToken();
    final organizationId = await _store.readSelectedOrganization();
    if (token == null || organizationId == null) {
      if (mounted) {
        setState(() {
          _error = 'Authentication required';
          _loading = false;
        });
      }
      return;
    }
    final api = PlatformApi(ref.read(environmentProvider).apiBaseUrl);
    final DeviceSummary device;
    try {
      device = await _resolveDevice(api, token, organizationId);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Device is unavailable.';
          _loading = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _device = device);
    // Real-time data and profile assignment are independent concerns -- a
    // freshly-paired device has no telemetry yet until it has a profile
    // installed, and a profile-service hiccup shouldn't hide readings that
    // are already flowing. Neither one may block the other from loading or
    // updating, so they run and fail independently rather than sharing one
    // try/catch.
    await Future.wait([
      _loadTelemetry(api, token, device),
      _loadProfileAssignment(api, token, organizationId, device),
    ]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadTelemetry(
    PlatformApi api,
    String token,
    DeviceSummary device,
  ) async {
    try {
      final reading = await api.latestDemoTelemetry(
        accessToken: token,
        deviceUuid: device.deviceUuid,
      );
      if (mounted) {
        setState(() {
          _reading = reading;
          _error = null;
        });
      }
    } catch (_) {
      // No telemetry yet (e.g. a freshly-paired device with no profile
      // installed) is a normal, expected state -- it must never block the
      // profile section from loading and never overwrite a reading already
      // on screen with an error.
      if (mounted && _reading == null) {
        setState(() => _error = 'Device readings are unavailable yet.');
      }
    }
  }

  Future<void> _loadProfileAssignment(
    PlatformApi api,
    String token,
    String organizationId,
    DeviceSummary device,
  ) async {
    try {
      final profiles = await api.listProfiles(
        accessToken: token,
        organizationId: organizationId,
      );
      final assignment = await api.activeDeviceProfile(
        accessToken: token,
        deviceId: device.deviceId,
      );
      final assignedMatches = assignment == null
          ? const <ProfileSummary>[]
          : profiles
                .where((profile) => profile.profileId == assignment.profileId)
                .toList(growable: false);
      final assigned = assignedMatches.length == 1
          ? assignedMatches.single
          : null;
      // Profile assignment exists to route notifications, not to gate the
      // telemetry view -- alerts only ever come from an assigned profile
      // evaluating whatever reading is currently on screen (or none, if
      // nothing has loaded yet).
      final reading = _reading;
      final alerts = reading == null
          ? const <AlgaeAlert>[]
          : assigned?.configuration?.evaluate(reading) ?? const <AlgaeAlert>[];
      if (mounted) {
        setState(() {
          _profiles = profiles;
          // A background refresh (e.g. a realtime telemetry tick) must not
          // clobber a profile the user has picked in the dropdown but not
          // yet submitted. Only resync the selection when it still matches
          // the last known server state.
          if (_selectedProfileId == null ||
              _selectedProfileId == _activeProfileId) {
            _selectedProfileId = assigned?.profileId;
          }
          _activeProfileId = assigned?.profileId;
          _alerts = alerts;
        });
        final signature = alerts.map((alert) => alert.parameterLabel).join('|');
        if (signature.isEmpty) {
          _lastAlertSignature = null;
        } else if (signature != _lastAlertSignature) {
          _lastAlertSignature = signature;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${alerts.length} profile threshold alert${alerts.length == 1 ? '' : 's'} detected.',
              ),
            ),
          );
        }
      }
    } catch (_) {
      // A profile-service hiccup must never block the telemetry view above
      // it or clear an already-loaded profile list/selection.
    }
  }

  @override
  Widget build(BuildContext context) {
    final realtime = ref.watch(realtimeControllerProvider);
    if (_observedEventRevision != realtime.eventRevision) {
      _observedEventRevision = realtime.eventRevision;
      if (_observedEventRevision > 0 && !_assigningProfile) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      }
    }
    final reading = _reading;
    return Scaffold(
      appBar: AppBar(title: Text(_device?.visibleName ?? 'Device telemetry')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, key: const Key('telemetry-error')),
          if (reading != null)
            DemoTelemetryView(
              reading: reading,
              realtimeText: realtime.state.visibleText,
              now: DateTime.now(),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Algae type / profile',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  DropdownButtonFormField<String>(
                    key: const Key('device-algae-profile-dropdown'),
                    initialValue: _selectedProfileId,
                    hint: const Text('Select an Algae Profile'),
                    items: [
                      for (final profile in _profiles)
                        DropdownMenuItem(
                          value: profile.profileId,
                          child: Text(profile.name),
                        ),
                    ],
                    onChanged: _assigningProfile
                        ? null
                        : (value) => setState(() => _selectedProfileId = value),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: _assigningProfile || _selectedProfileId == null
                        ? null
                        : _assignSelectedProfile,
                    child: Text(
                      _assigningProfile ? 'Assigning...' : 'Assign profile',
                    ),
                  ),
                  if (_profiles.isEmpty)
                    TextButton(
                      onPressed: () =>
                          Navigator.of(context).pushNamed('/profiles'),
                      child: const Text('Create an Algae Profile first'),
                    ),
                ],
              ),
            ),
          ),
          if (_alerts.isNotEmpty)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Active threshold alerts',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    for (final alert in _alerts) Text('• ${alert.safeMessage}'),
                  ],
                ),
              ),
            ),
          const Card(
            child: ListTile(
              title: Text('Cloud / certificate'),
              subtitle: Text('HTTPS recovery and one-time WSS tickets'),
            ),
          ),
          if (_device != null)
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DeviceSetupScreen(device: _device!),
                ),
              ),
              icon: const Icon(Icons.edit),
              label: const Text('Edit device settings'),
            ),
          if (_device != null)
            TextButton.icon(
              key: const Key('remove-device'),
              onPressed: _unpairing ? null : _removeDevice,
              icon: const Icon(Icons.delete_outline),
              label: Text(
                _unpairing
                    ? 'Waiting for device confirmation...'
                    : 'Unpair device',
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _assignSelectedProfile() async {
    final device = _device;
    final matches = _profiles
        .where((value) => value.profileId == _selectedProfileId)
        .toList(growable: false);
    final profile = matches.length == 1 ? matches.single : null;
    if (device == null || profile == null) return;
    setState(() => _assigningProfile = true);
    try {
      final token = await _store.readAccessToken();
      final organizationId = await _store.readSelectedOrganization();
      if (token == null || organizationId == null) {
        throw StateError('Authentication required');
      }
      await PlatformApi(
        ref.read(environmentProvider).apiBaseUrl,
      ).assignDeviceProfile(
        accessToken: token,
        organizationId: organizationId,
        deviceId: device.deviceId,
        profile: profile,
      );
      if (mounted) {
        setState(() {
          _activeProfileId = profile.profileId;
          _alerts = _reading == null
              ? const []
              : profile.configuration?.evaluate(_reading!) ?? const [];
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Algae Profile assigned to device.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile assignment was not saved.')),
        );
      }
    } finally {
      if (mounted) setState(() => _assigningProfile = false);
    }
  }

  Future<void> _removeDevice() async {
    final device = _device;
    if (device == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove device?'),
        content: const Text(
          'The ESP32 must be online. Confirm REMOVE DEVICE on its OLED using Select. Back cancels. Cloud ownership and credentials are removed only after that physical confirmation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Request unpair'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _unpairing = true);
    try {
      final token = await _store.readAccessToken();
      if (token == null) throw StateError('Authentication required');
      final outcome = await PlatformApi(
        ref.read(environmentProvider).apiBaseUrl,
      ).requestPhysicalUnpair(accessToken: token, device: device);
      if (!mounted) return;
      if (outcome == PhysicalUnpairOutcome.completed) {
        Navigator.of(context).pushNamedAndRemoveUntil('/devices', (_) => false);
        return;
      }
      final message = switch (outcome) {
        PhysicalUnpairOutcome.rejected =>
          'Unpair was cancelled or rejected on the device.',
        PhysicalUnpairOutcome.expired =>
          'Physical confirmation expired. The device remains paired.',
        PhysicalUnpairOutcome.timedOut =>
          'No physical confirmation was received. The device remains paired.',
        PhysicalUnpairOutcome.completed => '',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Device was not unpaired. Confirm on the physical device while it is online.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _unpairing = false);
    }
  }
}

class OtaScreen extends StatelessWidget {
  const OtaScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Development OTA')),
    body: const Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Chip(label: Text('Development only')),
          SizedBox(height: 12),
          Text(
            'Assigned release and progress arrive through authenticated HTTPS and WebSocket status updates.',
          ),
          SizedBox(height: 12),
          Text(
            'Production rollout controls are intentionally unavailable. Physical OTA and rollback require manual ESP32-S3 validation.',
          ),
        ],
      ),
    ),
  );
}

class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final _store = const TokenStore(FlutterSecureStorage());
  OidcUserProfile? _profile;
  List<OrganizationSummary> _organizations = const [];
  String? _selectedOrganizationId;
  bool _loading = true;
  bool _signingOut = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    unawaited(_loadOrganizations());
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await OidcClient(
        ref.read(environmentProvider),
        _store,
      ).profile();
      if (mounted) {
        setState(() {
          _profile = profile;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Signed-in account details are unavailable.';
        });
      }
    }
  }

  Future<void> _loadOrganizations() async {
    try {
      final environment = ref.read(environmentProvider);
      final token = await _store.readAccessToken();
      if (token == null) return;
      final results = await Future.wait<Object?>([
        PlatformApi(
          environment.apiBaseUrl,
        ).listOrganizations(accessToken: token),
        _store.readSelectedOrganization(),
      ]);
      if (!mounted) return;
      setState(() {
        _organizations = results[0]! as List<OrganizationSummary>;
        _selectedOrganizationId = results[1] as String?;
      });
    } catch (_) {
      // The switcher is a convenience; leave it hidden if it can't load.
    }
  }

  Future<void> _switchOrganization(String organizationId) async {
    if (organizationId == _selectedOrganizationId) return;
    await _store.selectOrganization(organizationId);
    if (mounted) Navigator.of(context).pushReplacementNamed('/home');
  }

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    await ref.read(realtimeControllerProvider).stop();
    await ref.read(pushNotificationProvider).deactivate();
    await ref.read(authSessionProvider).signOut();
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
    }
  }

  static const _moreDestinations = <(String, String, IconData, String)>[
    (
      'Overview',
      'All devices across every organization you belong to.',
      Icons.dashboard_outlined,
      '/overview',
    ),
    (
      'Device readings',
      'View authenticated realtime and latest device readings.',
      Icons.show_chart,
      '/readings',
    ),
    (
      'Algae Profiles',
      'Create algae types and configure all six sensor thresholds.',
      Icons.eco,
      '/profiles',
    ),
    (
      'Organization access',
      'Invite users and accept or reject incoming invitations.',
      Icons.group_add,
      '/organization-access',
    ),
    (
      'Development OTA status',
      'View OTA readiness; updates are never started automatically.',
      Icons.system_update,
      '/ota',
    ),
  ];

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      if (_loading) const Center(child: CircularProgressIndicator()),
      if (_profile != null) ...[
        Row(
          children: [
            const CircleAvatar(radius: 28, child: Icon(Icons.person, size: 28)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _profile!.primaryLabel,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    _profile!.email ?? _profile!.username ?? 'Keycloak account',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
      ],
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (_organizations.length > 1) ...[
        Text(
          'Organization',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (final organization in _organizations)
                RadioListTile<String>(
                  value: organization.id,
                  groupValue: _selectedOrganizationId,
                  title: Text(organization.name),
                  onChanged: (value) {
                    if (value != null) unawaited(_switchOrganization(value));
                  },
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
      Text(
        'More',
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Card(
        child: Column(
          children: [
            for (final item in _moreDestinations)
              ListTile(
                leading: Icon(item.$3),
                title: Text(item.$1),
                subtitle: Text(item.$2),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed(item.$4),
              ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const Text(
        'The next sign-in opens Keycloak account selection, even when a browser SSO session already exists.',
      ),
      const SizedBox(height: 16),
      FilledButton.tonalIcon(
        onPressed: _signingOut ? null : _signOut,
        icon: const Icon(Icons.logout),
        label: Text(_signingOut ? 'Signing out...' : 'Sign out'),
      ),
    ],
  );
}
