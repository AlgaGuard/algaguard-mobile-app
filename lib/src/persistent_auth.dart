import 'dart:async';

import 'package:flutter/foundation.dart';

enum PersistentAuthState { checking, authenticated, signedOut, unavailable }

class PersistentAuthController extends ChangeNotifier {
  PersistentAuthController({
    required this.hasRefreshToken,
    required this.accessTokenExpiry,
    required this.refresh,
    required this.login,
    required this.logout,
    this.refreshSkew = const Duration(minutes: 1),
  });

  final Future<bool> Function() hasRefreshToken;
  final Future<DateTime?> Function() accessTokenExpiry;
  final Future<String?> Function() refresh;
  final Future<void> Function() login;
  final Future<void> Function() logout;
  final Duration refreshSkew;

  PersistentAuthState state = PersistentAuthState.checking;
  Timer? _timer;
  bool _working = false;

  Future<void> restore() async {
    if (_working) return;
    _working = true;
    state = PersistentAuthState.checking;
    notifyListeners();
    try {
      if (!await hasRefreshToken()) {
        state = PersistentAuthState.signedOut;
        return;
      }
      final token = await refresh();
      if (token == null) {
        state = PersistentAuthState.unavailable;
        return;
      }
      state = PersistentAuthState.authenticated;
      await _scheduleRefresh();
    } catch (_) {
      // Preserve the refresh token on transient network/provider failures.
      state = PersistentAuthState.unavailable;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<void> signIn() async {
    if (_working) return;
    _working = true;
    try {
      await login();
      state = PersistentAuthState.authenticated;
      await _scheduleRefresh();
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<void> refreshNow() async {
    if (_working || state != PersistentAuthState.authenticated) return;
    _working = true;
    try {
      if (await refresh() == null) {
        state = PersistentAuthState.unavailable;
        _timer?.cancel();
      } else {
        await _scheduleRefresh();
      }
    } catch (_) {
      // A temporary outage must not silently sign the user out.
      state = PersistentAuthState.unavailable;
      _timer?.cancel();
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<void> resumed() async {
    if (state == PersistentAuthState.unavailable) {
      await restore();
    } else {
      await refreshNow();
    }
  }

  Future<void> signOut() async {
    _timer?.cancel();
    await logout();
    state = PersistentAuthState.signedOut;
    notifyListeners();
  }

  Future<void> _scheduleRefresh() async {
    _timer?.cancel();
    final expiry = await accessTokenExpiry();
    final delay = expiry == null
        ? const Duration(minutes: 3)
        : expiry.difference(DateTime.now().toUtc()) - refreshSkew;
    _timer = Timer(
      delay.isNegative ? const Duration(seconds: 1) : delay,
      () => unawaited(refreshNow()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
