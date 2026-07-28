import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'platform_clients.dart';

const secureTransportPreflightEnabled = bool.fromEnvironment(
  'ALGAGUARD_LOCAL_HTTPS_DEBUG',
);
bool secureTransportPreflightAvailable() =>
    secureTransportPreflightEnabled && !kReleaseMode;

enum SecureTransportState {
  idle,
  checking,
  ready,
  tlsFailure,
  hostnameFailure,
  timeout,
  serviceUnavailable,
  unexpectedFailure,
}

class SecureTransportPreflightController {
  SecureTransportPreflightController(this.api);
  final PlatformApi api;
  bool _busy = false;
  SecureTransportState state = SecureTransportState.idle;
  Future<SecureTransportState> check() async {
    if (_busy) return state;
    _busy = true;
    state = SecureTransportState.checking;
    try {
      state = (await api.secureTransportHealthPreflight())
          ? SecureTransportState.ready
          : SecureTransportState.serviceUnavailable;
    } on DioException catch (e) {
      state =
          e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout
          ? SecureTransportState.timeout
          : SecureTransportState.tlsFailure;
    } catch (_) {
      state = SecureTransportState.unexpectedFailure;
    } finally {
      _busy = false;
    }
    return state;
  }

  bool get busy => _busy;
}

class SecureTransportPreflightScreen extends StatefulWidget {
  const SecureTransportPreflightScreen({super.key, required this.controller});
  final SecureTransportPreflightController controller;
  @override
  State<SecureTransportPreflightScreen> createState() =>
      _SecureTransportPreflightScreenState();
}

class _SecureTransportPreflightScreenState
    extends State<SecureTransportPreflightScreen> {
  Future<void> _check() async {
    await widget.controller.check();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('Secure Transport Preflight')),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: widget.controller.busy ? null : _check,
            child: const Text('Check Secure HTTPS'),
          ),
          Text(
            widget.controller.state == SecureTransportState.ready
                ? 'MOBILE SECURE TRANSPORT READY'
                : widget.controller.state.name,
          ),
        ],
      ),
    ),
  );
}
