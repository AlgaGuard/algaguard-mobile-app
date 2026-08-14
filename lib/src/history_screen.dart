import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../main.dart' show environmentProvider;
import 'demo_telemetry.dart';
import 'platform_clients.dart';
import 'theme.dart';

enum _Param { temperature, ph, light, nutrient }

extension on _Param {
  String get label => switch (this) {
    _Param.temperature => 'Temperature',
    _Param.ph => 'pH',
    _Param.light => 'Light',
    _Param.nutrient => 'Nutrient value percentage',
  };

  double value(DemoTelemetryReading reading) => switch (this) {
    _Param.temperature => reading.temperatureC,
    _Param.ph => reading.ph,
    _Param.light => reading.lightLux,
    _Param.nutrient => reading.nutrientPercent,
  };

  Color color(ParamColors params) => switch (this) {
    _Param.temperature => params.temperature,
    _Param.ph => params.ph,
    _Param.light => params.light,
    _Param.nutrient => params.nutrient,
  };
}

/// A live trend chart built entirely from samples this screen has itself
/// observed via PlatformApi.latestDemoTelemetry -- there is no historical
/// query endpoint in this API, so rather than fabricate a longer trend this
/// polls for genuinely new readings and charts exactly what it has actually
/// seen, however short that record is.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final _store = const TokenStore(FlutterSecureStorage());
  final List<DemoTelemetryReading> _samples = [];
  _Param _selected = _Param.temperature;
  Timer? _poll;
  String? _deviceUuid;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_pollOnce());
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _pollOnce());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _pollOnce() async {
    try {
      final token = await _store.readAccessToken();
      final organizationId = await _store.readSelectedOrganization();
      if (token == null || organizationId == null) return;
      final api = PlatformApi(ref.read(environmentProvider).apiBaseUrl);
      var deviceUuid = _deviceUuid;
      if (deviceUuid == null) {
        final devices = await api.listDevices(
          accessToken: token,
          organizationId: organizationId,
        );
        final active = devices
            .where((candidate) => candidate.lifecycle != 'UNCLAIMED')
            .cast<DeviceSummary?>()
            .firstWhere((_) => true, orElse: () => null);
        if (active == null) return;
        deviceUuid = active.deviceUuid;
      }
      final reading = await api.latestDemoTelemetry(
        accessToken: token,
        deviceUuid: deviceUuid,
      );
      if (!mounted) return;
      setState(() {
        _deviceUuid = deviceUuid;
        _error = null;
        if (_samples.isEmpty || _samples.last.sequence != reading.sequence) {
          _samples.add(reading);
          if (_samples.length > 60) _samples.removeAt(0);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Live samples are unavailable.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final params = Theme.of(context).extension<ParamColors>()!;
    final color = _selected.color(params);
    final values = _samples.map(_selected.value).toList(growable: false);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Historical trend',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Live samples observed since this screen opened.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final param in _Param.values)
                ChoiceChip(
                  label: Text(param.label),
                  selected: _selected == param,
                  onSelected: (_) => setState(() => _selected = param),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_error != null) Text(_error!),
          Expanded(
            child: values.length < 2
                ? const Center(child: Text('Collecting live samples…'))
                : Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 20, 20, 12),
                      child: LineChart(
                        LineChartData(
                          gridData: const FlGridData(show: false),
                          titlesData: const FlTitlesData(show: false),
                          borderData: FlBorderData(show: false),
                          lineBarsData: [
                            LineChartBarData(
                              spots: [
                                for (var i = 0; i < values.length; i++)
                                  FlSpot(i.toDouble(), values[i]),
                              ],
                              isCurved: true,
                              color: color,
                              barWidth: 2,
                              dotData: const FlDotData(show: false),
                              belowBarData: BarAreaData(
                                show: true,
                                color: color.withValues(alpha: 0.12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
          if (values.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _StatTile(
                  label: 'Minimum',
                  value: values.reduce((a, b) => a < b ? a : b),
                ),
                _StatTile(
                  label: 'Average',
                  value: values.reduce((a, b) => a + b) / values.length,
                ),
                _StatTile(
                  label: 'Maximum',
                  value: values.reduce((a, b) => a > b ? a : b),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              value.toStringAsFixed(2),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
    ),
  );
}
