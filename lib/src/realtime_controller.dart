import 'package:flutter/foundation.dart';

import 'platform_clients.dart';

enum RealtimeSessionState {
  signedOut,
  ticketRequesting,
  ticketReady,
  ticketRejected,
  ticketExpired,
  ticketUnavailable,
  connecting,
  authenticating,
  ready,
  reconnecting,
  unavailable,
  authenticationFailed,
  disconnected,
}

extension RealtimeSessionStateText on RealtimeSessionState {
  String get visibleText => switch (this) {
    RealtimeSessionState.ready => 'REALTIME CONNECTED',
    RealtimeSessionState.connecting ||
    RealtimeSessionState.authenticating => 'Realtime connecting',
    RealtimeSessionState.reconnecting => 'Realtime reconnecting',
    RealtimeSessionState.authenticationFailed =>
      'Realtime authentication failed',
    RealtimeSessionState.signedOut ||
    RealtimeSessionState.disconnected => 'Realtime disconnected',
    _ => 'Realtime unavailable',
  };
}

typedef RealtimeConnectionFactory =
    RealtimeConnection Function({
      required Future<String> Function() ticket,
      required Future<void> Function() recover,
      required void Function(RealtimeClientState state) onState,
    });

class RealtimeSessionController extends ChangeNotifier {
  RealtimeSessionController({
    required this.url,
    required this.accessToken,
    required this.requestTicket,
    required this.recover,
    RealtimeConnectionFactory? connectionFactory,
    this.subscriptions,
    this.onEvent,
  }) {
    _connectionFactory =
        connectionFactory ??
        _defaultFactory(url, subscriptions, acceptSafeEvent);
  }

  final Uri url;
  final Future<String?> Function() accessToken;
  final Future<String> Function(String accessToken) requestTicket;
  final Future<void> Function() recover;
  late final RealtimeConnectionFactory _connectionFactory;
  final Future<List<Map<String, Object>>> Function()? subscriptions;
  final void Function(Map<String, dynamic> event)? onEvent;
  RealtimeConnection? _connection;
  RealtimeSessionState _state = RealtimeSessionState.signedOut;
  bool _starting = false;
  bool _ticketPresent = false;
  int _generation = 0;
  int _eventRevision = 0;
  bool _disposed = false;

  RealtimeSessionState get state => _state;
  bool get ticketPresent => _ticketPresent;
  bool get reconnectScheduled => _state == RealtimeSessionState.reconnecting;
  int get eventRevision => _eventRevision;

  static RealtimeConnectionFactory _defaultFactory(
    Uri url,
    Future<List<Map<String, Object>>> Function()? subscriptions,
    void Function(Map<String, dynamic> event) onEvent,
  ) =>
      ({
        required Future<String> Function() ticket,
        required Future<void> Function() recover,
        required void Function(RealtimeClientState state) onState,
      }) => RealtimeRecoveryClient(
        url: url,
        ticket: ticket,
        recover: recover,
        onState: onState,
        subscriptions: subscriptions,
        onEvent: onEvent,
      );

  Future<void> start() async {
    if (_disposed || _starting || _connection != null) return;
    _starting = true;
    final generation = _generation;
    try {
      final token = await accessToken();
      if (_disposed || generation != _generation || token == null) return;
      _connection = _connectionFactory(
        ticket: _requestTicket,
        recover: recover,
        onState: _onClientState,
      );
      await _connection!.connect();
    } finally {
      _starting = false;
    }
  }

  Future<String> _requestTicket() async {
    final token = await accessToken();
    if (_disposed || token == null) {
      throw const RealtimeTicketException(RealtimeTicketFailure.rejected);
    }
    _setState(RealtimeSessionState.ticketRequesting);
    try {
      final ticket = await requestTicket(token);
      if (_disposed) {
        throw const RealtimeTicketException(RealtimeTicketFailure.rejected);
      }
      _ticketPresent = true;
      _setState(RealtimeSessionState.ticketReady);
      return ticket;
    } on RealtimeTicketException catch (error) {
      _ticketPresent = false;
      _setState(switch (error.failure) {
        RealtimeTicketFailure.rejected => RealtimeSessionState.ticketRejected,
        RealtimeTicketFailure.expired => RealtimeSessionState.ticketExpired,
        RealtimeTicketFailure.unavailable =>
          RealtimeSessionState.ticketUnavailable,
      });
      rethrow;
    } catch (_) {
      _ticketPresent = false;
      _setState(RealtimeSessionState.ticketUnavailable);
      throw const RealtimeTicketException.unavailable();
    }
  }

  void _onClientState(RealtimeClientState state) {
    if (_disposed) return;
    _ticketPresent = false;
    _setState(switch (state) {
      RealtimeClientState.connecting => RealtimeSessionState.connecting,
      RealtimeClientState.authenticating => RealtimeSessionState.authenticating,
      RealtimeClientState.ready => RealtimeSessionState.ready,
      RealtimeClientState.reconnecting => RealtimeSessionState.reconnecting,
      RealtimeClientState.unavailable => RealtimeSessionState.unavailable,
      RealtimeClientState.authenticationFailed =>
        RealtimeSessionState.authenticationFailed,
      RealtimeClientState.disconnected => RealtimeSessionState.disconnected,
    });
  }

  void acceptSafeEvent(Map<String, dynamic> event) {
    if (_disposed || event['eventType'] != 'telemetry.updated') return;
    _eventRevision++;
    onEvent?.call(event);
    notifyListeners();
  }

  Future<void> stop() async {
    _generation++;
    _starting = false;
    _ticketPresent = false;
    final connection = _connection;
    _connection = null;
    await connection?.close();
    _setState(RealtimeSessionState.signedOut);
  }

  void _setState(RealtimeSessionState value) {
    if (_state == value) return;
    _state = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _ticketPresent = false;
    final connection = _connection;
    _connection = null;
    if (connection != null) {
      void close() async => connection.close();
      close();
    }
    super.dispose();
  }
}
