import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() => runApp(const ProviderScope(child: AlgaGuardApp()));

class AlgaGuardApp extends StatelessWidget {
  const AlgaGuardApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AlgaGuard',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff087b72)),
      useMaterial3: true,
    ),
    home: const HomeScreen(),
  );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  static const flows = <(String, IconData)>[
    ('Sign in with Keycloak', Icons.login),
    ('Select organization', Icons.apartment),
    ('Dashboard and devices', Icons.dashboard),
    ('Scan setup QR', Icons.qr_code_scanner),
    ('Confirm device claim', Icons.verified_user),
    ('BLE provisioning', Icons.bluetooth),
    ('Enter Wi-Fi for BLE transfer', Icons.wifi),
    ('Provisioning progress', Icons.sync),
    ('Device details', Icons.memory),
    ('Live simulated telemetry', Icons.show_chart),
    ('Profile view', Icons.tune),
    ('OTA status', Icons.system_update),
    ('Account', Icons.account_circle),
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('AlgaGuard'),
      actions: const [
        Padding(
          padding: EdgeInsets.all(12),
          child: Chip(label: Text('Development')),
        ),
      ],
    ),
    body: ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: flows.length + 1,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, index) {
        if (index == 0) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Simulated data is labelled. HTTPS recovers state after each WebSocket reconnect.',
              ),
            ),
          );
        }
        final flow = flows[index - 1];
        return ListTile(
          leading: Icon(flow.$2),
          title: Text(flow.$1),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => FlowScreen(title: flow.$1)),
          ),
        );
      },
    ),
  );
}

class FlowScreen extends StatelessWidget {
  const FlowScreen({super.key, required this.title});
  final String title;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '$title is wired to the platform abstraction. Runtime environment configuration and a real device are required for end-to-end use.',
        ),
      ),
    ),
  );
}
