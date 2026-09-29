import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/models.dart';
import '../data/repository.dart';
import '../services/notifications.dart';
import 'home.dart';
import 'today_screen.dart';

const _weeksShown = 26;

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key, required this.repo, required this.notifications});

  final Repository repo;
  final Notifications notifications;

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  Map<String, DayLevel> _levels = {};
  int _streak = 0;
  TimeOfDay _reminder = defaultReminder;

  Repository get repo => widget.repo;

  /// Monday of the oldest week shown.
  String get _start {
    final t = parseDateKey(repo.today);
    final monday = DateTime(t.year, t.month, t.day - (t.weekday - 1));
    return dateKey(DateTime(monday.year, monday.month, monday.day - 7 * (_weeksShown - 1)));
  }

  @override
  void initState() {
    super.initState();
    repo.revision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    repo.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final levels = await repo.heatmap(_start, repo.today);
    final streak = await repo.mitStreak();
    final reminder = await loadReminderTime(repo);
    if (!mounted) return;
    setState(() {
      _levels = levels;
      _streak = streak;
      _reminder = reminder;
    });
  }

  Future<void> _pickReminder() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _reminder,
      helpText: 'Nightly planning reminder',
    );
    if (picked == null) return;
    await saveReminderTime(repo, picked);
    await widget.notifications.schedulePlanReminder(picked);
    setState(() => _reminder = picked);
  }

  void _openDay(String date) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TodayScreen(repo: repo, date: date),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    Color levelColor(DayLevel? l) => switch (l) {
      null || DayLevel.none => colors.surfaceContainerHighest,
      DayLevel.logged => colors.primary.withValues(alpha: 0.25),
      DayLevel.secondaryDone => colors.primary.withValues(alpha: 0.55),
      DayLevel.mitDone => colors.primary,
    };

    final today = repo.today;
    // Newest week first so this week is visible without scrolling.
    final weeks = [for (var w = _weeksShown - 1; w >= 0; w--) addDays(_start, 7 * w)];
    final mitDays = _levels.values.where((l) => l == DayLevel.mitDone).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Progress'),
        actions: [
          TextButton.icon(
            onPressed: _pickReminder,
            icon: const Icon(Icons.notifications_outlined),
            label: Text(_reminder.format(context)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Row(
            children: [
              _Stat(value: '$_streak', label: 'day MIT streak'),
              const SizedBox(width: 12),
              _Stat(value: '$mitDays', label: 'MITs done, last $_weeksShown weeks'),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              const SizedBox(width: 56),
              for (final d in ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                Expanded(
                  child: Center(child: Text(d, style: theme.textTheme.labelSmall)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          for (final monday in weeks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      DateFormat('d MMM').format(parseDateKey(monday)),
                      style: theme.textTheme.labelSmall?.copyWith(color: colors.outline),
                    ),
                  ),
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final date = addDays(monday, i);
                          final future = date.compareTo(today) > 0;
                          return Padding(
                            padding: const EdgeInsets.all(2),
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: Material(
                                color: future ? Colors.transparent : levelColor(_levels[date]),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                  side: date == today
                                      ? BorderSide(color: colors.onSurface, width: 1.5)
                                      : BorderSide.none,
                                ),
                                child: future ? null : InkWell(onTap: () => _openDay(date)),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              for (final (level, label) in [
                (DayLevel.mitDone, 'MIT done'),
                (DayLevel.secondaryDone, 'Other task done'),
                (DayLevel.logged, 'Planned, nothing done'),
                (DayLevel.none, 'No plan'),
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(color: levelColor(level), borderRadius: BorderRadius.circular(3)),
                    ),
                    const SizedBox(width: 6),
                    Text(label, style: theme.textTheme.bodySmall),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Card(
        elevation: 0,
        color: theme.colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: theme.textTheme.headlineMedium),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
