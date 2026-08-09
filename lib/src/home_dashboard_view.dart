import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../main.dart' show deviceRefreshSignalProvider, environmentProvider;
import 'demo_telemetry.dart';
import 'platform_clients.dart';
import 'simulated_badge.dart';
import 'theme.dart';

/// The app's dashboard-style Home tab: a greeting, the realtime connection
/// state, a hero card for the organization's primary device, and a grid of
/// its six latest sensor readings. Reuses PlatformApi.latestDemoTelemetry
/// (and therefore DemoTelemetryReading's parsing/validation) rather than
/// duplicating any fetch or parsing logic -- DemoTelemetryView (the flat
/// list presentation on the device detail screen) and this dashboard are
/// two renderers over the same underlying reading.
class HomeDashboardView extends ConsumerStatefulWidget {
  const HomeDashboardView({super.key});

  @override
  ConsumerState<HomeDashboardView> createState() => _HomeDashboardViewState();
}

class _HomeDashboardViewState extends ConsumerState<HomeDashboardView> {
  final _store = const TokenStore(FlutterSecureStorage());
  DeviceSummary? _device;
  DemoTelemetryReading? _reading;
  bool _loading = true;
  // Device list/selection failing is a real error (no organization, no
  // network, etc.); telemetry failing to load for an otherwise-valid device
  // is expected and unremarkable (a brand-new device has no telemetry until
  // its first sample arrives) -- tracked separately so the latter never
  // blanks out a device the former successfully found.
  String? _deviceError;
  String? _telemetryError;
  int _lastRefreshSignal = -1;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final signal = ref.watch(deviceRefreshSignalProvider);
    if (_lastRefreshSignal != -1 && signal != _lastRefreshSignal) {
      unawaited(_load());
    }
    _lastRefreshSignal = signal;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _deviceError = null;
      _telemetryError = null;
    });
    DeviceSummary? device;
    try {
      final token = await _store.readAccessToken();
      final organizationId = await _store.readSelectedOrganization();
      if (token == null || organizationId == null) {
        throw StateError('Authenticated organization is required');
      }
      final api = PlatformApi(ref.read(environmentProvider).apiBaseUrl);
      final devices = await api.listDevices(
        accessToken: token,
        organizationId: organizationId,
      );
      // Prefer a fully-named device over one still mid-setup (e.g. claimed
      // but abandoned before naming) so the dashboard shows something
      // useful even while an incomplete pairing is sitting in the list.
      final eligible = devices
          .where((candidate) => candidate.lifecycle != 'UNCLAIMED')
          .toList(growable: false);
      device = eligible.cast<DeviceSummary?>().firstWhere(
        (candidate) => candidate?.displayName != null,
        orElse: () => eligible.isEmpty ? null : eligible.first,
      );
      if (!mounted) return;
      setState(() {
        _device = device;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _deviceError = 'Your devices are unavailable right now.';
          _loading = false;
        });
      }
      return;
    }
    if (device == null) return;
    try {
      final token = await _store.readAccessToken();
      if (token == null) return;
      final api = PlatformApi(ref.read(environmentProvider).apiBaseUrl);
      final reading = await api.latestDemoTelemetry(
        accessToken: token,
        deviceUuid: device.deviceUuid,
      );
      if (mounted) setState(() => _reading = reading);
    } catch (_) {
      // Expected for a device with no samples yet -- leave _reading null
      // and let the hero card show a "waiting for data" state instead of
      // treating this as a dashboard-wide failure.
      if (mounted) {
        setState(
          () => _telemetryError =
              'Waiting for the first reading from this device.',
        );
      }
    }
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  List<Widget> _buildDeviceSection(
    BuildContext context,
    ColorScheme scheme,
    ParamColors params,
  ) {
    final device = _device!;
    final reading = _reading;
    return [
      _HeroCard(device: device, reading: reading),
      if (device.displayName == null) ...[
        const SizedBox(height: 8),
        Card(
          color: scheme.surfaceContainerHighest,
          child: ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Finish setting up this device'),
            subtitle: const Text('Give it a name from Devices'),
            onTap: () => Navigator.of(context).pushNamed('/devices'),
          ),
        ),
      ] else if (_telemetryError != null) ...[
        const SizedBox(height: 8),
        Text(
          _telemetryError!,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ],
      const SizedBox(height: 20),
      Text(
        'Sensor readings',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 10),
      if (reading == null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No readings yet -- they will appear here once this device reports its first sample.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        )
      else
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.5,
          children: [
            _SensorTile(
              icon: Icons.thermostat,
              color: params.temperature,
              label: 'Temperature',
              value: '${reading.temperatureC.toStringAsFixed(1)} °C',
            ),
            _SensorTile(
              icon: Icons.science_outlined,
              color: params.ph,
              label: 'pH',
              value: reading.ph.toStringAsFixed(2),
            ),
            _SensorTile(
              icon: Icons.wb_sunny_outlined,
              color: params.light,
              label: 'Light intensity',
              value: '${reading.lightLux.toStringAsFixed(0)} lux',
            ),
            _SensorTile(
              icon: Icons.eco_outlined,
              color: params.nitrate,
              label: 'Nitrate',
              value: '${reading.nitrateMgL.toStringAsFixed(2)} mg/L',
            ),
            _SensorTile(
              icon: Icons.opacity,
              color: params.phosphate,
              label: 'Phosphate',
              value: '${reading.phosphateMgL.toStringAsFixed(2)} mg/L',
            ),
            _SensorTile(
              icon: Icons.grain,
              color: params.potassium,
              label: 'Potassium',
              value: '${reading.potassiumMgL.toStringAsFixed(2)} mg/L',
            ),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final params = Theme.of(context).extension<ParamColors>()!;
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _greeting,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            _device?.displayName ?? _device?.deviceId ?? 'No device yet',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_deviceError != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_deviceError!),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _load,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            )
          else if (_device == null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('Pair a device to see live readings here'),
                subtitle: const Text('Go to Devices to add one'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed('/devices'),
              ),
            )
          else if (_buildDeviceSection(context, scheme, params)
              case final section)
            ...section,
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.device, required this.reading});

  final DeviceSummary device;
  // Null whenever this device hasn't reported a sample yet -- a normal,
  // common state for a freshly-paired device, not an error.
  final DemoTelemetryReading? reading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reading = this.reading;
    final stale = reading == null || reading.isStale(DateTime.now());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    device.displayName ?? device.deviceId,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (reading?.simulated ?? false) const SimulatedBadge(),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  stale ? Icons.cloud_off : Icons.cloud_done,
                  size: 16,
                  color: stale ? scheme.error : AlgaGuardColors.statusGood,
                ),
                const SizedBox(width: 6),
                Text(
                  reading == null
                      ? 'Waiting for first reading'
                      : stale
                      ? 'Data is stale'
                      : 'System is online',
                  style: TextStyle(
                    color: stale ? scheme.error : AlgaGuardColors.statusGood,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SensorTile extends StatelessWidget {
  const _SensorTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Color.lerp(
                Theme.of(context).colorScheme.surface,
                color,
                0.18,
              ),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}
