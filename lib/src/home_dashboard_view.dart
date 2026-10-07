import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../main.dart'
    show
        deviceRefreshSignalProvider,
        environmentProvider,
        realtimeControllerProvider;
import 'demo_telemetry.dart';
import 'platform_clients.dart';
import 'simulated_badge.dart';
import 'theme.dart';

/// The app's dashboard-style Home tab: a greeting, the realtime connection
/// state, a hero card for the organization's primary device, and a grid of
/// its four latest sensor readings. Reuses PlatformApi.latestDemoTelemetry
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
  // Only the very first load should blank the page behind a spinner.
  // Realtime-triggered and pull-to-refresh reloads happen every few
  // seconds once data is flowing -- they must update the on-screen values
  // in place rather than repeatedly discarding and rebuilding the whole
  // device section.
  bool _hasLoadedOnce = false;
  // Device list/selection failing is a real error (no organization, no
  // network, etc.); telemetry failing to load for an otherwise-valid device
  // is expected and unremarkable (a brand-new device has no telemetry until
  // its first sample arrives) -- tracked separately so the latter never
  // blanks out a device the former successfully found.
  String? _deviceError;
  String? _telemetryError;
  int _lastRefreshSignal = -1;
  int _observedEventRevision = -1;

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
    final isInitialLoad = !_hasLoadedOnce;
    _hasLoadedOnce = true;
    setState(() {
      if (isInitialLoad) _loading = true;
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
        _TileGrid(
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
              color: params.nutrient,
              label: 'Nutrient value percentage',
              value: '${reading.nutrientPercent.toStringAsFixed(1)}%',
            ),
          ],
        ),
      if (reading != null && reading.hasNutrientEstimates) ...[
        const SizedBox(height: 20),
        Text(
          'Nutrient estimates',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          'Calculated on the device from pH and temperature, not measured. '
          'Phosphate and potassium are experimental and should not be used '
          'for dosing decisions.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        _TileGrid(
          children: [
            _SensorTile(
              icon: Icons.water_drop_outlined,
              color: params.nutrient,
              label: 'Nitrate (N), estimated',
              value: _estimateText(reading.nitrateMgL),
              badge: 'Estimate',
            ),
            _SensorTile(
              icon: Icons.grain,
              color: params.nutrient,
              label: 'Phosphate (P), estimated',
              value: _estimateText(reading.phosphateMgL),
              badge: _experimental,
            ),
            _SensorTile(
              icon: Icons.bubble_chart_outlined,
              color: params.nutrient,
              label: 'Potassium (K), estimated',
              value: _estimateText(reading.potassiumMgL),
              badge: _experimental,
            ),
          ],
        ),
      ],
    ];
  }

  static String _estimateText(double? value) =>
      value == null ? 'Out of range' : '${value.toStringAsFixed(1)} mg/L';

  @override
  Widget build(BuildContext context) {
    final realtime = ref.watch(realtimeControllerProvider);
    if (_observedEventRevision != realtime.eventRevision) {
      _observedEventRevision = realtime.eventRevision;
      if (_observedEventRevision > 0 && !_loading) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      }
    }
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
    this.badge,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;

  /// Short status shown top-right, e.g. "Experimental".
  final String? badge;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
              if (badge != null) ...[
                const SizedBox(width: 8),
                // Shrinks rather than overflowing beside the icon on very
                // narrow tiles.
                Expanded(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _Badge(
                        text: badge!,
                        warning: badge == _experimental,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
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

const _experimental = 'Experimental';

/// Two tiles per row. Each row is as tall as its taller tile's content; the
/// fixed-aspect GridView it replaces cut tiles off ("BOTTOM OVERFLOWED") on
/// narrow phones and with larger font sizes.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var index = 0; index < children.length; index += 2) ...[
        if (index > 0) const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: children[index]),
              const SizedBox(width: 12),
              Expanded(
                child: index + 1 < children.length
                    ? children[index + 1]
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ],
    ],
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.warning});

  final String text;

  /// Amber for experimental values, neutral otherwise.
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = warning
        ? (dark ? const Color(0xff3a2d10) : const Color(0xfffdf1d6))
        : scheme.surfaceContainerHighest;
    final foreground = warning
        ? (dark ? const Color(0xfff2c46a) : const Color(0xff8a5a00))
        : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}
