import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'algae_profiles.dart';
import 'platform_clients.dart';

class AlgaeProfilesScreen extends StatefulWidget {
  const AlgaeProfilesScreen({super.key, required this.apiBaseUrl});
  final Uri apiBaseUrl;

  @override
  State<AlgaeProfilesScreen> createState() => _AlgaeProfilesScreenState();
}

class _AlgaeProfilesScreenState extends State<AlgaeProfilesScreen> {
  final _store = const TokenStore(FlutterSecureStorage());
  List<ProfileSummary> _profiles = const [];
  bool _loading = true;
  String? _error;

  Future<(PlatformApi, String, String)> _context() async {
    final token = await _store.readAccessToken();
    final organizationId = await _store.readSelectedOrganization();
    if (token == null || organizationId == null) {
      throw StateError('Authentication required');
    }
    return (PlatformApi(widget.apiBaseUrl), token, organizationId);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final authorized = await _context();
      final profiles = await authorized.$1.listProfiles(
        accessToken: authorized.$2,
        organizationId: authorized.$3,
      );
      if (mounted) setState(() => _profiles = profiles);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Algae profiles could not be loaded.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit([ProfileSummary? existing]) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final fields = <String, (TextEditingController, TextEditingController)>{
      for (final parameter in algaeParameters)
        parameter.key: (
          TextEditingController(
            text:
                existing?.configuration?.thresholds[parameter.key]?.minimum
                    .toString() ??
                '',
          ),
          TextEditingController(
            text:
                existing?.configuration?.thresholds[parameter.key]?.maximum
                    .toString() ??
                '',
          ),
        ),
    };
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          existing == null ? 'Create Algae Profile' : 'Edit Algae Profile',
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('algae-profile-name'),
                  controller: name,
                  readOnly: existing != null,
                  maxLength: 120,
                  decoration: const InputDecoration(
                    labelText: 'Algae type / profile name',
                  ),
                ),
                const Text(
                  'Enter operator-selected limits. These values are not scientific recommendations.',
                ),
                for (final parameter in algaeParameters)
                  Row(
                    children: [
                      Expanded(child: Text(parameter.label)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: fields[parameter.key]!.$1,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: InputDecoration(
                            labelText: 'Min (${parameter.unit})',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: fields[parameter.key]!.$2,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: InputDecoration(
                            labelText: 'Max (${parameter.unit})',
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (submitted != true) {
      name.dispose();
      for (final value in fields.values) {
        value.$1.dispose();
        value.$2.dispose();
      }
      return;
    }
    try {
      final normalizedName = name.text.trim();
      final thresholds = <String, AlgaeThreshold>{};
      for (final parameter in algaeParameters) {
        final minimum = double.tryParse(fields[parameter.key]!.$1.text.trim());
        final maximum = double.tryParse(fields[parameter.key]!.$2.text.trim());
        if (minimum == null ||
            maximum == null ||
            !minimum.isFinite ||
            !maximum.isFinite ||
            minimum >= maximum) {
          throw const FormatException(
            'Every minimum must be lower than its maximum.',
          );
        }
        thresholds[parameter.key] = AlgaeThreshold(
          minimum: minimum,
          maximum: maximum,
        );
      }
      final configuration = AlgaeProfileConfiguration(
        Map.unmodifiable(thresholds),
      );
      final authorized = await _context();
      if (existing == null) {
        await authorized.$1.createAlgaeProfile(
          accessToken: authorized.$2,
          organizationId: authorized.$3,
          name: normalizedName,
          configuration: configuration,
        );
      } else {
        await authorized.$1.updateAlgaeProfile(
          accessToken: authorized.$2,
          profile: existing,
          configuration: configuration,
        );
      }
      await _load();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message.toString()
              : 'Algae profile was not saved.',
        );
      }
    } finally {
      name.dispose();
      for (final value in fields.values) {
        value.$1.dispose();
        value.$2.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Algae Profiles')),
    floatingActionButton: FloatingActionButton.extended(
      key: const Key('create-algae-profile'),
      onPressed: () => _edit(),
      icon: const Icon(Icons.add),
      label: const Text('Create profile'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (!_loading && _profiles.isEmpty)
          const Text('No Algae Profiles yet.'),
        for (final profile in _profiles)
          Card(
            child: ListTile(
              title: Text(profile.name),
              subtitle: Text(
                profile.configuration == null
                    ? 'Thresholds not configured'
                    : 'Six sensor thresholds configured · version ${profile.version}',
              ),
              trailing: const Icon(Icons.edit),
              onTap: () => _edit(profile),
            ),
          ),
      ],
    ),
  );
}
