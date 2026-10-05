import 'package:algaguard_mobile_app/src/demo_telemetry.dart';
import 'package:algaguard_mobile_app/src/demo_telemetry_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object> sample({DateTime? at}) => {
  'sequence': '9',
  'observedAt': (at ?? DateTime.utc(2026, 7, 30)).toIso8601String(),
  'timestampQuality': 'NTP_SYNCED',
  'uptimeMs': '9000',
  'values': {
    'temperatureC': 24.1,
    'ph': 7.1,
    'lightLux': 900,
    'nutrientPercent': 63.4,
  },
  'qualityFlags': ['SIMULATED'],
};

void main() {
  test('latest response decodes all four values', () {
    final reading = DemoTelemetryReading.fromLatestResponse({
      'latest': sample(),
    });
    expect(
      [
        reading.temperatureC,
        reading.ph,
        reading.lightLux,
        reading.nutrientPercent,
      ],
      [24.1, 7.1, 900, 63.4],
    );
  });

  test('nutrient estimates decode when present and stay null when absent', () {
    final withEstimates = sample();
    withEstimates['values'] = {
      ...withEstimates['values']! as Map,
      'nitrateMgL': 68.61,
      'phosphateMgL': 9.81,
      'potassiumMgL': 26.79,
    };
    final reading = DemoTelemetryReading.fromLatestResponse({
      'latest': withEstimates,
    });
    expect(reading.nitrateMgL, 68.61);
    expect(reading.phosphateMgL, 9.81);
    expect(reading.potassiumMgL, 26.79);
    expect(reading.hasNutrientEstimates, isTrue);

    final older = DemoTelemetryReading.fromLatestResponse({'latest': sample()});
    expect(older.nitrateMgL, isNull);
    expect(older.hasNutrientEstimates, isFalse);
  });

  test('an invalid estimate is dropped without rejecting the sample', () {
    final invalid = sample();
    invalid['values'] = {...invalid['values']! as Map, 'nitrateMgL': -3};
    final reading = DemoTelemetryReading.fromLatestResponse({
      'latest': invalid,
    });
    expect(reading.nitrateMgL, isNull);
    expect(reading.ph, 7.1);
  });

  test('realtime event decodes only the authoritative schema', () {
    final reading = DemoTelemetryReading.fromRealtimeEvent({
      'schema': 'urn:algaguard:schema:websocket:telemetry-updated:v1-1',
      'eventType': 'telemetry.updated',
      'payload': {'sample': sample()},
    });
    expect(reading.sequence, '9');
  });

  test('missing simulated source is rejected', () {
    final invalid = sample()..['qualityFlags'] = <String>[];
    expect(
      () => DemoTelemetryReading.fromLatestResponse({'latest': invalid}),
      throwsFormatException,
    );
  });

  test('negative concentrations and invalid pH are rejected', () {
    final invalid = sample();
    invalid['values'] = {...invalid['values']! as Map, 'nutrientPercent': -1};
    expect(
      () => DemoTelemetryReading.fromLatestResponse({'latest': invalid}),
      throwsFormatException,
    );
  });

  testWidgets('view shows four values', (tester) async {
    final reading = DemoTelemetryReading.fromLatestResponse({
      'latest': sample(),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DemoTelemetryView(
              reading: reading,
              realtimeText: 'REALTIME CONNECTED',
              now: reading.generatedAt,
            ),
          ),
        ),
      ),
    );
    for (final label in [
      'Temperature',
      'pH',
      'Light intensity',
      'Nutrient value percentage',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('REALTIME CONNECTED'), findsOneWidget);
  });

  testWidgets('stale state is explicit', (tester) async {
    final reading = DemoTelemetryReading.fromLatestResponse({
      'latest': sample(),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DemoTelemetryView(
              reading: reading,
              realtimeText: 'Realtime disconnected',
              now: reading.generatedAt.add(const Duration(minutes: 1)),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('telemetry-stale')), findsOneWidget);
  });

  testWidgets('view never renders raw identifiers or event JSON', (
    tester,
  ) async {
    final reading = DemoTelemetryReading.fromLatestResponse({
      'latest': sample(),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DemoTelemetryView(
              reading: reading,
              realtimeText: 'REALTIME CONNECTED',
              now: reading.generatedAt,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('deviceUuid'), findsNothing);
    expect(find.textContaining('organizationId'), findsNothing);
    expect(find.textContaining('eventType'), findsNothing);
  });
}
