import 'package:algaguard_mobile_app/src/platform_clients.dart';
import 'package:algaguard_mobile_app/src/realtime_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRealtimeConnection implements RealtimeConnection {
  _FakeRealtimeConnection({required this.ticket, required this.onState});

  final Future<String> Function() ticket;
  final void Function(RealtimeClientState state) onState;
  int connectCalls = 0;
  int closeCalls = 0;
  String? receivedTicket;

  @override
  Future<void> connect() async {
    connectCalls += 1;
    receivedTicket = await ticket();
    onState(RealtimeClientState.authenticating);
  }

  void ready() => onState(RealtimeClientState.ready);
  void reconnecting() => onState(RealtimeClientState.reconnecting);
  void authenticationFailed() =>
      onState(RealtimeClientState.authenticationFailed);

  @override
  Future<void> close() async {
    closeCalls += 1;
    onState(RealtimeClientState.disconnected);
  }
}

class _ConnectionHarness {
  _FakeRealtimeConnection? connection;

  RealtimeConnection create({
    required Future<String> Function() ticket,
    required Future<void> Function() recover,
    required void Function(RealtimeClientState state) onState,
  }) {
    return connection = _FakeRealtimeConnection(
      ticket: ticket,
      onState: onState,
    );
  }
}

RealtimeSessionController _controller(
  _ConnectionHarness harness, {
  Future<String?> Function()? accessToken,
  Future<String> Function(String accessToken)? requestTicket,
}) => RealtimeSessionController(
  url: Uri.parse('wss://realtime.example.test/realtime'),
  accessToken: accessToken ?? () async => 'authenticated-access',
  requestTicket: requestTicket ?? (_) async => 'one-time-ticket',
  recover: () async {},
  connectionFactory: harness.create,
);

void main() {
  test(
    'authenticated session acquires one authoritative ticket and client',
    () async {
      final harness = _ConnectionHarness();
      var ticketRequests = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            ticketRequests += 1;
            expect(options.method, 'POST');
            expect(options.path, '/services/realtime/tickets');
            expect(
              options.headers['Authorization'],
              'Bearer authenticated-access',
            );
            handler.resolve(
              Response<Object>(
                requestOptions: options,
                statusCode: 201,
                data: {'ticket': 'one-time-ticket'},
              ),
            );
          },
        ),
      );
      final api = PlatformApi(
        Uri.parse('https://api.example.test/v1'),
        client: dio,
      );
      final controller = _controller(
        harness,
        requestTicket: (accessToken) =>
            api.requestRealtimeTicket(accessToken: accessToken),
      );

      await controller.start();

      expect(ticketRequests, 1);
      expect(harness.connection?.connectCalls, 1);
      expect(harness.connection?.receivedTicket, 'one-time-ticket');
      await controller.stop();
    },
  );

  test(
    'unauthenticated state never requests a ticket or opens a socket',
    () async {
      final harness = _ConnectionHarness();
      var ticketRequests = 0;
      final controller = _controller(
        harness,
        accessToken: () async => null,
        requestTicket: (_) async {
          ticketRequests += 1;
          return 'one-time-ticket';
        },
      );

      await controller.start();

      expect(ticketRequests, 0);
      expect(harness.connection, isNull);
      expect(controller.state, RealtimeSessionState.signedOut);
    },
  );

  test(
    'authenticated handshake maps to ready with exact safe UI text',
    () async {
      final harness = _ConnectionHarness();
      final controller = _controller(harness);

      await controller.start();
      harness.connection!.ready();

      expect(controller.state, RealtimeSessionState.ready);
      expect(controller.state.visibleText, 'REALTIME CONNECTED');
      expect(controller.ticketPresent, isFalse);
      await controller.stop();
    },
  );

  test(
    'duplicate starts do not create duplicate ticket requests or sockets',
    () async {
      final harness = _ConnectionHarness();
      var ticketRequests = 0;
      final controller = _controller(
        harness,
        requestTicket: (_) async {
          ticketRequests += 1;
          return 'one-time-ticket';
        },
      );

      await Future.wait([controller.start(), controller.start()]);

      expect(ticketRequests, 1);
      expect(harness.connection?.connectCalls, 1);
      await controller.stop();
    },
  );

  test(
    'transient recovery is bounded while authentication failure is terminal',
    () async {
      final harness = _ConnectionHarness();
      final controller = _controller(harness);

      await controller.start();
      harness.connection!.reconnecting();
      expect(controller.state, RealtimeSessionState.reconnecting);
      harness.connection!.authenticationFailed();

      expect(controller.state, RealtimeSessionState.authenticationFailed);
      expect(harness.connection?.connectCalls, 1);
      await controller.stop();
    },
  );

  test('logout clears connection and only safe state remains', () async {
    final harness = _ConnectionHarness();
    final controller = _controller(harness);

    await controller.start();
    await controller.stop();

    expect(harness.connection?.closeCalls, 1);
    expect(controller.state, RealtimeSessionState.signedOut);
    expect(controller.ticketPresent, isFalse);
    expect(controller.reconnectScheduled, isFalse);
    expect(controller.state.visibleText, 'Realtime disconnected');
  });
}
