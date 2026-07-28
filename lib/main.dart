import 'package:algaguard_mobile_app/src/environment.dart';
import 'package:algaguard_mobile_app/src/onboarding.dart';
import 'package:algaguard_mobile_app/src/physical_session_handoff.dart';
import 'package:algaguard_mobile_app/src/secure_transport_preflight.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

final environmentProvider = Provider<AppEnvironment>(
  (_) => AppEnvironment.fromDefines(),
);

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

class OrganizationScreen extends StatelessWidget {
  const OrganizationScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Select organization')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: ListTile(
            title: Text('Development organization'),
            subtitle: Text(
              'Only authorized organizations returned by HTTPS may be selected.',
            ),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pushReplacementNamed('/home'),
          child: const Text('Continue to monitoring'),
        ),
        const SizedBox(height: 12),
        const Text(
          'Revoked access is handled by returning to this screen after HTTPS recovery.',
          semanticsLabel: 'Revoked organization access is not retained',
        ),
      ],
    ),
  );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  static const _items = <(String, IconData, String)>[
    ('Devices', Icons.memory, '/devices'),
    ('Scan setup QR', Icons.qr_code_scanner, '/scan'),
    ('Live telemetry', Icons.show_chart, '/device'),
    ('Safe command and LED control', Icons.lightbulb_outline, '/device'),
    ('Development OTA status', Icons.system_update, '/ota'),
    ('Account', Icons.account_circle, '/account'),
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('AlgaGuard'),
      actions: const [
        Padding(
          padding: EdgeInsets.all(10),
          child: Chip(label: Text('SIMULATED')),
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

class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Devices')),
    body: ListView(
      children: [
        ListTile(
          title: const Text('AG-000001'),
          subtitle: const Text('SIMULATED · status recovered through HTTPS'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).pushNamed('/device'),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'The local demo shows only data returned by the authorized platform APIs.',
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
      final api = PlatformApi(environment.apiBaseUrl);
      final session = await api.consumeClaim(
        accessToken: token,
        organizationId: environment.organizationId,
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

class BleProvisioningScreen extends StatefulWidget {
  const BleProvisioningScreen({
    super.key,
    required this.claim,
    required this.session,
  });
  final QrClaim claim;
  final ProvisioningSession session;
  @override
  State<BleProvisioningScreen> createState() => _BleProvisioningScreenState();
}

class _BleProvisioningScreenState extends State<BleProvisioningScreen> {
  final _ssid = TextEditingController();
  final _password = TextEditingController();
  String _state = 'Ready to discover the matching AlgaGuard BLE service.';
  bool _working = false;
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
        setState(
          () =>
              _state = 'Accepted by device. Waiting for device network status.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _state =
              'Provisioning failed. Verify the physical BLE device and retry.',
        );
      }
    } finally {
      _password.clear();
      if (mounted) setState(() => _working = false);
    }
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
        const SizedBox(height: 12),
        const Text(
          'Password remains only in this form for the active BLE call and is cleared after success or failure. Real BLE requires a phone and ESP32-S3.',
        ),
      ],
    ),
  );
}

class DeviceDetailsScreen extends StatelessWidget {
  const DeviceDetailsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AG-000001')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Chip(label: Text('SIMULATED telemetry')),
        const Card(
          child: ListTile(
            title: Text('Live telemetry'),
            subtitle: Text(
              'Temperature, pH, light, nitrate, phosphate, potassium',
            ),
          ),
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

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Account')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: FilledButton.tonal(
        onPressed: () async {
          await OidcClient(
            ref.read(environmentProvider),
            const TokenStore(FlutterSecureStorage()),
          ).logout();
          if (context.mounted) {
            Navigator.of(
              context,
            ).pushNamedAndRemoveUntil('/login', (_) => false);
          }
        },
        child: const Text('Sign out'),
      ),
    ),
  );
}
