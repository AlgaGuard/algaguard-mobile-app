// Renders the real app screens with realistic sample data and saves them as
// PNGs (Pixel 8 size) for documentation. Not part of the test suite:
//
//   flutter test tool/screenshots/app_screenshots_test.dart --update-goldens
//
// Output: screenshots/*.png. Every API call is answered in-process by the
// fake server below; nothing touches the network or the cloud.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:algaguard_mobile_app/main.dart';
import 'package:algaguard_mobile_app/src/algae_profiles_screen.dart';
import 'package:algaguard_mobile_app/src/app_shell.dart';
import 'package:algaguard_mobile_app/src/organization_access_screen.dart';
import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:algaguard_mobile_app/src/realtime_controller.dart';
import 'package:algaguard_mobile_app/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------- data ----

const _orgId = '6e6825d7-6206-494c-975e-a7857a583986';
const _labOrgId = '9c9b2aa6-59bd-46ae-b2cd-46f4f6bf5ec7';

const _tankA = <String, Object>{
  'deviceUuid': 'a1ed81e4-675c-401d-a333-d31c8699160e',
  'deviceId': 'AG-000001',
  'lifecycle': 'ACTIVE',
  'ownershipVersion': '1',
  'displayName': 'Spirulina Tank A',
};
const _tankB = <String, Object>{
  'deviceUuid': 'b2c4d6e8-1a3b-4c5d-8e7f-9a0b1c2d3e4f',
  'deviceId': 'AG-000002',
  'lifecycle': 'ACTIVE',
  'ownershipVersion': '1',
  'displayName': 'Chlorella Tank B',
};
const _pond = <String, Object>{
  'deviceUuid': 'c3d5e7f9-2b4c-4d6e-9f8a-0b1c2d3e4f5a',
  'deviceId': 'AG-000003',
  'lifecycle': 'ACTIVE',
  'ownershipVersion': '2',
  'displayName': 'Nursery Pond',
};

const _spirulinaProfileId = '7f1e2d3c-4b5a-4968-8776-655443322110';
const _chlorellaProfileId = '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d';

Map<String, Object> _profile(
  String id,
  String name,
  Map<String, List<double>> thresholds,
) => {
  'profileId': id,
  'name': name,
  'current': {
    'version': 3,
    'configuration': {
      'schema': 'urn:algaguard:schema:profile:algae-thresholds:v1',
      'schemaVersion': '1.0.0',
      'parameters': {
        for (final entry in thresholds.entries)
          entry.key: {'minimum': entry.value[0], 'maximum': entry.value[1]},
      },
    },
  },
};

final _profiles = [
  _profile(_spirulinaProfileId, 'Spirulina platensis', {
    'temperatureC': [25, 35],
    'ph': [8.5, 10.5],
    'lightLux': [5000, 30000],
    'nutrientPercent': [40, 90],
    'nitrateMgL': [40, 90],
  }),
  _profile(_chlorellaProfileId, 'Chlorella vulgaris', {
    'temperatureC': [20, 30],
    'ph': [6.5, 8.5],
    'lightLux': [3000, 20000],
    'nutrientPercent': [35, 85],
  }),
];

/// A smooth, believable day-time trend: one reading per call, so the
/// History chart (which charts what it polls) draws a gentle curve.
int _sequence = 1240;
Map<String, Object> _reading({double phase = 0}) {
  _sequence++;
  final t = _sequence / 5 + phase;
  double wobble(double size) => size * math.sin(t * 2.7) * 0.25;
  final ph = 8.92 + 0.18 * math.sin(t / 1.6) + wobble(0.04);
  final temperature = 28.6 + 1.1 * math.sin(t / 2.2) + wobble(0.15);
  return {
    'sequence': '$_sequence',
    'observedAt': DateTime.now()
        .toUtc()
        .subtract(const Duration(seconds: 12))
        .toIso8601String(),
    'timestampQuality': 'NTP_SYNCED',
    'uptimeMs': '${_sequence * 30000}',
    'values': {
      'temperatureC': double.parse(temperature.toStringAsFixed(2)),
      'ph': double.parse(ph.toStringAsFixed(2)),
      'lightLux': (14200 + 1800 * math.sin(t / 3) + wobble(300))
          .roundToDouble(),
      'nutrientPercent': double.parse(
        (71.5 + 2.4 * math.sin(t / 2.8)).toStringAsFixed(1),
      ),
      'nitrateMgL': double.parse((66.8 - 4.1 * (ph - 8.92)).toStringAsFixed(2)),
      'phosphateMgL': double.parse(
        (9.6 + 0.7 * math.sin(t / 2.5)).toStringAsFixed(2),
      ),
      'potassiumMgL': double.parse(
        (27.4 + 0.9 * math.sin(t / 2.1)).toStringAsFixed(2),
      ),
    },
    'qualityFlags': ['REAL'],
    'simulationScenario': 'device-real-sensors',
  };
}

Map<String, Object> _alert(
  String id,
  Map<String, Object> device,
  String parameter,
  String direction,
  double value,
  double? minimum,
  double? maximum,
  Duration ago,
) => {
  'alertId': id,
  'deviceId': device['deviceId']!,
  'parameter': parameter,
  'direction': direction,
  'value': value,
  'minimum': ?minimum,
  'maximum': ?maximum,
  'occurredAt': DateTime.now().toUtc().subtract(ago).toIso8601String(),
};

List<Map<String, Object>> _alerts() => [
  _alert(
    '5d0c8a10-1f2e-4d3c-9b8a-7f6e5d4c3b2a',
    _tankB,
    'temperatureC',
    'HIGH',
    31.6,
    20,
    30,
    const Duration(minutes: 7),
  ),
  _alert(
    '5d0c8a11-1f2e-4d3c-9b8a-7f6e5d4c3b2a',
    _pond,
    'ph',
    'LOW',
    8.21,
    8.5,
    10.5,
    const Duration(minutes: 42),
  ),
  _alert(
    '5d0c8a12-1f2e-4d3c-9b8a-7f6e5d4c3b2a',
    _tankA,
    'lightLux',
    'LOW',
    3870,
    5000,
    30000,
    const Duration(hours: 3, minutes: 15),
  ),
  _alert(
    '5d0c8a13-1f2e-4d3c-9b8a-7f6e5d4c3b2a',
    _tankA,
    'nitrateMgL',
    'LOW',
    37.9,
    40,
    90,
    const Duration(hours: 9),
  ),
  _alert(
    '5d0c8a14-1f2e-4d3c-9b8a-7f6e5d4c3b2a',
    _tankB,
    'nutrientPercent',
    'LOW',
    31.2,
    35,
    85,
    const Duration(days: 1, hours: 2),
  ),
];

// ---------------------------------------------------------- fake server ----

class _Reply {
  const _Reply(this.status, [this.body]);
  final int status;
  final Object? body;
}

_Reply _route(String method, Uri uri) {
  final path = uri.path;
  if (path.endsWith('/protocol/openid-connect/userinfo')) {
    return const _Reply(200, {
      'name': 'Nimsika Bosilu',
      'preferred_username': 'nimsika',
      'email': 'nimsika@algaguard.dev',
    });
  }
  if (path.endsWith('/services/access/organizations') && method == 'GET') {
    return const _Reply(200, {
      'items': [
        {'id': _orgId, 'name': 'Bosilu Algae Farm', 'currentUserRole': 'OWNER'},
        {
          'id': _labOrgId,
          'name': 'Spirulina Research Lab',
          'currentUserRole': 'ADMIN',
        },
      ],
    });
  }
  if (path.endsWith('/services/access/invitations')) {
    return _Reply(200, {
      'items': [
        {
          'id': '3c1d2e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f',
          'organizationName': 'Kandy Algae Co-op',
          'role': 'VIEWER',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(days: 5))
              .toIso8601String(),
        },
        {
          'id': '4d2e3f5a-6b7c-4d8e-9f0a-1b2c3d4e5f6a',
          'organizationName': 'Galle Aqua Lab',
          'role': 'ADMIN',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(days: 2))
              .toIso8601String(),
        },
      ],
    });
  }
  if (path.endsWith('/services/device/devices')) {
    return const _Reply(200, {
      'items': [_tankA, _tankB, _pond],
    });
  }
  if (path.endsWith('/services/telemetry/devices/latest-batch')) {
    return _Reply(200, {
      'items': [
        {'deviceUuid': _tankA['deviceUuid'], 'latest': _reading()},
        {'deviceUuid': _tankB['deviceUuid'], 'latest': _reading(phase: 1.7)},
        {'deviceUuid': _pond['deviceUuid'], 'latest': _reading(phase: 3.1)},
      ],
    });
  }
  final latest = RegExp(
    r'/services/telemetry/devices/([^/]+)/latest$',
  ).firstMatch(path);
  if (latest != null) {
    return _Reply(200, {'deviceUuid': latest.group(1), 'latest': _reading()});
  }
  if (RegExp(
    r'/services/realtime/organizations/[^/]+/alerts$',
  ).hasMatch(path)) {
    return _Reply(200, {'items': _alerts()});
  }
  if (path.endsWith('/services/profile/profiles') && method == 'GET') {
    return _Reply(200, {'items': _profiles});
  }
  if (path.endsWith('/profile-assignment')) {
    return const _Reply(200, {
      'profileId': _spirulinaProfileId,
      'profileVersion': 3,
    });
  }
  // Realtime tickets and anything else: unavailable, so the screens fall
  // back to their HTTPS polling (as they do when the socket drops).
  return const _Reply(503, {'code': 'UNAVAILABLE'});
}

class _FakeHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient();
}

class _FakeHttpClient implements HttpClient {
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  Duration? connectionTimeout;
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeRequest(method, url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.method, this.uri);
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _FakeHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  @override
  int contentLength = -1;
  @override
  bool bufferOutput = true;

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  void add(List<int> data) {}
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  Future<HttpClientResponse> close() async {
    final reply = _route(method, uri);
    return _FakeResponse(reply.status, utf8.encode(jsonEncode(reply.body)));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this._bytes);
  final List<int> _bytes;
  @override
  final int statusCode;
  @override
  final HttpHeaders headers = _FakeHeaders()
    ..set('content-type', 'application/json; charset=utf-8');
  @override
  String get reasonPhrase => statusCode == 200 ? 'OK' : 'Unavailable';
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  X509Certificate? get certificate => null;
  @override
  int get contentLength => _bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  bool get persistentConnection => false;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  final _values = <String, List<String>>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = ['$value'];
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      (_values[name.toLowerCase()] ??= []).add('$value');
  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];
  @override
  String? value(String name) => _values[name.toLowerCase()]?.join(',');
  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _values.forEach(action);
  @override
  void removeAll(String name) => _values.remove(name.toLowerCase());
  @override
  ContentType? contentType;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ------------------------------------------------------------- harness ----

Future<void> _loadFonts() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final fonts = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> read(String file) async =>
      ByteData.sublistView(await File('$fonts/$file').readAsBytes());
  final roboto = FontLoader('Roboto');
  for (final file in [
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
    'roboto-light.ttf',
  ]) {
    roboto.addFont(read(file));
  }
  await roboto.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(read('materialicons-regular.otf'))).load();
}

ThemeData _withRoboto(ThemeData theme) => theme.copyWith(
  textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
  primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'Roboto'),
  // The app's chip label style sets only a colour, so it would otherwise
  // fall back to the test font (solid blocks) instead of Roboto.
  chipTheme: theme.chipTheme.copyWith(
    labelStyle: (theme.chipTheme.labelStyle ?? const TextStyle()).copyWith(
      fontFamily: 'Roboto',
    ),
    secondaryLabelStyle:
        (theme.chipTheme.secondaryLabelStyle ?? const TextStyle()).copyWith(
          fontFamily: 'Roboto',
        ),
  ),
);

/// A live connection that stays open, so screens show the normal
/// "connected" state instead of "Realtime disconnected".
class _ConnectedRealtime implements RealtimeConnection {
  _ConnectedRealtime(this.ticket, this.onState);
  final Future<String> Function() ticket;
  final void Function(RealtimeClientState state) onState;

  @override
  Future<void> connect() async {
    await ticket();
    onState(RealtimeClientState.ready);
  }

  @override
  Future<void> close() async {}
}

final _realtimeOverride = realtimeControllerProvider.overrideWith(
  (ref) => RealtimeSessionController(
    url: Uri.parse('wss://realtime.test/realtime'),
    accessToken: () async => 'sample-access-token',
    requestTicket: (_) async => 'sample-ticket',
    recover: () async {},
    connectionFactory:
        ({required ticket, required recover, required onState}) =>
            _ConnectedRealtime(ticket, onState),
  ),
);

Widget _app(Widget home, {bool dark = false}) => ProviderScope(
  overrides: [_realtimeOverride],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _withRoboto(AppTheme.light),
    darkTheme: _withRoboto(AppTheme.dark),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    home: home,
  ),
);

Future<void> _settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  await _settle(tester, frames: 5);
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../../screenshots/$name.png'),
  );
}

Future<void> _tearDown(WidgetTester tester) async {
  // Dispose the tree so polling timers and controllers stop cleanly.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  // Flutter requires debug paint flags to be restored inside the test body.
  debugDisableShadows = true;
}

void main() {
  setUpAll(_loadFonts);

  setUp(() {
    HttpOverrides.global = _FakeHttpOverrides();
    // This file is a test run by `flutter test`; it lives in tool/ only so
    // the normal suite does not regenerate the images.
    // ignore: invalid_use_of_visible_for_testing_member
    FlutterSecureStorage.setMockInitialValues({
      'oidc_access_token': 'sample-access-token',
      'oidc_refresh_token': 'sample-refresh-token',
      'oidc_access_token_expiry': DateTime.now()
          .add(const Duration(hours: 8))
          .toUtc()
          .toIso8601String(),
      'selected_organization_id': _orgId,
    });
  });

  void sized(WidgetTester tester) {
    // Pixel 8: 1080 x 2400 at 2.625.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    debugDisableShadows = false; // real elevation shadows in the images
  }

  for (final dark in [false, true]) {
    final suffix = dark ? '_dark' : '';

    testWidgets('main tabs$suffix', (tester) async {
      sized(tester);
      await tester.pumpWidget(_app(const AppShell(), dark: dark));
      // Let History poll a few minutes of readings so its chart has a trend.
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(seconds: 8));
      }
      await _settle(tester);
      await _shot(tester, '01_home$suffix');

      await tester.tap(find.text('Devices'));
      await _shot(tester, '02_devices$suffix');

      await tester.tap(find.text('History'));
      await _shot(tester, '03_history_temperature$suffix');
      if (!dark) {
        for (final (label, file) in [
          ('pH', '04_history_ph'),
          ('Nitrate (estimated)', '05_history_nitrate'),
        ]) {
          final chip = find.text(label);
          if (chip.evaluate().isNotEmpty) {
            await tester.tap(chip.first);
            await _shot(tester, file);
          }
        }
      }

      await tester.tap(find.text('Alerts'));
      await _settle(tester);
      await _shot(tester, '06_alerts$suffix');

      await tester.tap(find.text('Profile'));
      await _settle(tester);
      await _shot(tester, '07_profile$suffix');
      await _tearDown(tester);
    });

    testWidgets('device details$suffix', (tester) async {
      sized(tester);
      await tester.pumpWidget(
        _app(
          DeviceDetailsScreen(device: DeviceSummary.fromJson(_tankA)),
          dark: dark,
        ),
      );
      // In the app AppShell starts the live connection; do the same here.
      ProviderScope.containerOf(
        tester.element(find.byType(DeviceDetailsScreen)),
      ).read(realtimeControllerProvider).start();
      await _settle(tester, frames: 30);
      await _shot(tester, '08_device_details$suffix');
      await _tearDown(tester);
    });
  }

  testWidgets('algae profiles', (tester) async {
    sized(tester);
    await tester.pumpWidget(
      _app(AlgaeProfilesScreen(apiBaseUrl: Uri.parse('https://api.test/v1'))),
    );
    await _settle(tester, frames: 30);
    await _shot(tester, '09_algae_profiles');
    await _tearDown(tester);
  });

  testWidgets('organizations', (tester) async {
    sized(tester);
    await tester.pumpWidget(_app(const OrganizationScreen()));
    await _settle(tester, frames: 30);
    await _shot(tester, '10_organizations');
    await _tearDown(tester);
  });

  testWidgets('invitations', (tester) async {
    sized(tester);
    await tester.pumpWidget(
      _app(
        OrganizationAccessScreen(apiBaseUrl: Uri.parse('https://api.test/v1')),
      ),
    );
    await _settle(tester, frames: 30);
    await _shot(tester, '11_team_invitations');
    await _tearDown(tester);
  });

  // "Fits every phone" check: render every screen on narrow and short
  // phones and with a larger font. Any RenderFlex overflow (the yellow and
  // black "BOTTOM OVERFLOWED BY n PIXELS" stripe) fails the test.
  const phones = <(String, Size, double, double)>[
    ('realme_360x785', Size(720, 1570), 2.0, 1.0),
    ('small_360x640', Size(720, 1280), 2.0, 1.0),
    ('small_large_text', Size(720, 1280), 2.0, 1.3),
    ('compact_320x640', Size(640, 1280), 2.0, 1.0),
  ];
  for (final (name, size, ratio, textScale) in phones) {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = ratio;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      debugDisableShadows = false;
    }

    Future<void> scrolledShots(WidgetTester tester, String screen) async {
      await _shot(tester, 'fit/$name/${screen}_top');
      final scrollables = find.byType(Scrollable);
      if (scrollables.evaluate().isNotEmpty) {
        await tester.drag(scrollables.first, const Offset(0, -3000));
        await _settle(tester, frames: 5);
        await _shot(tester, 'fit/$name/${screen}_bottom');
      }
    }

    testWidgets('fits $name: tabs', (tester) async {
      phone(tester);
      await tester.pumpWidget(_app(const AppShell()));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 8));
      }
      await _settle(tester);
      await scrolledShots(tester, 'home');
      for (final tab in ['Devices', 'History', 'Alerts', 'Profile']) {
        await tester.tap(find.text(tab).last);
        await _settle(tester);
        await scrolledShots(tester, tab.toLowerCase());
      }
      await _tearDown(tester);
    });

    testWidgets('fits $name: other screens', (tester) async {
      phone(tester);
      for (final (screen, widget) in <(String, Widget)>[
        (
          'device_details',
          DeviceDetailsScreen(device: DeviceSummary.fromJson(_tankA)),
        ),
        (
          'algae_profiles',
          AlgaeProfilesScreen(apiBaseUrl: Uri.parse('https://api.test/v1')),
        ),
        ('organizations', const OrganizationScreen()),
        (
          'invitations',
          OrganizationAccessScreen(
            apiBaseUrl: Uri.parse('https://api.test/v1'),
          ),
        ),
      ]) {
        await tester.pumpWidget(_app(widget));
        await _settle(tester, frames: 30);
        await scrolledShots(tester, screen);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }
      await _tearDown(tester);
    });
  }
}
