import 'dart:async';

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
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

final environmentProvider = Provider<AppEnvironment>(
  (_) => AppEnvironment.fromDefines(),
);

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

void main() => runApp(const ProviderScope(child: AlgaGuardApp()));

class AlgaGuardApp extends ConsumerWidget {
  const AlgaGuardApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: 'AlgaGuard',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff087b72)),
      useMaterial3: true,
    ),
    routes: {
      '/': (_) => const SplashScreen(),
      '/login': (_) => const LoginScreen(),
      '/organizations': (_) => const OrganizationScreen(),
      '/home': (_) => const HomeScreen(),
      '/devices': (_) => const DevicesScreen(),
      '/scan': (_) => const ScanQrScreen(),
      '/device': (_) => const DeviceDetailsScreen(),
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

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: FilledButton.icon(
        icon: const Icon(Icons.eco),
        label: const Text('Start AlgaGuard'),
        onPressed: () => Navigator.of(context).pushReplacementNamed('/login'),
      ),
    ),
  );
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
      final environment = ref.read(environmentProvider);
      await OidcClient(
        environment,
        const TokenStore(FlutterSecureStorage()),
      ).login();
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

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const _items = <(String, IconData, String)>[
    ('Devices', Icons.memory, '/devices'),
    ('Scan setup QR', Icons.qr_code_scanner, '/scan'),
    ('Live telemetry', Icons.show_chart, '/device'),
    ('Safe command and LED control', Icons.lightbulb_outline, '/device'),
    ('Development OTA status', Icons.system_update, '/ota'),
    ('Account', Icons.account_circle, '/account'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(realtimeControllerProvider).start();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final realtime = ref.watch(realtimeControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('AlgaGuard'),
        actions: [
          Padding(
            padding: EdgeInsets.all(10),
            child: Chip(label: Text(realtime.state.visibleText)),
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length + 1,
        separatorBuilder: (_, _) => const Divider(),
        itemBuilder: (context, index) {
          if (index == 0) {
            return const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Live updates use one-time WebSocket tickets; HTTPS recovers authoritative state after reconnect.',
                ),
              ),
            );
          }
          final item = _items[index - 1];
          return ListTile(
            leading: Icon(item.$2),
            title: Text(item.$1),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).pushNamed(item.$3),
          );
        },
      ),
    );
  }
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
            title: Text(device.deviceId),
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
    QrOnboardingScanState.failed => 'Secure onboarding was not prepared',
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
      final prepared = await widget.api.exchangeQrOnboarding(
        accessToken: widget.accessToken,
        organizationId: widget.organizationId,
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
    appBar: AppBar(title: const Text('Scan setup QR')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
  bool _loading = true;
  String? _error;
  int _observedEventRevision = -1;

  @override
  void initState() {
    super.initState();
    _load();
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
    try {
      final token = await _store.readAccessToken();
      final organizationId = await _store.readSelectedOrganization();
      if (token == null || organizationId == null) {
        throw StateError('Authentication required');
      }
      final api = PlatformApi(ref.read(environmentProvider).apiBaseUrl);
      final device = await _resolveDevice(api, token, organizationId);
      final reading = await api.latestDemoTelemetry(
        accessToken: token,
        deviceUuid: device.deviceUuid,
      );
      if (mounted) {
        setState(() {
          _reading = reading;
          _error = null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Simulated telemetry is unavailable.';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final realtime = ref.watch(realtimeControllerProvider);
    if (_observedEventRevision != realtime.eventRevision) {
      _observedEventRevision = realtime.eventRevision;
      if (_observedEventRevision > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      }
    }
    final reading = _reading;
    return Scaffold(
      appBar: AppBar(title: const Text('Demo device telemetry')),
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
          const Card(
            child: ListTile(
              title: Text('Profile'),
              subtitle: Text(
                'Development demo values — not scientifically approved',
              ),
            ),
          ),
          const Card(
            child: ListTile(
              title: Text('Cloud / certificate'),
              subtitle: Text('HTTPS recovery and one-time WSS tickets'),
            ),
          ),
          FilledButton.icon(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Set demo indicator state?'),
                  content: const Text(
                    'This is a safe LED-only command. No reset or reboot action is available.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Confirm'),
                    ),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'REQUEST_STATUS / indicator command queued for authorized device.',
                    ),
                  ),
                );
              }
            },
            icon: const Icon(Icons.lightbulb_outline),
            label: const Text('Safe LED control'),
          ),
        ],
      ),
    );
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
  bool _loading = true;
  bool _signingOut = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
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

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    await ref.read(realtimeControllerProvider).stop();
    await OidcClient(ref.read(environmentProvider), _store).logout();
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading) const CircularProgressIndicator(),
          if (_profile != null) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(_profile!.primaryLabel),
              subtitle: _profile!.email == null
                  ? Text(_profile!.username ?? 'Keycloak account')
                  : Text(_profile!.email!),
            ),
            const SizedBox(height: 12),
          ],
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
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
      ),
    ),
  );
}
