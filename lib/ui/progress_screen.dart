import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/models.dart';
import '../data/repository.dart';
import '../services/notifications.dart';
import '../services/sync.dart';
import 'settings_screen.dart';
import 'today_screen.dart';

const _weeksShown = 26;

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key, required this.repo, required this.notifications, required this.sync});

  final Repository repo;
  final Notifications notifications;
  final SyncService sync;

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  Map<String, DayLevel> _levels = {};
  int _streak = 0;
  Map<int, ({int planned, int done})> _weekday = {};
  List<String> _neglected = [];
  List<Deadline> _deadlines = [];

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
    final weekday = await repo.mitByWeekday();
    final neglected = await repo.neglectedSubjects();
    final deadlines = await repo.upcomingDeadlines();
    if (!mounted) return;
    setState(() {
      _levels = levels;
      _streak = streak;
      _weekday = weekday;
      _neglected = neglected;
      _deadlines = deadlines;
    });
  }

  Future<void> _addDeadline() async {
    final title = TextEditingController();
    final subject = TextEditingController();
    var due = DateTime.now().add(const Duration(days: 7));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Add deadline'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'What'),
              ),
              TextField(
                controller: subject,
                decoration: const InputDecoration(labelText: 'Subject (optional)'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.event),
                label: Text(DateFormat('EEE d MMM').format(due)),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: due,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                  );
                  if (picked != null) setDialog(() => due = picked);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      await repo.addDeadline(title: title.text, dueDate: dateKey(due), subject: subject.text);
    }
  }

  String _dueLabel(String due) {
    final days = parseDateKey(due).difference(parseDateKey(repo.today)).inDays;
    final when = DateFormat('EEE d MMM').format(parseDateKey(due));
    return days == 0 ? '$when · today' : '$when · in $days day${days == 1 ? '' : 's'}';
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
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(repo: repo, notifications: widget.notifications, sync: widget.sync),
              ),
            ),
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
          if (_neglected.isNotEmpty) ...[
            const SizedBox(height: 24),
            Card(
              elevation: 0,
              color: colors.errorContainer,
              child: ListTile(
                leading: Icon(Icons.warning_amber_rounded, color: colors.onErrorContainer),
                title: Text('Planned often, never finished', style: TextStyle(color: colors.onErrorContainer)),
                subtitle: Text(
                  '${_neglected.join(', ')} — 3+ times in two weeks, nothing marked done. Smaller chunks?',
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),
          Text('MIT done by weekday · last 12 weeks', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          _WeekdayBars(stats: _weekday),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(child: Text('Deadlines', style: theme.textTheme.titleSmall)),
              TextButton.icon(onPressed: _addDeadline, icon: const Icon(Icons.add), label: const Text('Add')),
            ],
          ),
          if (_deadlines.isEmpty)
            Text('None. Deadlines help the forecast.', style: theme.textTheme.bodySmall)
          else
            for (final d in _deadlines)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(d.subject == null ? d.title : '${d.title} · ${d.subject}'),
                subtitle: Text(_dueLabel(d.dueDate)),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                  onPressed: () => repo.deleteDeadline(d.id),
                ),
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

/// Descriptive only: share of planned MITs done, per weekday. Bars carry the
/// count so a 100% from one day isn't mistaken for a pattern.
class _WeekdayBars extends StatelessWidget {
  const _WeekdayBars({required this.stats});
  final Map<int, ({int planned, int done})> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return SizedBox(
      height: 132,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var d = 1; d <= 7; d++)
            Expanded(
              child: Builder(
                builder: (context) {
                  final s = stats[d] ?? (planned: 0, done: 0);
                  final rate = s.planned == 0 ? 0.0 : s.done / s.planned;
                  return Tooltip(
                    message: '${labels[d - 1]}: ${s.done} of ${s.planned} MITs done',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(s.planned == 0 ? '–' : '${(rate * 100).round()}%', style: theme.textTheme.labelSmall),
                        const SizedBox(height: 4),
                        Container(
                          height: 4 + 80 * rate,
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(labels[d - 1], style: theme.textTheme.labelSmall),
                        Text(
                          'n=${s.planned}',
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
