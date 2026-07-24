import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'environment.dart';
import 'onboarding.dart';

class TokenStore {
  const TokenStore(this.storage);
  final FlutterSecureStorage storage;
  Future<void> save({required String accessToken, String? refreshToken}) async {
    await storage.write(key: 'oidc_access_token', value: accessToken);
    if (refreshToken != null) {
      await storage.write(key: 'oidc_refresh_token', value: refreshToken);
    }
  }

  Future<String?> readAccessToken() =>
      storage.read(key: 'oidc_access_token');
  Future<String?> readRefreshToken() =>
      storage.read(key: 'oidc_refresh_token');

  Future<void> clear() async {
    await storage.delete(key: 'oidc_access_token');
    await storage.delete(key: 'oidc_refresh_token');
  }
}

class OidcClient {
  OidcClient(this.environment, this.store, {FlutterAppAuth? appAuth})
    : _appAuth = appAuth ?? FlutterAppAuth();
  final AppEnvironment environment;
  final TokenStore store;
  final FlutterAppAuth _appAuth;

  Future<void> login() async {
    final response = await _appAuth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        environment.keycloakClientId,
        environment.redirectUri,
        issuer: environment.keycloakIssuer.toString(),
        scopes: const ['openid', 'profile', 'email', 'offline_access'],
      ),
    );
    if (response.accessToken == null) {
      throw StateError('Keycloak did not return an access token');
    }
    await store.save(
      accessToken: response.accessToken!,
      refreshToken: response.refreshToken,
    );
  }

  Future<String?> refresh() async {
    final refreshToken = await store.readRefreshToken();
    if (refreshToken == null) return null;
    final response = await _appAuth.token(
      TokenRequest(
        environment.keycloakClientId,
        environment.redirectUri,
        issuer: environment.keycloakIssuer.toString(),
        refreshToken: refreshToken,
      ),
    );
    if (response.accessToken == null) return null;
    await store.save(
      accessToken: response.accessToken!,
      refreshToken: response.refreshToken ?? refreshToken,
    );
    return response.accessToken;
  }

  Future<void> logout() => store.clear();
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

class FlutterBlueProvisioner implements BleProvisioner {
  @override
  Future<void> provision({
    required String serviceId,
    required String ssid,
    required String password,
  }) async {
    final serviceGuid = Guid(serviceId);
    await FlutterBluePlus.startScan(
      withServices: [serviceGuid],
      timeout: const Duration(seconds: 15),
    );
    final results = await FlutterBluePlus.scanResults
        .where((items) => items.isNotEmpty)
        .first;
    final device = results
        .firstWhere(
          (result) =>
              result.advertisementData.serviceUuids.contains(serviceGuid),
        )
        .device;
    await FlutterBluePlus.stopScan();
    await device.connect(timeout: const Duration(seconds: 15));
    try {
      final services = await device.discoverServices();
      final characteristic = services
          .expand((service) => service.characteristics)
          .where(
            (item) =>
                item.properties.write || item.properties.writeWithoutResponse,
          )
          .cast<BluetoothCharacteristic?>()
          .firstWhere((item) => item != null, orElse: () => null);
      if (characteristic == null) {
        throw StateError('No writable AlgaGuard provisioning characteristic');
      }
      await characteristic.write(
        BleProtocol.wifiCredentials(ssid, password),
        withoutResponse: characteristic.properties.writeWithoutResponse,
      );
    } finally {
      await device.disconnect();
    }
  }
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
