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
import 'demo_telemetry.dart';
import 'qr_onboarding.dart';
import 'algae_profiles.dart';

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int value) => value.toRadixString(16).padLeft(2, '0');
  final value = bytes.map(hex).join();
  return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
      '${value.substring(12, 16)}-${value.substring(16, 20)}-'
      '${value.substring(20)}';
}

class TokenStore {
  const TokenStore(this.storage);
  final FlutterSecureStorage storage;
  static const _accessTokenKey = 'oidc_access_token';
  static const _refreshTokenKey = 'oidc_refresh_token';
  static const _accessTokenExpiryKey = 'oidc_access_token_expiry';
  static const _selectedOrganizationKey = 'selected_organization_id';
  static const _pushInstallationKey = 'push_installation_id';

  Future<void> save({
    required String accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiresAt,
  }) async {
    await storage.write(key: _accessTokenKey, value: accessToken);
    if (refreshToken != null) {
      await storage.write(key: _refreshTokenKey, value: refreshToken);
    }
    if (accessTokenExpiresAt != null) {
      await storage.write(
        key: _accessTokenExpiryKey,
        value: accessTokenExpiresAt.toUtc().toIso8601String(),
      );
    }
  }

  // Keep credentials in secure storage; callers receive them only when needed.
  Future<String?> readAccessToken() => storage.read(key: _accessTokenKey);
  Future<String?> readRefreshToken() => storage.read(key: _refreshTokenKey);
  Future<DateTime?> readAccessTokenExpiry() async {
    final value = await storage.read(key: _accessTokenExpiryKey);
    return value == null ? null : DateTime.tryParse(value)?.toUtc();
  }

  Future<void> selectOrganization(String organizationId) async {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(organizationId)) {
      throw const FormatException('Invalid organization identifier');
    }
    await storage.write(key: _selectedOrganizationKey, value: organizationId);
  }

  Future<String?> readSelectedOrganization() =>
      storage.read(key: _selectedOrganizationKey);

  Future<void> clearSelectedOrganization() =>
      storage.delete(key: _selectedOrganizationKey);

  Future<String> readOrCreatePushInstallationId() async {
    final existing = await storage.read(key: _pushInstallationKey);
    if (existing != null &&
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false,
        ).hasMatch(existing)) {
      return existing;
    }
    final created = _uuidV4();
    await storage.write(key: _pushInstallationKey, value: created);
    return created;
  }

  Future<String?> readPushInstallationId() =>
      storage.read(key: _pushInstallationKey);

  Future<void> clearPushInstallationId() =>
      storage.delete(key: _pushInstallationKey);

  Future<void> clear() async {
    await storage.delete(key: _accessTokenKey);
    await storage.delete(key: _refreshTokenKey);
    await storage.delete(key: _accessTokenExpiryKey);
    await storage.delete(key: _selectedOrganizationKey);
  }
}

class OidcUserProfile {
  const OidcUserProfile({
    required this.displayName,
    required this.username,
    required this.email,
  });

  factory OidcUserProfile.fromJson(Map<String, dynamic> value) {
    String? bounded(String key, int maximum) {
      final field = value[key];
      if (field is! String || field.trim().isEmpty || field.length > maximum) {
        return null;
      }
      return field.trim();
    }

    final profile = OidcUserProfile(
      displayName: bounded('name', 200),
      username: bounded('preferred_username', 128),
      email: bounded('email', 254),
    );
    if (profile.displayName == null &&
        profile.username == null &&
        profile.email == null) {
      throw const FormatException('Account profile is unavailable');
    }
    return profile;
  }

  final String? displayName;
  final String? username;
  final String? email;
  String get primaryLabel =>
      displayName ?? username ?? email ?? 'Signed-in account';
}

class OidcClient {
  OidcClient(
    this.environment,
    this.store, {
    FlutterAppAuth? appAuth,
    Dio? httpClient,
  }) : _appAuth = appAuth ?? FlutterAppAuth(),
       _httpClient = httpClient ?? Dio();
  final AppEnvironment environment;
  final TokenStore store;
  final FlutterAppAuth _appAuth;
  final Dio _httpClient;

  Future<void> login() async {
    final response = await _appAuth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        environment.keycloakClientId,
        environment.redirectUri,
        issuer: environment.keycloakIssuer.toString(),
        scopes: const ['openid', 'profile', 'email', 'offline_access'],
        promptValues: const ['select_account'],
      ),
    );
    if (response.accessToken == null) {
      throw StateError('Keycloak did not return an access token');
    }
    await store.save(
      accessToken: response.accessToken!,
      refreshToken: response.refreshToken,
      accessTokenExpiresAt: response.accessTokenExpirationDateTime,
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
      accessTokenExpiresAt: response.accessTokenExpirationDateTime,
    );
    return response.accessToken;
  }

  Future<OidcUserProfile> profile() async {
    var accessToken = await store.readAccessToken();
    if (accessToken == null) throw StateError('Sign in is required');
    final endpoint = Uri.parse(
      '${environment.keycloakIssuer}/protocol/openid-connect/userinfo',
    );
    Future<Response<Object>> request(String token) => _httpClient.get<Object>(
      endpoint.toString(),
      options: Options(
        headers: {'Authorization': 'Bearer $token'},
        followRedirects: false,
        sendTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    Response<Object> response;
    try {
      response = await request(accessToken);
    } on DioException catch (error) {
      if (error.response?.statusCode != 401) rethrow;
      accessToken = await refresh();
      if (accessToken == null) throw StateError('Sign in is required');
      response = await request(accessToken);
    }
    if (response.statusCode != 200 || response.data is! Map) {
      throw StateError('Account profile is unavailable');
    }
    return OidcUserProfile.fromJson(
      Map<String, dynamic>.from(response.data! as Map),
    );
  }

  Future<void> logout() => store.clear();
}

class OrganizationSummary {
  const OrganizationSummary({
    required this.id,
    required this.name,
    this.currentUserRole,
  });

  factory OrganizationSummary.fromJson(Map<String, dynamic> value) {
    final id = value['id'];
    final name = value['name'];
    final role = value['currentUserRole'];
    if (id is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false,
        ).hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 120 ||
        (role != null &&
            (role is! String ||
                !const {
                  'OWNER',
                  'ADMIN',
                  'OPERATOR',
                  'VIEWER',
                }.contains(role)))) {
      throw const FormatException('Invalid organization response');
    }
    return OrganizationSummary(
      id: id,
      name: name.trim(),
      currentUserRole: role as String?,
    );
  }

  final String id;
  final String name;
  final String? currentUserRole;
}

class DeviceSummary {
  const DeviceSummary({
    required this.deviceUuid,
    required this.deviceId,
    required this.lifecycle,
    required this.ownershipVersion,
    this.displayName,
  });

  factory DeviceSummary.fromJson(Map<String, dynamic> value) {
    final deviceUuid = value['deviceUuid'];
    final deviceId = value['deviceId'];
    final lifecycle = value['lifecycle'];
    final ownershipVersion = value['ownershipVersion'];
    final displayName = value['displayName'];
    if (deviceUuid is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false,
        ).hasMatch(deviceUuid) ||
        deviceId is! String ||
        !RegExp(r'^AG-[0-9]{6}$').hasMatch(deviceId) ||
        lifecycle is! String ||
        ownershipVersion is! String ||
        !RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(ownershipVersion) ||
        (displayName != null &&
            (displayName is! String ||
                displayName.trim().isEmpty ||
                displayName.length > 64)) ||
        !const {
          'UNCLAIMED',
          'CLAIMED',
          'PROVISIONED',
          'ACTIVE',
          'INACTIVE',
          'REVOKED',
        }.contains(lifecycle)) {
      throw const FormatException('Invalid device response');
    }
    return DeviceSummary(
      deviceUuid: deviceUuid,
      deviceId: deviceId,
      lifecycle: lifecycle,
      ownershipVersion: ownershipVersion,
      displayName: displayName as String?,
    );
  }

  final String deviceUuid;
  final String deviceId;
  final String lifecycle;
  final String ownershipVersion;
  final String? displayName;

  String get visibleName => displayName ?? deviceId;
}

class AlertRecord {
  const AlertRecord({
    required this.alertId,
    required this.deviceId,
    required this.parameter,
    required this.direction,
    required this.value,
    required this.occurredAt,
    this.minimum,
    this.maximum,
  });

  factory AlertRecord.fromJson(Map<String, dynamic> value) {
    final alertId = value['alertId'];
    final deviceId = value['deviceId'];
    final parameter = value['parameter'];
    final direction = value['direction'];
    final numericValue = value['value'];
    final occurredAt = value['occurredAt'];
    if (alertId is! String ||
        deviceId is! String ||
        parameter is! String ||
        direction is! String ||
        !const {'LOW', 'HIGH'}.contains(direction) ||
        numericValue is! num ||
        occurredAt is! String) {
      throw const FormatException('Invalid alert response');
    }
    final occurred = DateTime.tryParse(occurredAt)?.toUtc();
    if (occurred == null) throw const FormatException('Invalid alert time');
    final minimum = value['minimum'];
    final maximum = value['maximum'];
    return AlertRecord(
      alertId: alertId,
      deviceId: deviceId,
      parameter: parameter,
      direction: direction,
      value: numericValue.toDouble(),
      occurredAt: occurred,
      minimum: minimum is num ? minimum.toDouble() : null,
      maximum: maximum is num ? maximum.toDouble() : null,
    );
  }

  final String alertId;
  final String deviceId;
  final String parameter;
  final String direction;
  final double value;
  final DateTime occurredAt;
  final double? minimum;
  final double? maximum;
}

class ProfileSummary {
  const ProfileSummary({
    required this.profileId,
    required this.name,
    required this.version,
    required this.configuration,
  });

  factory ProfileSummary.fromJson(Map<String, dynamic> value) {
    final profileId = value['profileId'];
    final name = value['name'];
    final current = value['current'];
    if (profileId is! String ||
        name is! String ||
        name.trim().isEmpty ||
        current is! Map ||
        current['version'] is! int) {
      throw const FormatException('Invalid profile response');
    }
    AlgaeProfileConfiguration? configuration;
    final rawConfiguration = current['configuration'];
    if (rawConfiguration is Map && rawConfiguration['parameters'] is Map) {
      configuration = AlgaeProfileConfiguration.fromJson(
        Map<String, dynamic>.from(rawConfiguration),
      );
    }
    return ProfileSummary(
      profileId: profileId,
      name: name.trim(),
      version: current['version'] as int,
      configuration: configuration,
    );
  }

  final String profileId;
  final String name;
  final int version;
  final AlgaeProfileConfiguration? configuration;
}

class OrganizationInvitationSummary {
  const OrganizationInvitationSummary({
    required this.id,
    required this.organizationName,
    required this.role,
    required this.expiresAt,
  });

  factory OrganizationInvitationSummary.fromJson(Map<String, dynamic> value) {
    final id = value['id'];
    final organizationName = value['organizationName'];
    final role = value['role'];
    final expiresAt = DateTime.tryParse(
      value['expiresAt'] as String? ?? '',
    )?.toUtc();
    if (id is! String ||
        organizationName is! String ||
        organizationName.trim().isEmpty ||
        !const {'ADMIN', 'VIEWER'}.contains(role) ||
        expiresAt == null) {
      throw const FormatException('Invalid organization invitation');
    }
    return OrganizationInvitationSummary(
      id: id,
      organizationName: organizationName.trim(),
      role: role as String,
      expiresAt: expiresAt,
    );
  }

  final String id;
  final String organizationName;
  final String role;
  final DateTime expiresAt;
}

class DeviceProfileAssignment {
  const DeviceProfileAssignment({
    required this.profileId,
    required this.profileVersion,
  });

  factory DeviceProfileAssignment.fromJson(Map<String, dynamic> value) {
    final profileId = value['profileId'];
    final profileVersion = value['profileVersion'];
    if (profileId is! String || profileVersion is! int) {
      throw const FormatException('Invalid profile assignment');
    }
    return DeviceProfileAssignment(
      profileId: profileId,
      profileVersion: profileVersion,
    );
  }

  final String profileId;
  final int profileVersion;
}

class PreparedPhysicalOnboarding {
  const PreparedPhysicalOnboarding({
    required this.claim,
    required this.session,
  });

  final QrClaim claim;
  final ProvisioningSession session;
}

enum DeviceCloudReadiness { ready, timedOut, unavailable }

enum PhysicalUnpairOutcome { completed, rejected, expired, timedOut }

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

  Future<void> registerPushInstallation({
    required String accessToken,
    required String installationId,
    required String registrationToken,
  }) async {
    await dio.put<Object>(
      '/services/realtime/push/registrations/$installationId',
      data: {'platform': 'ANDROID', 'registrationToken': registrationToken},
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
  }

  Future<void> unregisterPushInstallation({
    required String accessToken,
    required String installationId,
  }) async {
    await dio.delete<Object>(
      '/services/realtime/push/registrations/$installationId',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
  }

  Future<List<OrganizationSummary>> listOrganizations({
    required String accessToken,
  }) async {
    final response = await dio.get<Object>(
      '/services/access/organizations',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    if (response.statusCode != 200 || response.data is! Map) {
      throw StateError('Organizations are unavailable');
    }
    final root = Map<String, dynamic>.from(response.data! as Map);
    final items = root['items'];
    if (items is! List || items.length > 100) {
      throw const FormatException('Invalid organizations response');
    }
    return items
        .map(
          (item) => OrganizationSummary.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
  }

  Future<OrganizationSummary> createOrganization({
    required String accessToken,
    required String name,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty || normalizedName.length > 120) {
      throw const FormatException('Invalid organization name');
    }
    final response = await dio.post<Object>(
      '/services/access/organizations',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {'name': normalizedName},
    );
    if (response.statusCode != 201 || response.data is! Map) {
      throw StateError('Organization was not created');
    }
    return OrganizationSummary.fromJson(
      Map<String, dynamic>.from(response.data! as Map),
    );
  }

  Future<ProvisioningSession> consumeClaim({
    required String accessToken,
    required String organizationId,
    required QrClaim claim,
  }) async {
    final response = await dio.post<Object>(
      '/services/device/claims/consume',
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

  Future<List<DeviceSummary>> listDevices({
    required String accessToken,
    required String organizationId,
  }) async {
    final response = await dio.get<Object>(
      '/services/device/devices',
      queryParameters: {'organizationId': organizationId},
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    if (response.statusCode != 200 || response.data is! Map) {
      throw StateError('Devices are unavailable');
    }
    final items = (response.data! as Map)['items'];
    if (items is! List || items.length > 100) {
      throw const FormatException('Invalid devices response');
    }
    return items
        .map(
          (item) =>
              DeviceSummary.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false);
  }

  Future<DeviceSummary> updateDeviceName({
    required String accessToken,
    required String deviceUuid,
    required String displayName,
  }) async {
    final normalized = displayName.trim();
    if (normalized.isEmpty || normalized.length > 64) {
      throw const FormatException('Invalid device name');
    }
    final response = await dio.patch<Object>(
      '/services/device/devices/$deviceUuid',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {'displayName': normalized},
    );
    if (response.statusCode != 200 || response.data is! Map) {
      throw StateError('Device name was not saved');
    }
    return DeviceSummary.fromJson(
      Map<String, dynamic>.from(response.data! as Map),
    );
  }

  Future<List<ProfileSummary>> listProfiles({
    required String accessToken,
    required String organizationId,
  }) async {
    final response = await dio.get<Object>(
      '/services/profile/profiles',
      queryParameters: {'organizationId': organizationId},
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    if (response.statusCode != 200 || response.data is! Map) {
      throw StateError('Profiles are unavailable');
    }
    final items = (response.data! as Map)['items'];
    if (items is! List || items.length > 100) {
      throw const FormatException('Invalid profiles response');
    }
    return items
        .map(
          (item) =>
              ProfileSummary.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false);
  }

  Future<void> inviteOrganizationMember({
    required String accessToken,
    required String organizationId,
    required String email,
    required String role,
  }) async {
    final normalized = email.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(normalized) ||
        !const {'ADMIN', 'VIEWER'}.contains(role)) {
      throw const FormatException('Invalid invitation');
    }
    final response = await dio.post<Object>(
      '/services/access/organizations/$organizationId/invitations',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {'email': normalized, 'role': role},
    );
    if (response.statusCode != 201) {
      throw StateError('Invitation was not created');
    }
  }

  Future<List<OrganizationInvitationSummary>> listIncomingInvitations({
    required String accessToken,
  }) async {
    final response = await dio.get<Object>(
      '/services/access/invitations',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    if (response.statusCode != 200 || response.data is! Map) {
      throw StateError('Invitations are unavailable');
    }
    final items = (response.data! as Map)['items'];
    if (items is! List || items.length > 100) {
      throw const FormatException('Invalid invitations response');
    }
    return items
        .map(
          (item) => OrganizationInvitationSummary.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
  }

  Future<void> respondToInvitation({
    required String accessToken,
    required String invitationId,
    required bool accept,
  }) async {
    final response = await dio.post<Object>(
      '/services/access/invitations/$invitationId/${accept ? 'accept' : 'reject'}',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    if ((accept && response.statusCode != 200) ||
        (!accept && response.statusCode != 204)) {
      throw StateError('Invitation response was not saved');
    }
  }

  Future<ProfileSummary> createAlgaeProfile({
    required String accessToken,
    required String organizationId,
    required String name,
    required AlgaeProfileConfiguration configuration,
  }) async {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.length > 120) {
      throw const FormatException('Invalid algae profile name');
    }
    final response = await dio.post<Object>(
      '/services/profile/profiles',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {
        'organizationId': organizationId,
        'name': normalized,
        'configuration': configuration.toJson(),
      },
    );
    if (response.statusCode != 201 || response.data is! Map) {
      throw StateError('Algae profile was not created');
    }
    return ProfileSummary.fromJson(
      Map<String, dynamic>.from(response.data! as Map),
    );
  }

  Future<ProfileSummary> updateAlgaeProfile({
    required String accessToken,
    required ProfileSummary profile,
    required AlgaeProfileConfiguration configuration,
  }) async {
    final response = await dio.post<Object>(
      '/services/profile/profiles/${profile.profileId}/versions',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: configuration.toJson(),
    );
    if (response.statusCode != 201 || response.data is! Map) {
      throw StateError('Algae profile was not updated');
    }
    return ProfileSummary(
      profileId: profile.profileId,
      name: profile.name,
      version: profile.version + 1,
      configuration: configuration,
    );
  }

  Future<void> deleteAlgaeProfile({
    required String accessToken,
    required ProfileSummary profile,
  }) async {
    final response = await dio.delete<Object>(
      '/services/profile/profiles/${profile.profileId}',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: const {'confirmation': 'DELETE'},
    );
    if (response.statusCode != 204) {
      throw StateError('Algae profile was not deleted');
    }
  }

  Future<DeviceProfileAssignment?> activeDeviceProfile({
    required String accessToken,
    required String deviceId,
  }) async {
    try {
      final response = await dio.get<Object>(
        '/services/profile/devices/$deviceId/profile-assignment',
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      );
      if (response.statusCode == 404) return null;
      if (response.statusCode != 200 || response.data is! Map) {
        throw StateError('Profile assignment is unavailable');
      }
      return DeviceProfileAssignment.fromJson(
        Map<String, dynamic>.from(response.data! as Map),
      );
    } on DioException catch (failure) {
      if (failure.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> assignDeviceProfile({
    required String accessToken,
    required String organizationId,
    required String deviceId,
    required ProfileSummary profile,
  }) async {
    final response = await dio.put<Object>(
      '/services/profile/devices/$deviceId/profile-assignment',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {
        'organizationId': organizationId,
        'profileId': profile.profileId,
        'version': profile.version,
      },
    );
    if (response.statusCode != 200 || response.data is! Map) {
      throw StateError('Profile was not assigned');
    }
    final assignment = Map<String, dynamic>.from(response.data! as Map);
    final configurationId = assignment['id'];
    if (configurationId is! String) {
      throw const FormatException('Invalid profile assignment response');
    }
    final command = await dio.post<Object>(
      '/services/command/devices/$deviceId/commands',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {
        'commandId': _uuidV4(),
        'commandType': 'APPLY_PROFILE_CONFIGURATION',
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 10))
            .toIso8601String(),
        'parameters': {
          'configurationId': configurationId,
          'profileId': profile.profileId,
          'profileVersion': '${profile.version}.0.0',
        },
      },
    );
    if (command.statusCode != 202) {
      throw StateError('Profile activation command was not queued');
    }
  }

  Future<ProfileSummary> createAndAssignDeviceProfile({
    required String accessToken,
    required String organizationId,
    required String deviceId,
    required String profileName,
  }) async {
    final normalized = profileName.trim();
    if (normalized.isEmpty || normalized.length > 120) {
      throw const FormatException('Invalid profile name');
    }
    final profiles = await listProfiles(
      accessToken: accessToken,
      organizationId: organizationId,
    );
    final matches = profiles
        .where(
          (profile) => profile.name.toLowerCase() == normalized.toLowerCase(),
        )
        .toList(growable: false);
    final ProfileSummary profile;
    if (matches.length == 1) {
      profile = matches.single;
    } else if (matches.isEmpty) {
      final created = await dio.post<Object>(
        '/services/profile/profiles',
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        data: {
          'organizationId': organizationId,
          'name': normalized,
          'configuration': {
            'status': 'DRAFT',
            'thresholds': <String, Object>{},
          },
        },
      );
      if (created.statusCode != 201 || created.data is! Map) {
        throw StateError('Profile was not created');
      }
      profile = ProfileSummary.fromJson(
        Map<String, dynamic>.from(created.data! as Map),
      );
    } else {
      throw StateError('Profile name is already used more than once');
    }

    final assigned = await dio.put<Object>(
      '/services/profile/devices/$deviceId/profile-assignment',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {
        'organizationId': organizationId,
        'profileId': profile.profileId,
        'version': profile.version,
      },
    );
    if (assigned.statusCode != 200 || assigned.data is! Map) {
      throw StateError('Profile was not assigned');
    }
    final assignment = Map<String, dynamic>.from(assigned.data! as Map);
    final configurationId = assignment['id'];
    if (configurationId is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false,
        ).hasMatch(configurationId)) {
      throw const FormatException('Invalid profile assignment response');
    }
    final commandId = _uuidV4();
    final command = await dio.post<Object>(
      '/services/command/devices/$deviceId/commands',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {
        'commandId': commandId,
        'commandType': 'APPLY_PROFILE_CONFIGURATION',
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 10))
            .toIso8601String(),
        'parameters': {
          'configurationId': configurationId,
          'profileId': profile.profileId,
          'profileVersion': '${profile.version}.0.0',
        },
      },
    );
    if (command.statusCode != 202) {
      throw StateError('Device profile command was not queued');
    }
    return profile;
  }

  Future<PhysicalUnpairOutcome> requestPhysicalUnpair({
    required String accessToken,
    required DeviceSummary device,
    Duration timeout = const Duration(minutes: 2),
    Duration pollInterval = const Duration(seconds: 2),
    Future<void> Function(Duration) delay = Future<void>.delayed,
  }) async {
    if (timeout <= Duration.zero || pollInterval <= Duration.zero) {
      throw const FormatException('Invalid physical unpair window');
    }
    final commandId = _uuidV4();
    final queued = await dio.post<Object>(
      '/services/command/devices/${device.deviceId}/commands',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {
        'commandId': commandId,
        'commandType': 'REQUEST_PHYSICAL_UNPAIR',
        'expiresAt': DateTime.now().toUtc().add(timeout).toIso8601String(),
        'parameters': <String, Object>{},
      },
    );
    if (queued.statusCode != 202) {
      throw StateError('Physical confirmation request was not queued');
    }
    final deadline = DateTime.now().toUtc().add(timeout);
    while (DateTime.now().toUtc().isBefore(deadline)) {
      final response = await dio.get<Object>(
        '/services/command/commands/$commandId',
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      );
      if (response.statusCode != 200 || response.data is! Map) {
        throw StateError('Physical confirmation status is unavailable');
      }
      final value = Map<String, dynamic>.from(response.data! as Map);
      if (value['commandId'] != commandId ||
          value['deviceId'] != device.deviceId ||
          value['commandType'] != 'REQUEST_PHYSICAL_UNPAIR') {
        throw const FormatException('Invalid physical confirmation status');
      }
      switch (value['status']) {
        case 'SUCCEEDED':
          final finalized = await dio.post<Object>(
            '/services/device/devices/${device.deviceUuid}/physical-unpair/finalize',
            options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
            data: {
              'commandId': commandId,
              'ownershipVersion': device.ownershipVersion,
              'confirmation': 'PHYSICALLY_CONFIRMED',
            },
          );
          if (finalized.statusCode != 200 || finalized.data is! Map) {
            throw StateError('Physical unpair was not finalized');
          }
          final result = Map<String, dynamic>.from(finalized.data! as Map);
          if (result['state'] != 'UNPAIRED' ||
              result['lifecycle'] != 'UNCLAIMED') {
            throw const FormatException('Invalid physical unpair result');
          }
          return PhysicalUnpairOutcome.completed;
        case 'REJECTED':
        case 'FAILED':
          return PhysicalUnpairOutcome.rejected;
        case 'EXPIRED':
          return PhysicalUnpairOutcome.expired;
        case 'QUEUED':
        case 'SENT':
        case 'ACKNOWLEDGED':
        case 'IN_PROGRESS':
          await delay(pollInterval);
          break;
        default:
          throw const FormatException('Invalid physical confirmation status');
      }
    }
    return PhysicalUnpairOutcome.timedOut;
  }

  Future<DeviceCloudReadiness> waitForDeviceCloudReadiness({
    required String accessToken,
    required String organizationId,
    required String deviceId,
    Duration timeout = const Duration(seconds: 45),
    Duration pollInterval = const Duration(seconds: 2),
    Future<void> Function(Duration) delay = Future<void>.delayed,
  }) async {
    if (!RegExp(r'^AG-[0-9]{6}$').hasMatch(deviceId) ||
        timeout <= Duration.zero ||
        pollInterval <= Duration.zero) {
      throw const FormatException('Invalid cloud readiness request');
    }
    final deadline = DateTime.now().toUtc().add(timeout);
    do {
      try {
        final devices = await listDevices(
          accessToken: accessToken,
          organizationId: organizationId,
        );
        final matches = devices.where((device) => device.deviceId == deviceId);
        // Provisioning records are intentionally hidden from ordinary device
        // lists until credential bootstrap reaches a visible lifecycle.
        if (matches.isEmpty) {
          // Continue polling within the bounded readiness window.
        } else if (matches.length != 1) {
          return DeviceCloudReadiness.unavailable;
        } else {
          if (const {
            'PROVISIONED',
            'ACTIVE',
          }.contains(matches.single.lifecycle)) {
            return DeviceCloudReadiness.ready;
          }
          if (matches.single.lifecycle != 'CLAIMED') {
            return DeviceCloudReadiness.unavailable;
          }
        }
      } on FormatException {
        return DeviceCloudReadiness.unavailable;
      } on StateError {
        return DeviceCloudReadiness.unavailable;
      } on DioException {
        // A short transport interruption is allowed within the bounded poll.
      }
      if (!DateTime.now().toUtc().isBefore(deadline)) break;
      await delay(pollInterval);
    } while (DateTime.now().toUtc().isBefore(deadline));
    return DeviceCloudReadiness.timedOut;
  }

  Future<PreparedPhysicalOnboarding> exchangeQrOnboarding({
    required String accessToken,
    DeviceSummary? device,
    String? organizationId,
    required QrOnboardingInvitation invitation,
  }) async {
    final scanFirst = device == null && organizationId != null;
    final existingDevice = device != null && organizationId == null;
    if (!scanFirst && !existingDevice) {
      throw const FormatException('QR_EXCHANGE_MODE_INVALID');
    }
    if (device != null &&
        (!const {
              'CLAIMED',
              'PROVISIONED',
              'ACTIVE',
              'INACTIVE',
            }.contains(device.lifecycle) ||
            device.deviceId != invitation.deviceId)) {
      throw const FormatException('QR_DEVICE_MISMATCH');
    }
    late final Response<Object> response;
    try {
      response = await dio.post<Object>(
        '/services/device/device-onboarding/qr/exchange',
        options: Options(
          headers: {'Authorization': 'Bearer $accessToken'},
          followRedirects: false,
        ),
        data: scanFirst
            ? {
                'schema':
                    'urn:algaguard:schema:onboarding:qr-onboarding-exchange-request:v2',
                'schemaVersion': '2.0.0',
                'invitationUri': invitation.uri,
                'organizationId': organizationId,
                'registrationMode': 'DEVELOPMENT_SCAN_FIRST',
              }
            : {
                'schema':
                    'urn:algaguard:schema:onboarding:qr-onboarding-exchange-request:v1',
                'schemaVersion': '1.0.0',
                'invitationUri': invitation.uri,
                'ownershipVersion': device!.ownershipVersion,
              },
      );
    } on DioException catch (failure) {
      final data = failure.response?.data;
      final code = data is Map ? data['code'] : null;
      final status = failure.response?.statusCode;
      throw QrOnboardingExchangeException(
        status == 410 || code == 'QR_INVITATION_EXPIRED'
            ? QrOnboardingExchangeFailure.expired
            : code == 'QR_INVITATION_REPLAYED'
            ? QrOnboardingExchangeFailure.replayed
            : code == 'QR_ONBOARDING_NOT_ALLOWED'
            ? QrOnboardingExchangeFailure.deviceNotEligible
            : code == 'CROSS_ORGANIZATION_DENIED'
            ? QrOnboardingExchangeFailure.pairedWithAnotherOrganization
            : status == 401 || status == 403
            ? QrOnboardingExchangeFailure.authorization
            : QrOnboardingExchangeFailure.unavailable,
      );
    }
    if (response.statusCode != 201 ||
        response.headers.value('cache-control')?.toLowerCase() != 'no-store' ||
        response.data is! Map) {
      throw const FormatException('QR_EXCHANGE_UNAVAILABLE');
    }
    final value = Map<String, dynamic>.from(response.data! as Map);
    const required = {
      'schema',
      'schemaVersion',
      'sessionId',
      'deviceId',
      'createdAt',
      'expiresAt',
      'serviceUuid',
      'sessionToken',
      'bindingGrant',
    };
    if (value.keys.toSet().difference(required).isNotEmpty ||
        required.difference(value.keys.toSet()).isNotEmpty ||
        value['schema'] !=
            'urn:algaguard:schema:onboarding:qr-onboarding-exchange-response:v1' ||
        value['schemaVersion'] != '1.0.0' ||
        value['deviceId'] != invitation.deviceId ||
        value['serviceUuid'] != bleProvisioningServiceUuid ||
        value['sessionId'] is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false,
        ).hasMatch(value['sessionId'] as String) ||
        value['sessionToken'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_-]{32,96}$',
        ).hasMatch(value['sessionToken'] as String) ||
        value['bindingGrant'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_-]{194}$',
        ).hasMatch(value['bindingGrant'] as String) ||
        value['expiresAt'] is! String) {
      throw const FormatException('QR_EXCHANGE_UNAVAILABLE');
    }
    final expiresAt = DateTime.parse(value['expiresAt'] as String).toUtc();
    if (!expiresAt.isAfter(DateTime.now().toUtc())) {
      throw const FormatException('QR_EXCHANGE_EXPIRED');
    }
    return PreparedPhysicalOnboarding(
      claim: QrClaim(
        deviceId: invitation.deviceId,
        claimCode: '',
        bootstrapUrl: Uri(),
        environment: 'development',
        bleServiceId: bleProvisioningServiceUuid,
        expiresAt: expiresAt,
      ),
      session: ProvisioningSession(
        sessionId: value['sessionId'] as String,
        deviceId: invitation.deviceId,
        expiresAt: expiresAt,
        sessionToken: value['sessionToken'] as String,
        bindingGrant: value['bindingGrant'] as String,
      ),
    );
  }

  Future<DemoTelemetryReading> latestDemoTelemetry({
    required String accessToken,
    required String deviceUuid,
  }) async {
    final response = await dio.get<Object>(
      '/services/telemetry/devices/$deviceUuid/latest',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    if (response.statusCode != 200 || response.data is! Map) {
      throw StateError('Telemetry is unavailable');
    }
    return DemoTelemetryReading.fromLatestResponse(
      Map<String, dynamic>.from(response.data! as Map),
    );
  }

  /// Latest reading per device UUID, omitting devices with no telemetry yet
  /// or an unparsable sample rather than failing the whole batch.
  Future<Map<String, DemoTelemetryReading>> latestTelemetryBatch({
    required String accessToken,
    required List<String> deviceUuids,
  }) async {
    if (deviceUuids.isEmpty) return const {};
    final response = await dio.post<Object>(
      '/services/telemetry/devices/latest-batch',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      data: {'deviceUuids': deviceUuids},
    );
    if (response.statusCode != 200 || response.data is! Map) {
      throw StateError('Telemetry is unavailable');
    }
    final items = (response.data! as Map)['items'];
    if (items is! List) {
      throw const FormatException('Invalid telemetry batch response');
    }
    final readings = <String, DemoTelemetryReading>{};
    for (final item in items) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final deviceUuid = map['deviceUuid'];
      if (deviceUuid is! String) continue;
      try {
        readings[deviceUuid] = DemoTelemetryReading.fromLatestResponse(map);
      } on FormatException {
        // No reading yet, or an unparsable/non-demo sample; omit it.
      }
    }
    return readings;
  }

  Future<List<AlertRecord>> listOrganizationAlerts({
    required String accessToken,
    required String organizationId,
  }) async {
    final response = await dio.get<Object>(
      '/services/realtime/organizations/$organizationId/alerts',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    if (response.statusCode != 200 || response.data is! Map) {
      throw StateError('Alerts are unavailable');
    }
    final items = (response.data! as Map)['items'];
    if (items is! List || items.length > 500) {
      throw const FormatException('Invalid alerts response');
    }
    return items
        .map(
          (item) =>
              AlertRecord.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false);
  }

  /// Development-only owner-authorized recovery. The returned session remains
  /// in memory only and no claim, device, or ownership record is created.
  Future<PreparedPhysicalOnboarding> reissueOwnedDeviceBootstrapSession({
    required String accessToken,
    required DeviceSummary device,
  }) async {
    if (device.lifecycle != 'CLAIMED') {
      throw StateError('Owned device is not eligible for bootstrap reissue');
    }
    final Response<Object> response;
    try {
      response = await dio.post<Object>(
        '/services/device/devices/${device.deviceUuid}/bootstrap-sessions/reissue',
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        data: {
          'schema':
              'urn:algaguard:schema:onboarding:owned-device-bootstrap-reissue-request:v2',
          'schemaVersion': '2.0.0',
          'ownershipVersion': device.ownershipVersion,
        },
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        throw const BootstrapReissueException(
          BootstrapReissueFailureCategory.authorizationFailure,
        );
      }
      if (status != null && status >= 500) {
        throw const BootstrapReissueException(
          BootstrapReissueFailureCategory.serverFailure,
        );
      }
      throw const BootstrapReissueException(
        BootstrapReissueFailureCategory.transportFailure,
      );
    }
    if (response.statusCode != 201 || response.data is! Map) {
      throw const BootstrapReissueException(
        BootstrapReissueFailureCategory.responseSchemaMismatch,
      );
    }
    final value = Map<String, dynamic>.from(response.data! as Map);
    const required = {
      'schema',
      'schemaVersion',
      'sessionId',
      'deviceId',
      'createdAt',
      'expiresAt',
      'serviceUuid',
      'sessionToken',
    };
    if (value.keys.toSet().difference(required).isNotEmpty ||
        !value.keys.toSet().containsAll(required) ||
        value['schema'] !=
            'urn:algaguard:schema:onboarding:bootstrap-session:v1' ||
        value['schemaVersion'] != '1.0.0' ||
        value['deviceId'] != device.deviceId ||
        value['sessionId'] is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false,
        ).hasMatch(value['sessionId'] as String) ||
        value['createdAt'] is! String ||
        value['sessionToken'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_-]{32,96}$',
        ).hasMatch(value['sessionToken'] as String) ||
        value['expiresAt'] is! String) {
      throw const BootstrapReissueException(
        BootstrapReissueFailureCategory.responseSchemaMismatch,
      );
    }
    if (value['serviceUuid'] != bleProvisioningServiceUuid) {
      throw const BootstrapReissueException(
        BootstrapReissueFailureCategory.serviceUuidMismatch,
      );
    }
    late final DateTime createdAt;
    late final DateTime expiresAt;
    try {
      createdAt = DateTime.parse(value['createdAt'] as String).toUtc();
      expiresAt = DateTime.parse(value['expiresAt'] as String).toUtc();
    } on FormatException {
      throw const BootstrapReissueException(
        BootstrapReissueFailureCategory.responseSchemaMismatch,
      );
    }
    if (!expiresAt.isAfter(createdAt) ||
        !expiresAt.isAfter(DateTime.now().toUtc())) {
      throw const BootstrapReissueException(
        BootstrapReissueFailureCategory.responseSchemaMismatch,
      );
    }
    return PreparedPhysicalOnboarding(
      claim: QrClaim(
        deviceId: device.deviceId,
        claimCode: '',
        bootstrapUrl: Uri.parse('/services/device/claims/consume'),
        environment: 'development',
        bleServiceId: bleProvisioningServiceUuid,
        expiresAt: expiresAt,
      ),
      session: ProvisioningSession(
        sessionId: value['sessionId'] as String,
        deviceId: device.deviceId,
        expiresAt: expiresAt,
        sessionToken: value['sessionToken'] as String,
      ),
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
    try {
      await dio.post<void>(
        '/services/device/development/physical-session-handoffs/approve',
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        data: {
          'protocolVersion': 1,
          'userCode': normalizedCode,
          'sessionId': session.sessionId,
          'deviceId': session.deviceId,
          'sessionToken': session.takeToken(),
        },
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 410) {
        throw const PhysicalSessionApprovalException(
          PhysicalSessionApprovalFailureCategory.expired,
        );
      }
      rethrow;
    }
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

  Future<String> requestRealtimeTicket({required String accessToken}) async {
    final Response<Object> response;
    try {
      response = await dio.post<Object>(
        '/services/realtime/tickets',
        options: Options(
          headers: {'Authorization': 'Bearer $accessToken'},
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          followRedirects: false,
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        throw const RealtimeTicketException(RealtimeTicketFailure.rejected);
      }
      if (status == 410) {
        throw const RealtimeTicketException(RealtimeTicketFailure.expired);
      }
      throw const RealtimeTicketException.unavailable();
    }
    if (response.statusCode != 201 || response.data is! Map) {
      throw const RealtimeTicketException.unavailable();
    }
    final ticket = (response.data! as Map)['ticket'];
    if (ticket is! String || ticket.isEmpty || ticket.length > 512) {
      throw const RealtimeTicketException.unavailable();
    }
    return ticket;
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
    String? bindingGrant,
    void Function(SafeProvisioningStatus status)? onStatus,
  }) async {
    if (serviceId.toLowerCase() != bleProvisioningServiceUuid) {
      throw const BleProvisioningWireException('SERVICE_NOT_FOUND');
    }
    final serviceGuid = Guid(bleProvisioningServiceUuid);
    late final ScanResult matchingResult;
    try {
      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(
        withServices: [serviceGuid],
        timeout: const Duration(seconds: 15),
      );
      matchingResult = await FlutterBluePlus.scanResults
          .map(
            (results) =>
                results.where((result) => _matchesProvisioningAdvert(result)),
          )
          .where((results) => results.isNotEmpty)
          .map((results) => results.first)
          .first
          .timeout(
            const Duration(seconds: 16),
            onTimeout: () async {
              await FlutterBluePlus.stopScan();
              return _scanByProvisioningNameFallback();
            },
          );
    } finally {
      await FlutterBluePlus.stopScan();
    }
    final device = matchingResult.device;
    await device.connect(timeout: const Duration(seconds: 15));
    // Best-effort: a larger MTU means fewer 11-byte-header fragments for the
    // same Wi-Fi credential payload, which means fewer sequential BLE writes
    // that could each independently drop mid-transfer. The default
    // unnegotiated ATT MTU (23 bytes) works but is needlessly fragile for a
    // multi-frame write; failing to negotiate up just leaves the existing
    // default, so this never turns a working connection into a failing one.
    try {
      await device.requestMtu(517).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Fall through with whatever MTU is already negotiated.
    }

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
      final services = await _discoverProvisioningServices(device);
      final service = services.firstWhere(
        (candidate) =>
            canonicalFlutterBlueUuid(candidate.uuid) ==
            bleProvisioningServiceUuid,
      );
      final request = service.characteristics.firstWhere(
        (candidate) =>
            canonicalFlutterBlueUuid(candidate.uuid) ==
            bleProvisioningRequestUuid,
      );
      statusCharacteristic = service.characteristics.firstWhere(
        (candidate) =>
            canonicalFlutterBlueUuid(candidate.uuid) ==
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

      // onValueReceived emits actual reads and notifications. lastValueStream
      // also replays an initially empty cache entry, which is not a device
      // status and must not be fed to the strict status decoder.
      statusSubscription = statusCharacteristic.onValueReceived.listen(
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
        bindingGrant: bindingGrant,
      );
      final fragmentPayloadLimit = min(
        BleProvisioningWire.maxFragmentPayload,
        device.mtuNow - 3 - BleProvisioningWire.headerLength,
      );
      frames = BleProvisioningWire.framePayload(
        payload,
        _nextMessageId(),
        fragmentPayloadLimit: fragmentPayloadLimit,
      );
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

  Future<List<BluetoothService>> _discoverProvisioningServices(
    BluetoothDevice device,
  ) async {
    BleProvisioningWireException? lastContractError;
    for (var attempt = 0; attempt < 2; attempt += 1) {
      final services = await device.discoverServices();
      final contractServices = services
          .map(
            (service) => BleServiceContract(
              uuid: canonicalFlutterBlueUuid(service.uuid),
              characteristics: service.characteristics
                  .map(
                    (characteristic) => BleCharacteristicContract(
                      uuid: canonicalFlutterBlueUuid(characteristic.uuid),
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
      try {
        BleProvisioningWire.selectCharacteristics(contractServices);
        return services;
      } on BleProvisioningWireException catch (error) {
        lastContractError = error;
        if (attempt == 0 && error.code == 'SERVICE_NOT_FOUND') {
          try {
            await device.clearGattCache();
            await device.disconnect();
            await Future<void>.delayed(const Duration(milliseconds: 750));
            await device.connect(timeout: const Duration(seconds: 15));
            await Future<void>.delayed(const Duration(milliseconds: 500));
            continue;
          } catch (_) {
            // Cache refresh/reconnect failures contain no provisioning payload.
          }
        }
        rethrow;
      }
    }
    throw lastContractError ??
        const BleProvisioningWireException('SERVICE_NOT_FOUND');
  }

  int _nextMessageId() {
    for (var attempts = 0; attempts < 32; attempts++) {
      final messageId = _random.nextInt(0x7fffffff) + 1;
      if (_usedMessageIds.add(messageId)) return messageId;
    }
    throw const BleProvisioningWireException('MESSAGE_ID_UNAVAILABLE');
  }

  Future<ScanResult> _scanByProvisioningNameFallback() async {
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    try {
      return await FlutterBluePlus.scanResults
          .map(
            (results) =>
                results.where((result) => _matchesProvisioningAdvert(result)),
          )
          .where((results) => results.isNotEmpty)
          .map((results) => results.first)
          .first
          .timeout(
            const Duration(seconds: 9),
            onTimeout: () =>
                throw const BleProvisioningWireException('SERVICE_NOT_FOUND'),
          );
    } finally {
      await FlutterBluePlus.stopScan();
    }
  }

  bool _matchesProvisioningAdvert(ScanResult result) {
    final serviceMatch = result.advertisementData.serviceUuids.any(
      (uuid) => canonicalFlutterBlueUuid(uuid) == bleProvisioningServiceUuid,
    );
    if (serviceMatch) return true;
    final advertisedName = result.advertisementData.advName.trim();
    final platformName = result.device.platformName.trim();
    return advertisedName == 'AlgaGuard-Setup' ||
        platformName == 'AlgaGuard-Setup';
  }
}

enum RealtimeTicketFailure { unavailable, rejected, expired }

class RealtimeTicketException implements Exception {
  const RealtimeTicketException(this.failure);
  const RealtimeTicketException.unavailable()
    : failure = RealtimeTicketFailure.unavailable;
  final RealtimeTicketFailure failure;
}

enum RealtimeClientState {
  connecting,
  authenticating,
  ready,
  reconnecting,
  unavailable,
  authenticationFailed,
  disconnected,
}

abstract interface class RealtimeConnection {
  Future<void> connect();
  Future<void> close();
}

class RealtimeRecoveryClient implements RealtimeConnection {
  RealtimeRecoveryClient({
    required this.url,
    required this.ticket,
    required this.recover,
    required this.onState,
    this.subscriptions,
    this.onEvent,
    Random? random,
  }) : _random = random ?? Random.secure();
  final Uri url;
  final Future<String> Function() ticket;
  final Future<void> Function() recover;
  final void Function(RealtimeClientState state) onState;
  final Future<List<Map<String, Object>>> Function()? subscriptions;
  final void Function(Map<String, dynamic> event)? onEvent;
  final Random _random;
  WebSocket? _socket;
  bool _stopped = false;
  bool _reconnectScheduled = false;
  Timer? _reconnectTimer;
  int _attempt = 0;

  @override
  Future<void> connect() async {
    if (_stopped) return;
    _reconnectScheduled = false;
    onState(RealtimeClientState.connecting);
    String oneTimeTicket = '';
    try {
      oneTimeTicket = await ticket();
      if (_stopped) return;
      onState(RealtimeClientState.authenticating);
      final socket = await WebSocket.connect(
        url.replace(queryParameters: {'ticket': oneTimeTicket}).toString(),
      );
      oneTimeTicket = '';
      if (_stopped) {
        await socket.close();
        return;
      }
      _socket = socket;
      await recover();
      if (_stopped) return;
      final requestId = _newRequestId();
      socket.listen(
        (message) => _onMessage(message, requestId),
        onDone: () => _onDone(socket.closeCode),
        onError: (error, stackTrace) => _onDone(socket.closeCode),
        cancelOnError: true,
      );
      socket.add(
        jsonEncode({
          'schema': 'algaguard.websocket.subscribe',
          'schemaVersion': '1.0.0',
          'requestId': requestId,
          'subscriptions': subscriptions == null
              ? [
                  {
                    'resourceType': 'current-user',
                    'events': ['system.notification'],
                  },
                ]
              : await subscriptions!(),
        }),
      );
    } on RealtimeTicketException {
      oneTimeTicket = '';
      if (!_stopped) onState(RealtimeClientState.authenticationFailed);
    } on WebSocketException {
      oneTimeTicket = '';
      await _discardSocket();
      if (!_stopped) onState(RealtimeClientState.unavailable);
      _scheduleReconnect();
    } catch (_) {
      oneTimeTicket = '';
      await _discardSocket();
      if (!_stopped) onState(RealtimeClientState.unavailable);
      _scheduleReconnect();
    }
  }

  void _onMessage(Object message, String requestId) {
    if (_stopped || message is! String) return;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map) return;
      final schema = decoded['schema'];
      if (schema == 'urn:algaguard:schema:websocket:telemetry-updated:v1-1' &&
          decoded['eventType'] == 'telemetry.updated') {
        onEvent?.call(Map<String, dynamic>.from(decoded));
        return;
      }
      if (decoded['requestId'] != requestId) return;
      if (schema == 'urn:algaguard:schema:websocket:subscription-ack:v1' &&
          decoded['accepted'] is List &&
          (decoded['accepted'] as List).isNotEmpty) {
        _attempt = 0;
        onState(RealtimeClientState.ready);
      } else if (schema == 'urn:algaguard:schema:websocket:realtime-error:v1') {
        onState(RealtimeClientState.authenticationFailed);
      }
    } catch (_) {
      // Invalid messages are ignored; the client never renders raw frames.
    }
  }

  void _onDone(int? closeCode) {
    if (_stopped) return;
    _socket = null;
    if (closeCode == 4401) {
      onState(RealtimeClientState.authenticationFailed);
      return;
    }
    onState(RealtimeClientState.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    if (_reconnectScheduled) return;
    _reconnectScheduled = true;
    onState(RealtimeClientState.reconnecting);
    final exponent = _attempt < 6 ? _attempt++ : 6;
    final delay = Duration(
      milliseconds: 500 * (1 << exponent) + _random.nextInt(251),
    );
    _reconnectTimer = Timer(delay, () async {
      if (!_stopped) await connect();
    });
  }

  Future<void> _discardSocket() async {
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }

  String _newRequestId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  Future<void> close() async {
    _stopped = true;
    _reconnectScheduled = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _socket?.close();
    _socket = null;
    onState(RealtimeClientState.disconnected);
  }
}

enum BootstrapReissueFailureCategory {
  responseSchemaMismatch,
  serviceUuidMismatch,
  transportFailure,
  authorizationFailure,
  serverFailure,
  unexpectedFailure,
}

class BootstrapReissueException implements Exception {
  const BootstrapReissueException(this.category);

  final BootstrapReissueFailureCategory category;

  @override
  String toString() => 'BootstrapReissueException(${category.name})';
}

enum PhysicalSessionApprovalFailureCategory { expired }

class PhysicalSessionApprovalException implements Exception {
  const PhysicalSessionApprovalException(this.category);
  final PhysicalSessionApprovalFailureCategory category;

  @override
  String toString() => 'PhysicalSessionApprovalException(${category.name})';
}

String canonicalFlutterBlueUuid(Guid uuid) => uuid.str128.toLowerCase();
