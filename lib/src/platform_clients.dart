import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStore {
  const TokenStore(this.storage);
  final FlutterSecureStorage storage;
  Future<void> save(String token) =>
      storage.write(key: 'oidc_access_token', value: token);
  Future<String?> read() => storage.read(key: 'oidc_access_token');
  Future<void> clear() => storage.delete(key: 'oidc_access_token');
}

class PlatformApi {
  PlatformApi(Uri baseUrl)
    : dio = Dio(
        BaseOptions(
          baseUrl: baseUrl.toString(),
          connectTimeout: const Duration(seconds: 10),
        ),
      );
  final Dio dio;
  Future<Map<String, dynamic>> claim(String code) async =>
      Map<String, dynamic>.from(
        (await dio.post<Object>('/claims', data: {'claimCode': code})).data!
            as Map,
      );
}

class RealtimeRecoveryClient {
  RealtimeRecoveryClient({
    required this.url,
    required this.ticket,
    required this.recover,
  });
  final Uri url;
  final Future<String> Function() ticket;
  final Future<void> Function() recover;
  WebSocket? _socket;
  bool _stopped = false;
  Future<void> connect() async {
    final oneTimeTicket = await ticket();
    _socket = await WebSocket.connect(
      url.replace(queryParameters: {'ticket': oneTimeTicket}).toString(),
    );
    await recover();
    _socket!.add(
      jsonEncode({
        'schema': 'algaguard.websocket.subscribe',
        'schemaVersion': '1.0.0',
        'requestId': 'mobile-session',
        'subscriptions': [
          {
            'resourceType': 'current-user',
            'events': ['system.notification'],
          },
        ],
      }),
    );
    _socket!.done.then((_) => _reconnect());
  }

  Future<void> _reconnect() async {
    if (_stopped) return;
    await Future<void>.delayed(const Duration(seconds: 1));
    await connect();
  }

  Future<void> close() async {
    _stopped = true;
    await _socket?.close();
  }
}
