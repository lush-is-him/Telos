import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../services/notifications.dart';
import '../services/sync.dart';
import 'home.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.repo, required this.notifications, required this.sync});

  final Repository repo;
  final Notifications notifications;
  final SyncService sync;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  TimeOfDay _reminder = defaultReminder;
  TimeOfDay? _morning;
  String? _lastSync;
  String? _lastError;
  bool _canRestore = false;
  bool _busy = false;

  Repository get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _url.text = await repo.getSetting(serverUrlKey) ?? '';
    _token.text = await repo.getSetting(serverTokenKey) ?? '';
    final reminder = await loadReminderTime(repo);
    final morning = await loadTime(repo, morningNudgeKey);
    final last = await repo.getSetting(lastSyncKey);
    final err = await repo.getSetting(lastSyncErrorKey);
    final hasPlans = await repo.hasAnyPlans();
    if (!mounted) return;
    setState(() {
      _reminder = reminder;
      _morning = morning;
      _lastSync = last;
      _lastError = (err?.isEmpty ?? true) ? null : err;
      _canRestore = !hasPlans;
    });
  }

  Future<void> _run(Future<String> Function() action) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final msg = await action();
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      await _load();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveServer() => _run(() async {
    await repo.setSetting(serverUrlKey, _url.text.trim());
    await repo.setSetting(serverTokenKey, _token.text.trim());
    if (!await widget.sync.ping()) return 'Saved, but the server did not answer.';
    final err = await widget.sync.push();
    return err == null ? 'Connected and synced.' : 'Connected, but sync failed: $err';
  });

  Future<void> _pickReminder() async {
    final t = await showTimePicker(context: context, initialTime: _reminder, helpText: 'Nightly planning reminder');
    if (t == null) return;
    await saveTime(repo, planReminderKey, t);
    await widget.notifications.schedulePlanReminder(t);
    setState(() => _reminder = t);
  }

  Future<void> _setMorning(bool on) async {
    TimeOfDay? t;
    if (on) {
      t = await showTimePicker(
        context: context,
        initialTime: _morning ?? defaultMorningNudge,
        helpText: 'Morning nudge',
      );
      if (t == null) return;
    }
    await saveTime(repo, morningNudgeKey, t);
    await widget.notifications.scheduleMorningNudge(t);
    setState(() => _morning = t);
  }

  String _ago(String iso) {
    final d = DateTime.now().difference(DateTime.parse(iso));
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text('Reminders', style: theme.textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.nightlight_outlined),
            title: const Text('Plan tomorrow'),
            subtitle: const Text('Opens the Plan screen'),
            trailing: TextButton(onPressed: _pickReminder, child: Text(_reminder.format(context))),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.wb_sunny_outlined),
            title: const Text("Morning nudge"),
            subtitle: Text(_morning == null ? 'Off' : 'At ${_morning!.format(context)}'),
            value: _morning != null,
            onChanged: _setMorning,
          ),
          const Divider(height: 32),
          Text('Home server backup', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Changes are pushed whenever the app opens or closes and the server is reachable. '
            'If it is off, nothing is lost — they go next time.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://ubuntu-pc.tailnet.ts.net:8000',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Token', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(onPressed: _busy ? null : _saveServer, child: const Text('Save & sync')),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _lastError != null
                      ? 'Last attempt failed'
                      : _lastSync == null
                      ? 'Never synced'
                      : 'Synced ${_ago(_lastSync!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _lastError != null ? theme.colorScheme.error : null,
                  ),
                ),
              ),
            ],
          ),
          if (_lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_lastError!, style: theme.textTheme.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
          if (_canRestore) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.restore),
              label: const Text('Restore from server'),
              onPressed: _busy ? null : () => _run(() async => 'Restored ${await widget.sync.restore()} rows.'),
            ),
            Text('Only available on an empty phone (e.g. after reinstalling).', style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
