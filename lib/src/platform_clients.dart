import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'ble_provisioning_wire.dart';
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

  // Keep credentials in secure storage; callers receive them only when needed.
  Future<String?> readAccessToken() => storage.read(key: 'oidc_access_token');
  Future<String?> readRefreshToken() => storage.read(key: 'oidc_refresh_token');

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
  PlatformApi(Uri baseUrl, {Dio? client})
    : dio =
          client ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl.toString(),
              connectTimeout: const Duration(seconds: 10),
            ),
          );
  final Dio dio;
  Future<ProvisioningSession> consumeClaim({
    required String accessToken,
    required String organizationId,
    required QrClaim claim,
  }) async {
    final response = await dio.post<Object>(
      '/claims/consume',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {
        'organizationId': organizationId,
        'deviceId': claim.deviceId,
        'claimCode': claim.claimCode,
      },
    );
    final root = Map<String, dynamic>.from(response.data! as Map);
    final bootstrap = Map<String, dynamic>.from(root['bootstrap'] as Map);
    if (root['device'] is! Map ||
        bootstrap['deviceId'] != claim.deviceId ||
        bootstrap['sessionId'] is! String ||
        bootstrap['sessionToken'] is! String ||
        bootstrap['expiresAt'] is! String) {
      throw const FormatException('Invalid claim response');
    }
    return ProvisioningSession(
      sessionId: bootstrap['sessionId'] as String,
      deviceId: bootstrap['deviceId'] as String,
      expiresAt: DateTime.parse(bootstrap['expiresAt'] as String).toUtc(),
      sessionToken: bootstrap['sessionToken'] as String,
    );
  }

  /// Development-only approval. Callers must keep the supplied session in RAM
  /// and must not log or persist the request body.
  Future<void> approvePhysicalSessionHandoff({
    required String accessToken,
    required String userCode,
    required ProvisioningSession session,
  }) async {
    final normalizedCode = userCode.toUpperCase().replaceAll(
      RegExp(r'[ -]'),
      '',
    );
    if (!RegExp(r'^[A-HJ-NP-Z2-9]{6,16}$').hasMatch(normalizedCode) ||
        session.isExpired) {
      throw const FormatException('HANDOFF_APPROVAL_UNAVAILABLE');
    }
    await dio.post<void>(
      '/development/physical-session-handoffs/approve',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {
        'protocolVersion': 1,
        'userCode': normalizedCode,
        'sessionId': session.sessionId,
        'deviceId': session.deviceId,
        'sessionToken': session.takeToken(),
      },
    );
  }

  Future<bool> secureTransportHealthPreflight() async {
    final response = await dio.get<void>(
      '/health',
      options: Options(
        sendTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        followRedirects: false,
      ),
    );
    return response.statusCode == 200;
  }
}

class FlutterBlueProvisioner implements BleProvisioner {
  FlutterBlueProvisioner({Random? random})
    : _random = random ?? Random.secure();

  final Random _random;
  final Set<int> _usedMessageIds = <int>{};

  @override
  Future<void> provision({
    required String serviceId,
    required String sessionId,
    required String deviceId,
    required String sessionToken,
    required String ssid,
    required String password,
    void Function(SafeProvisioningStatus status)? onStatus,
  }) async {
    if (serviceId.toLowerCase() != bleProvisioningServiceUuid) {
      throw const BleProvisioningWireException('SERVICE_NOT_FOUND');
    }
    final serviceGuid = Guid(bleProvisioningServiceUuid);
    await FlutterBluePlus.startScan(
      withServices: [serviceGuid],
      timeout: const Duration(seconds: 15),
    );
    final results = await FlutterBluePlus.scanResults
        .where((items) => items.isNotEmpty)
        .first;
    final matchingResults = results.where(
      (result) => result.advertisementData.serviceUuids.contains(serviceGuid),
    );
    if (matchingResults.isEmpty) {
      throw const BleProvisioningWireException('SERVICE_NOT_FOUND');
    }
    final device = matchingResults.first.device;
    await FlutterBluePlus.stopScan();
    await device.connect(timeout: const Duration(seconds: 15));

    StreamSubscription<List<int>>? statusSubscription;
    StreamSubscription<BluetoothConnectionState>? connectionSubscription;
    BluetoothCharacteristic? statusCharacteristic;
    final ready = Completer<void>();
    final terminal = Completer<SafeProvisioningStatus>();
    var latestStatus = const SafeProvisioningStatus(
      SafeProvisioningState.cancelled,
      'DISCONNECTED',
    );
    var payload = <int>[];
    var frames = <List<int>>[];
    SequentialFrameWriter? writer;
    try {
      final services = await device.discoverServices();
      final contractServices = services
          .map(
            (service) => BleServiceContract(
              uuid: service.uuid.toString(),
              characteristics: service.characteristics
                  .map(
                    (characteristic) => BleCharacteristicContract(
                      uuid: characteristic.uuid.toString(),
                      canRead: characteristic.properties.read,
                      canWriteWithResponse: characteristic.properties.write,
                      canWriteWithoutResponse:
                          characteristic.properties.writeWithoutResponse,
                      canNotify: characteristic.properties.notify,
                    ),
                  )
                  .toList(growable: false),
            ),
          )
          .toList(growable: false);
      BleProvisioningWire.selectCharacteristics(contractServices);
      final service = services.firstWhere(
        (candidate) =>
            candidate.uuid.toString().toLowerCase() ==
            bleProvisioningServiceUuid,
      );
      final request = service.characteristics.firstWhere(
        (candidate) =>
            candidate.uuid.toString().toLowerCase() ==
            bleProvisioningRequestUuid,
      );
      statusCharacteristic = service.characteristics.firstWhere(
        (candidate) =>
            candidate.uuid.toString().toLowerCase() ==
            bleProvisioningStatusUuid,
      );

      void observeStatus(List<int> bytes) {
        try {
          latestStatus = BleProvisioningWire.decodeSafeStatus(bytes);
          onStatus?.call(latestStatus);
          if (latestStatus.state == SafeProvisioningState.ready &&
              !ready.isCompleted) {
            ready.complete();
          }
          if (latestStatus.isTerminal && !terminal.isCompleted) {
            terminal.complete(latestStatus);
          }
        } on BleProvisioningWireException catch (error, stackTrace) {
          if (!ready.isCompleted) ready.completeError(error, stackTrace);
          if (!terminal.isCompleted) terminal.completeError(error, stackTrace);
        }
      }

      statusSubscription = statusCharacteristic.lastValueStream.listen(
        observeStatus,
      );
      connectionSubscription = device.connectionState.listen((connectionState) {
        if (connectionState == BluetoothConnectionState.disconnected) {
          final disconnected = const SafeProvisioningStatus(
            SafeProvisioningState.cancelled,
            'DISCONNECTED',
          );
          onStatus?.call(disconnected);
          if (!ready.isCompleted) {
            ready.completeError(
              const BleProvisioningWireException('DISCONNECTED'),
            );
          }
          if (!terminal.isCompleted) {
            terminal.complete(disconnected);
          }
        }
      });
      await statusCharacteristic.setNotifyValue(true);
      observeStatus(await statusCharacteristic.read());
      if (latestStatus.state != SafeProvisioningState.ready) {
        await ready.future.timeout(const Duration(seconds: 15));
      }

      payload = BleProtocol.provisioningRequest(
        sessionId: sessionId,
        deviceId: deviceId,
        sessionToken: sessionToken,
        ssid: ssid,
        password: password,
      );
      frames = BleProvisioningWire.framePayload(payload, _nextMessageId());
      writer = SequentialFrameWriter(frames);
      while (writer.hasPending) {
        final frame = writer.current;
        await request
            .write(frame, withoutResponse: false)
            .timeout(const Duration(seconds: 15));
        writer.acknowledgeWrite();
      }
      final completion = await terminal.future.timeout(
        const Duration(seconds: 30),
      );
      if (!completion.isAccepted) {
        throw BleProvisioningWireException(completion.reason);
      }
    } finally {
      writer?.clear();
      payload.fillRange(0, payload.length, 0);
      await statusSubscription?.cancel();
      await connectionSubscription?.cancel();
      try {
        await statusCharacteristic?.setNotifyValue(false);
      } catch (_) {
        // Disconnect is still required; status cleanup errors carry no secret data.
      }
      await device.disconnect();
    }
  }

  int _nextMessageId() {
    for (var attempts = 0; attempts < 32; attempts++) {
      final messageId = _random.nextInt(0x7fffffff) + 1;
      if (_usedMessageIds.add(messageId)) return messageId;
    }
    throw const BleProvisioningWireException('MESSAGE_ID_UNAVAILABLE');
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
