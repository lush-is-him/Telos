import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/models.dart';
import '../data/repository.dart';

String formatMinutes(int m) => m < 60 ? '${m}m' : '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';

/// Today's work. With [date] set it shows that day instead (from the heatmap).
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key, required this.repo, this.date, this.onPlan});

  final Repository repo;
  final String? date;
  final VoidCallback? onPlan;

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> with WidgetsBindingObserver {
  DayPlan? _plan;
  RunningTimer? _running;
  Timer? _ticker;

  Repository get repo => widget.repo;
  String get _date => widget.date ?? repo.today;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    repo.revision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    repo.revision.removeListener(_load);
    _ticker?.cancel();
    super.dispose();
  }

  // Coming back to the app may cross midnight.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      repo.recordAppOpen();
      _load();
    }
  }

  Future<void> _load() async {
    final plan = await repo.loadDay(_date);
    final running = await repo.runningTimer();
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _running = running;
    });
    _ticker?.cancel();
    if (running != null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    }
  }

  int? _liveMinutes(String itemId) {
    final r = _running;
    if (r == null || r.itemId != itemId) return null;
    return DateTime.now().difference(r.startedAt).inMinutes;
  }

  void _toggleTimer(ItemKind kind, String id) {
    if (_running?.itemId == id) {
      repo.stopTimer();
    } else {
      repo.startTimer(kind, id);
    }
  }

  Future<void> _adjustMinutes(ItemKind kind, String id) async {
    final controller = TextEditingController();
    final minutes = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add minutes'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          decoration: const InputDecoration(hintText: 'e.g. 30, or -10 to correct'),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, int.tryParse(controller.text)),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (minutes != null && minutes != 0) await repo.addManualMinutes(kind, id, minutes);
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final isToday = _date == repo.today;
    final title = isToday ? 'Today' : DateFormat('EEE d MMM yyyy').format(parseDateKey(_date));

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: plan == null
          ? const Center(child: CircularProgressIndicator())
          : plan.isEmpty
          ? _EmptyDay(isToday: isToday, onPlan: widget.onPlan)
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (plan.mit != null) ...[
                  const _SectionLabel('Most important'),
                  _taskTile(plan.mit!, emphasised: true),
                ],
                if (plan.secondaries.isNotEmpty) ...[
                  const _SectionLabel('Also'),
                  for (final t in plan.secondaries) _taskTile(t),
                ],
                if (plan.study.isNotEmpty) ...[const _SectionLabel('Study'), for (final s in plan.study) _studyTile(s)],
              ],
            ),
    );
  }

  Widget _taskTile(Task t, {bool emphasised = false}) {
    final theme = Theme.of(context);
    final live = _liveMinutes(t.id);
    final style = (emphasised ? theme.textTheme.titleLarge : theme.textTheme.titleMedium)?.copyWith(
      decoration: t.done ? TextDecoration.lineThrough : null,
      color: t.done ? theme.colorScheme.outline : null,
    );
    return Card(
      elevation: 0,
      color: emphasised ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        leading: Checkbox(value: t.done, onChanged: (v) => repo.setTaskDone(t.id, v ?? false)),
        title: Text(t.title, style: style),
        subtitle: _meta([t.category?.name, _timeLabel(t.timeSpentMinutes, live)]),
        trailing: t.done
            ? null
            : _TimerButton(running: live != null, onPressed: () => _toggleTimer(ItemKind.task, t.id)),
        onLongPress: () => _adjustMinutes(ItemKind.task, t.id),
      ),
    );
  }

  Widget _studyTile(StudyItem s) {
    final theme = Theme.of(context);
    final live = _liveMinutes(s.id);
    final done = s.status == StudyStatus.done;
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        leading: IconButton(
          tooltip: '${s.status.label} — tap to change',
          icon: Icon(switch (s.status) {
            StudyStatus.notStarted => Icons.radio_button_unchecked,
            StudyStatus.partial => Icons.timelapse,
            StudyStatus.done => Icons.check_circle,
          }),
          color: done ? theme.colorScheme.primary : null,
          onPressed: () =>
              repo.setStudyStatus(s.id, StudyStatus.values[(s.status.index + 1) % StudyStatus.values.length]),
        ),
        title: Text(
          '${s.subject} · ${s.workToDo}',
          style: theme.textTheme.titleMedium?.copyWith(
            decoration: done ? TextDecoration.lineThrough : null,
            color: done ? theme.colorScheme.outline : null,
          ),
        ),
        subtitle: _meta([s.status.label, _timeLabel(s.timeSpentMinutes, live)]),
        trailing: done
            ? null
            : _TimerButton(running: live != null, onPressed: () => _toggleTimer(ItemKind.study, s.id)),
        onLongPress: () => _adjustMinutes(ItemKind.study, s.id),
      ),
    );
  }

  String? _timeLabel(int logged, int? live) {
    if (live != null) return '${formatMinutes(logged + live)} · running';
    return logged > 0 ? formatMinutes(logged) : null;
  }

  Widget? _meta(List<String?> parts) {
    final text = parts.whereType<String>().join(' · ');
    return text.isEmpty ? null : Text(text);
  }
}

class _TimerButton extends StatelessWidget {
  const _TimerButton({required this.running, required this.onPressed});
  final bool running;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => running
      ? IconButton.filled(tooltip: 'Stop timer', icon: const Icon(Icons.pause), onPressed: onPressed)
      : IconButton.outlined(tooltip: 'Start timer', icon: const Icon(Icons.play_arrow), onPressed: onPressed);
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(letterSpacing: 1.2, color: Theme.of(context).colorScheme.outline),
    ),
  );
}

class _EmptyDay extends StatelessWidget {
  const _EmptyDay({required this.isToday, this.onPlan});
  final bool isToday;
  final VoidCallback? onPlan;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(isToday ? 'Nothing planned for today.' : 'Nothing was planned this day.'),
        if (isToday && onPlan != null) ...[
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onPlan, child: const Text('Plan now')),
        ],
      ],
    ),
  );
}
