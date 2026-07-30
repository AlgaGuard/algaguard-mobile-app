import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'onboarding.dart';
import 'platform_clients.dart';

/// This is intentionally opt-in and cannot be enabled in a release build.
const physicalSessionApprovalEnabled = bool.fromEnvironment(
  'ALGAGUARD_ENABLE_PHYSICAL_SESSION_APPROVAL',
  defaultValue: false,
);

bool physicalSessionApprovalAvailable({required bool releaseMode}) =>
    physicalSessionApprovalEnabled && !releaseMode;

enum PhysicalSessionApprovalState {
  ready,
  approving,
  approved,
  invalidCode,
  expired,
  rejected,
  sessionUnavailable,
  networkError,
}

class PhysicalSessionApprovalController {
  PhysicalSessionApprovalController({
    required this.api,
    required this.accessToken,
    required this.session,
    required this.enabled,
  });

  final PlatformApi api;
  final String accessToken;
  ProvisioningSession? session;
  final bool enabled;
  bool _busy = false;
  bool get busy => _busy;
  PhysicalSessionApprovalState state = PhysicalSessionApprovalState.ready;

  Future<PhysicalSessionApprovalState> approve(String userCode) async {
    if (!enabled || kReleaseMode) {
      return state = PhysicalSessionApprovalState.sessionUnavailable;
    }
    final active = session;
    final normalized = userCode.toUpperCase().replaceAll(RegExp(r'[ -]'), '');
    if (_busy) {
      return state = PhysicalSessionApprovalState.rejected;
    }
    if (!RegExp(r'^[A-HJ-NP-Z2-9]{6,16}$').hasMatch(normalized)) {
      return state = PhysicalSessionApprovalState.invalidCode;
    }
    if (active == null || active.isExpired) {
      active?.clear();
      session = null;
      return state = PhysicalSessionApprovalState.sessionUnavailable;
    }
    _busy = true;
    state = PhysicalSessionApprovalState.approving;
    try {
      await api.approvePhysicalSessionHandoff(
        accessToken: accessToken,
        userCode: normalized,
        session: active,
      );
      return state = PhysicalSessionApprovalState.approved;
    } on FormatException {
      active.clear();
      session = null;
      return state = PhysicalSessionApprovalState.invalidCode;
    } catch (_) {
      // Never render server bodies or transport exceptions.
      clear();
      return state = PhysicalSessionApprovalState.networkError;
    } finally {
      _busy = false;
    }
  }

  ProvisioningSession takeApprovedSession() {
    final active = session;
    if (state != PhysicalSessionApprovalState.approved || active == null) {
      throw StateError('Approved session is unavailable');
    }
    session = null;
    return active;
  }

  void clear() {
    session?.clear();
    session = null;
  }

  static void clearAuthoritativeSession(ProvisioningSession session) =>
      session.clear();
}

/// Deliberately not registered in normal navigation. Physical validation code
/// may present this development-only screen after an in-memory claim succeeds.
class PhysicalSessionApprovalScreen extends StatefulWidget {
  const PhysicalSessionApprovalScreen({
    super.key,
    required this.controller,
    required this.onApproved,
  });
  final PhysicalSessionApprovalController controller;
  final void Function(BuildContext context, ProvisioningSession session)
  onApproved;

  @override
  State<PhysicalSessionApprovalScreen> createState() =>
      _PhysicalSessionApprovalScreenState();
}

class _PhysicalSessionApprovalScreenState
    extends State<PhysicalSessionApprovalScreen> {
  final _userCode = TextEditingController();

  @override
  void dispose() {
    _userCode.clear();
    _userCode.dispose();
    widget.controller.clear();
    super.dispose();
  }

  String get _status => switch (widget.controller.state) {
    PhysicalSessionApprovalState.ready => 'Ready',
    PhysicalSessionApprovalState.approving => 'Approving',
    PhysicalSessionApprovalState.approved => 'HANDOFF_APPROVED',
    PhysicalSessionApprovalState.invalidCode => 'Invalid code',
    PhysicalSessionApprovalState.expired => 'Expired',
    PhysicalSessionApprovalState.rejected => 'Rejected',
    PhysicalSessionApprovalState.sessionUnavailable => 'Session unavailable',
    PhysicalSessionApprovalState.networkError => 'Network error',
  };

  Future<void> _approve() async {
    final result = await widget.controller.approve(_userCode.text);
    _userCode.clear();
    if (!mounted) return;
    setState(() {});
    if (result == PhysicalSessionApprovalState.approved) {
      widget.onApproved(context, widget.controller.takeApprovedSession());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!physicalSessionApprovalAvailable(releaseMode: kReleaseMode)) {
      return const Scaffold(
        body: Center(child: Text('Development approval unavailable')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Development session approval')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            TextField(
              controller: _userCode,
              maxLength: 20,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'User code'),
            ),
            FilledButton(
              onPressed: widget.controller.busy ? null : _approve,
              child: Text(widget.controller.busy ? 'Approving…' : 'Approve'),
            ),
            Text(_status),
          ],
        ),
      ),
    );
  }
}
