import 'dart:async';

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
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  final PlatformApi api;
  final String accessToken;
  ProvisioningSession? session;
  final bool enabled;
  final DateTime Function() _now;
  bool _busy = false;
  bool get busy => _busy;
  PhysicalSessionApprovalState state = PhysicalSessionApprovalState.ready;

  Duration get remaining => session?.remaining(now: _now()) ?? Duration.zero;

  bool refreshExpiry() {
    final active = session;
    if (active == null || !active.isExpiredAt(_now())) return false;
    active.clear();
    session = null;
    state = PhysicalSessionApprovalState.expired;
    return true;
  }

  bool replaceExpiredSession(ProvisioningSession replacement) {
    if (session != null && !refreshExpiry()) return false;
    session = replacement;
    state = PhysicalSessionApprovalState.ready;
    return true;
  }

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
    if (active == null || refreshExpiry()) {
      active?.clear();
      return state = active == null
          ? PhysicalSessionApprovalState.sessionUnavailable
          : PhysicalSessionApprovalState.expired;
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
    } on PhysicalSessionApprovalException catch (error) {
      clear();
      return state = switch (error.category) {
        PhysicalSessionApprovalFailureCategory.expired =>
          PhysicalSessionApprovalState.expired,
      };
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
  Timer? _countdown;

  @override
  void initState() {
    super.initState();
    widget.controller.refreshExpiry();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      widget.controller.refreshExpiry();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _userCode.clear();
    _userCode.dispose();
    widget.controller.clear();
    super.dispose();
  }

  String get _status => switch (widget.controller.state) {
    PhysicalSessionApprovalState.ready => 'Session ready',
    PhysicalSessionApprovalState.approving => 'Approving',
    PhysicalSessionApprovalState.approved => 'HANDOFF_APPROVED',
    PhysicalSessionApprovalState.invalidCode => 'Invalid code',
    PhysicalSessionApprovalState.expired => 'Session expired',
    PhysicalSessionApprovalState.rejected => 'Rejected',
    PhysicalSessionApprovalState.sessionUnavailable => 'Session unavailable',
    PhysicalSessionApprovalState.networkError => 'Network error',
  };

  String get _countdownText {
    final remaining = widget.controller.remaining;
    final minutes = remaining.inMinutes.toString().padLeft(2, '0');
    final seconds = (remaining.inSeconds % 60).toString().padLeft(2, '0');
    return 'Expires in $minutes:$seconds';
  }

  Future<void> _approve() async {
    final result = await widget.controller.approve(_userCode.text);
    _userCode.clear();
    if (!mounted) return;
    setState(() {});
    if (result == PhysicalSessionApprovalState.approved) {
      widget.onApproved(context, widget.controller.takeApprovedSession());
    }
  }

  // A pending handoff session self-heals via its own expiry timer even if
  // this screen is force-closed, but a stray back tap mid-approval would
  // otherwise discard it with no confirmation -- warn instead, same pattern
  // as the other mid-flow screens.
  Future<void> _confirmLeave() async {
    if (widget.controller.state == PhysicalSessionApprovalState.expired) {
      Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this approval?'),
        content: const Text(
          'Leaving now discards this pending session approval. The device '
          'will need a fresh session request.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Leave anyway'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (!physicalSessionApprovalAvailable(releaseMode: kReleaseMode)) {
      return const Scaffold(
        body: Center(child: Text('Development approval unavailable')),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_confirmLeave());
      },
      child: Scaffold(
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
                onPressed:
                    widget.controller.busy ||
                        widget.controller.state ==
                            PhysicalSessionApprovalState.expired
                    ? null
                    : _approve,
                child: Text(widget.controller.busy ? 'Approving…' : 'Approve'),
              ),
              Text(_status),
              if (widget.controller.state !=
                  PhysicalSessionApprovalState.expired)
                Text(_countdownText),
              if (widget.controller.state ==
                  PhysicalSessionApprovalState.expired)
                const Text('Request a fresh development session'),
            ],
          ),
        ),
      ),
    );
  }
}
