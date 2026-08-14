class DemoTelemetryReading {
  const DemoTelemetryReading({
    required this.sequence,
    required this.generatedAt,
    required this.temperatureC,
    required this.ph,
    required this.lightLux,
    required this.nutrientPercent,
    required this.simulated,
  });

  factory DemoTelemetryReading.fromLatestResponse(Map<String, dynamic> root) {
    final latest = root['latest'];
    if (latest is! Map) throw const FormatException('Telemetry is unavailable');
    return DemoTelemetryReading._fromSample(Map<String, dynamic>.from(latest));
  }

  factory DemoTelemetryReading.fromRealtimeEvent(Map<String, dynamic> root) {
    if (root['schema'] !=
            'urn:algaguard:schema:websocket:telemetry-updated:v1-1' ||
        root['eventType'] != 'telemetry.updated' ||
        root['payload'] is! Map) {
      throw const FormatException('Unsupported realtime event');
    }
    final payload = Map<String, dynamic>.from(root['payload'] as Map);
    final sample = payload['sample'];
    if (sample is! Map) throw const FormatException('Telemetry sample missing');
    return DemoTelemetryReading._fromSample(Map<String, dynamic>.from(sample));
  }

  factory DemoTelemetryReading._fromSample(Map<String, dynamic> sample) {
    final valuesValue = sample['values'];
    final flagsValue = sample['qualityFlags'];
    final observedAt = sample['observedAt'];
    final sequence = sample['sequence'];
    if (valuesValue is! Map ||
        flagsValue is! List ||
        observedAt is! String ||
        sequence is! String ||
        !RegExp(r'^(0|[1-9][0-9]{0,19})$').hasMatch(sequence)) {
      throw const FormatException('Invalid telemetry sample');
    }
    final values = Map<String, dynamic>.from(valuesValue);
    double requiredNumber(String name, {bool nonNegative = false}) {
      final value = values[name];
      if (value is! num || !value.isFinite || (nonNegative && value < 0)) {
        throw const FormatException('Invalid telemetry value');
      }
      return value.toDouble();
    }

    final ph = requiredNumber('ph', nonNegative: true);
    if (ph > 14) throw const FormatException('Invalid telemetry value');
    final generatedAt = DateTime.tryParse(observedAt)?.toUtc();
    if (generatedAt == null) {
      throw const FormatException('Invalid telemetry time');
    }
    final flags = flagsValue.whereType<String>().toSet();
    if (flags.isEmpty) {
      throw const FormatException('Telemetry sample has no quality flags');
    }
    return DemoTelemetryReading(
      sequence: sequence,
      generatedAt: generatedAt,
      temperatureC: requiredNumber('temperatureC'),
      ph: ph,
      lightLux: requiredNumber('lightLux', nonNegative: true),
      nutrientPercent: requiredNumber('nutrientPercent', nonNegative: true),
      simulated: flags.contains('SIMULATED'),
    );
  }

  final String sequence;
  final DateTime generatedAt;
  final double temperatureC;
  final double ph;
  final double lightLux;
  final double nutrientPercent;
  final bool simulated;

  bool isStale(
    DateTime now, {
    Duration maximumAge = const Duration(seconds: 20),
  }) => now.toUtc().difference(generatedAt) > maximumAge;
}
