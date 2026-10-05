import 'demo_telemetry.dart';

class AlgaeParameter {
  const AlgaeParameter(
    this.key,
    this.label,
    this.unit, {
    this.optional = false,
  });
  final String key;
  final String label;
  final String unit;

  /// Optional thresholds may be left blank. The nutrient estimates are
  /// optional so profiles saved before they existed still load.
  final bool optional;
}

const algaeParameters = <AlgaeParameter>[
  AlgaeParameter('temperatureC', 'Temperature', 'C'),
  AlgaeParameter('ph', 'pH', 'pH'),
  AlgaeParameter('lightLux', 'Light intensity', 'lux'),
  AlgaeParameter('nutrientPercent', 'Nutrient value', '%'),
  AlgaeParameter('nitrateMgL', 'Nitrate (estimated)', 'mg/L', optional: true),
  AlgaeParameter(
    'phosphateMgL',
    'Phosphate (experimental estimate)',
    'mg/L',
    optional: true,
  ),
  AlgaeParameter(
    'potassiumMgL',
    'Potassium (experimental estimate)',
    'mg/L',
    optional: true,
  ),
];

/// Human-readable name for a parameter key, e.g. in a server alert record.
String algaeParameterLabel(String key) {
  for (final parameter in algaeParameters) {
    if (parameter.key == key) return parameter.label;
  }
  return key;
}

class AlgaeThreshold {
  const AlgaeThreshold({required this.minimum, required this.maximum});

  factory AlgaeThreshold.fromJson(Map<String, dynamic> value) {
    final minimum = value['minimum'];
    final maximum = value['maximum'];
    if (minimum is! num ||
        maximum is! num ||
        !minimum.isFinite ||
        !maximum.isFinite ||
        minimum >= maximum) {
      throw const FormatException('Invalid algae threshold');
    }
    return AlgaeThreshold(
      minimum: minimum.toDouble(),
      maximum: maximum.toDouble(),
    );
  }

  final double minimum;
  final double maximum;

  Map<String, Object> toJson() => {'minimum': minimum, 'maximum': maximum};
}

class AlgaeProfileConfiguration {
  const AlgaeProfileConfiguration(this.thresholds);

  factory AlgaeProfileConfiguration.fromJson(Map<String, dynamic> value) {
    final parameters = value['parameters'];
    if (parameters is! Map) {
      throw const FormatException('Invalid algae profile configuration');
    }
    final parsed = <String, AlgaeThreshold>{};
    for (final parameter in algaeParameters) {
      final threshold = parameters[parameter.key];
      if (threshold == null && parameter.optional) continue;
      if (threshold is! Map) {
        throw const FormatException('Missing algae threshold');
      }
      parsed[parameter.key] = AlgaeThreshold.fromJson(
        Map<String, dynamic>.from(threshold),
      );
    }
    return AlgaeProfileConfiguration(Map.unmodifiable(parsed));
  }

  final Map<String, AlgaeThreshold> thresholds;

  Map<String, Object> toJson() => {
    'schema': 'urn:algaguard:schema:profile:algae-thresholds:v1',
    'schemaVersion': '1.0.0',
    'parameters': {
      for (final entry in thresholds.entries) entry.key: entry.value.toJson(),
    },
  };

  List<AlgaeAlert> evaluate(DemoTelemetryReading reading) {
    final values = <String, double?>{
      'temperatureC': reading.temperatureC,
      'ph': reading.ph,
      'lightLux': reading.lightLux,
      'nutrientPercent': reading.nutrientPercent,
      'nitrateMgL': reading.nitrateMgL,
      'phosphateMgL': reading.phosphateMgL,
      'potassiumMgL': reading.potassiumMgL,
    };
    return [
      for (final parameter in algaeParameters)
        if ((values[parameter.key], thresholds[parameter.key]) case (
          final double value,
          final AlgaeThreshold threshold,
        ) when value < threshold.minimum || value > threshold.maximum)
          AlgaeAlert(parameter.label),
    ];
  }
}

class AlgaeAlert {
  const AlgaeAlert(this.parameterLabel);
  final String parameterLabel;
  String get safeMessage =>
      '$parameterLabel is outside the selected profile range.';
}
