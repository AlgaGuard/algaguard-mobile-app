import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../main.dart' show environmentProvider;
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
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
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
      final device = devices
          .where((candidate) => candidate.lifecycle != 'UNCLAIMED')
          .cast<DeviceSummary?>()
          .firstWhere((_) => true, orElse: () => null);
      if (device == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final reading = await api.latestDemoTelemetry(
        accessToken: token,
        deviceUuid: device.deviceUuid,
      );
      if (!mounted) return;
      setState(() {
        _device = device;
        _reading = reading;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Live telemetry is unavailable right now.';
          _loading = false;
        });
      }
    }
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
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
          else if (_error != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!),
              ),
            )
          else if (_device == null || _reading == null)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('Pair a device to see live readings here.'),
              ),
            )
          else ...[
            _HeroCard(device: _device!, reading: _reading!),
            const SizedBox(height: 20),
            Text(
              'Sensor readings',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
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
                  value: '${_reading!.temperatureC.toStringAsFixed(1)} °C',
                ),
                _SensorTile(
                  icon: Icons.science_outlined,
                  color: params.ph,
                  label: 'pH',
                  value: _reading!.ph.toStringAsFixed(2),
                ),
                _SensorTile(
                  icon: Icons.wb_sunny_outlined,
                  color: params.light,
                  label: 'Light intensity',
                  value: '${_reading!.lightLux.toStringAsFixed(0)} lux',
                ),
                _SensorTile(
                  icon: Icons.eco_outlined,
                  color: params.nitrate,
                  label: 'Nitrate',
                  value: '${_reading!.nitrateMgL.toStringAsFixed(2)} mg/L',
                ),
                _SensorTile(
                  icon: Icons.opacity,
                  color: params.phosphate,
                  label: 'Phosphate',
                  value: '${_reading!.phosphateMgL.toStringAsFixed(2)} mg/L',
                ),
                _SensorTile(
                  icon: Icons.grain,
                  color: params.potassium,
                  label: 'Potassium',
                  value: '${_reading!.potassiumMgL.toStringAsFixed(2)} mg/L',
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.device, required this.reading});

  final DeviceSummary device;
  final DemoTelemetryReading reading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stale = reading.isStale(DateTime.now());
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
                if (reading.simulated) const SimulatedBadge(),
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
                  stale ? 'Data is stale' : 'System is online',
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
