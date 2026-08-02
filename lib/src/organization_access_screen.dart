import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'platform_clients.dart';

class OrganizationAccessScreen extends StatefulWidget {
  const OrganizationAccessScreen({super.key, required this.apiBaseUrl});
  final Uri apiBaseUrl;

  @override
  State<OrganizationAccessScreen> createState() =>
      _OrganizationAccessScreenState();
}

class _OrganizationAccessScreenState extends State<OrganizationAccessScreen> {
  final _store = const TokenStore(FlutterSecureStorage());
  List<OrganizationInvitationSummary> _incoming = const [];
  bool _loading = true;
  String? _message;

  Future<String> _token() async =>
      await _store.readAccessToken() ??
      (throw StateError('Authentication required'));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await PlatformApi(
        widget.apiBaseUrl,
      ).listIncomingInvitations(accessToken: await _token());
      if (mounted) setState(() => _incoming = values);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Invitations could not be loaded.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _invite() async {
    final email = TextEditingController();
    var role = 'VIEWER';
    final submit = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Invite organization member'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Existing account email',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: const [
                  DropdownMenuItem(value: 'ADMIN', child: Text('Admin')),
                  DropdownMenuItem(value: 'VIEWER', child: Text('Viewer only')),
                ],
                onChanged: (value) =>
                    setDialogState(() => role = value ?? 'VIEWER'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Send invite'),
            ),
          ],
        ),
      ),
    );
    if (submit == true) {
      try {
        final organizationId = await _store.readSelectedOrganization();
        if (organizationId == null) throw StateError('Organization required');
        await PlatformApi(widget.apiBaseUrl).inviteOrganizationMember(
          accessToken: await _token(),
          organizationId: organizationId,
          email: email.text,
          role: role,
        );
        if (mounted) setState(() => _message = 'Invitation sent safely.');
      } catch (_) {
        if (mounted) {
          setState(
            () => _message =
                'Invitation was not sent. Owner or admin access is required.',
          );
        }
      }
    }
    email.dispose();
  }

  Future<void> _respond(
    OrganizationInvitationSummary invitation,
    bool accept,
  ) async {
    try {
      await PlatformApi(widget.apiBaseUrl).respondToInvitation(
        accessToken: await _token(),
        invitationId: invitation.id,
        accept: accept,
      );
      if (mounted) {
        setState(
          () => _message = accept
              ? 'Invitation accepted.'
              : 'Invitation rejected.',
        );
      }
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Invitation response was not saved.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Organization access')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _invite,
      icon: const Icon(Icons.person_add),
      label: const Text('Invite user'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Incoming invitations',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_message!),
          ),
        if (!_loading && _incoming.isEmpty)
          const Text('No pending invitations.'),
        for (final invitation in _incoming)
          Card(
            child: ListTile(
              title: Text(invitation.organizationName),
              subtitle: Text(
                invitation.role == 'ADMIN' ? 'Admin' : 'Viewer only',
              ),
              trailing: Wrap(
                children: [
                  TextButton(
                    onPressed: () => _respond(invitation, false),
                    child: const Text('Reject'),
                  ),
                  FilledButton(
                    onPressed: () => _respond(invitation, true),
                    child: const Text('Accept'),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
