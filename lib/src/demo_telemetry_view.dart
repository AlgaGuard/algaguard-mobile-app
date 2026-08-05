import 'package:flutter/material.dart';
import 'demo_telemetry.dart';

class DemoTelemetryView extends StatelessWidget {
  const DemoTelemetryView({
    super.key,
    required this.reading,
    required this.realtimeText,
    required this.now,
  });

  final DemoTelemetryReading reading;
  final String realtimeText;
  final DateTime now;

  Widget _value(String label, String value) => Card(
    child: ListTile(title: Text(label), subtitle: Text(value)),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(realtimeText),
      if (reading.isStale(now))
        const Text('Data is stale', key: Key('telemetry-stale')),
      _value('Temperature', '${reading.temperatureC.toStringAsFixed(2)} °C'),
      _value('pH', reading.ph.toStringAsFixed(2)),
      _value('Light intensity', '${reading.lightLux.toStringAsFixed(0)} lux'),
      _value('Nitrate', '${reading.nitrateMgL.toStringAsFixed(2)} mg/L'),
      _value('Phosphate', '${reading.phosphateMgL.toStringAsFixed(2)} mg/L'),
      _value('Potassium', '${reading.potassiumMgL.toStringAsFixed(2)} mg/L'),
      Text('Last updated ${reading.generatedAt.toLocal()}'),
    ],
  );
}
