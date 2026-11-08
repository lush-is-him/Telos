import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/models.dart';
import '../data/repository.dart';

IconData kindIcon(GoalKind k) => switch (k) {
  GoalKind.task => Icons.task_alt,
  GoalKind.study => Icons.menu_book,
  GoalKind.action => Icons.bolt,
};

Color priorityColor(BuildContext context, Priority p) {
  final cs = Theme.of(context).colorScheme;
  return switch (p) {
    Priority.high => cs.error,
    Priority.medium => cs.tertiary,
    Priority.low => cs.outline,
  };
}

/// Small coloured "High / Medium / Low" label.
class PriorityTag extends StatelessWidget {
  const PriorityTag(this.priority, {super.key});
  final Priority priority;

  @override
  Widget build(BuildContext context) {
    final c = priorityColor(context, priority);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: c),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(priority.label, style: TextStyle(fontSize: 11, color: c)),
    );
  }
}

/// Weekly goals (Sunday to Friday): write them with a priority, split big ones
/// into steps, see how the app would spread them over the days, and rate the
/// week on Friday evening.
class WeekScreen extends StatefulWidget {
  const WeekScreen({super.key, required this.repo, required this.reviewRequests});

  final Repository repo;

  /// Bumped when the Friday notification is tapped: opens the review.
  final ValueListenable<int> reviewRequests;

  @override
  State<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends State<WeekScreen> {
  late String _week = widget.repo.currentWeek;
  List<Goal> _goals = [];
  WeekDraft? _draft;
  Capacity? _capacity;
  String? _toReview;
  int _carryable = 0;
  bool _loaded = false;
  final _stepFields = <String, TextEditingController>{};

  Repository get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    repo.revision.addListener(_load);
    widget.reviewRequests.addListener(_openReviewFromNotification);
    _load();
    // Cold start from the Friday notification: the request came before us.
    if (widget.reviewRequests.value > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openReviewFromNotification());
    }
  }

  @override
  void dispose() {
    repo.revision.removeListener(_load);
    widget.reviewRequests.removeListener(_openReviewFromNotification);
    for (final c in _stepFields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final goals = await repo.loadWeek(_week);
    final draft = await repo.weekDraft(_week);
    final capacity = await repo.capacity();
    final toReview = await repo.weekToReview();
    final previous = await repo.loadWeek(addDays(_week, -7));
    final titles = {for (final g in goals) g.title.toLowerCase()};
    if (!mounted) return;
    setState(() {
      _goals = goals;
      _draft = draft;
      _capacity = capacity;
      _toReview = toReview;
      _carryable = previous.where((g) => !g.done && !titles.contains(g.title.toLowerCase())).length;
      _loaded = true;
    });
  }

  Future<void> _openReviewFromNotification() async {
    final week = await repo.weekToReview();
    if (week != null && mounted) await _review(week);
  }

  void _shiftWeek(int weeks) {
    setState(() => _week = addDays(_week, 7 * weeks));
    _load();
  }

  String _range(String week) {
    final start = parseDateKey(week);
    final end = parseDateKey(addDays(week, 5));
    final f = DateFormat('d MMM');
    return start.month == end.month ? '${start.day} – ${f.format(end)}' : '${f.format(start)} – ${f.format(end)}';
  }

  int get _plannedUnits => _goals.fold(0, (n, g) => n + g.units);

  // ------------------------------------------------------------------ actions

  Future<void> _addGoal() async {
    final result = await showDialog<({String title, GoalKind kind, Priority priority})>(
      context: context,
      builder: (_) => const _GoalDialog(),
    );
    if (result == null) return;
    await repo.addGoal(weekStart: _week, title: result.title, kind: result.kind, priority: result.priority);
  }

  Future<void> _editGoal(Goal g) async {
    final result = await showDialog<({String title, GoalKind kind, Priority priority})>(
      context: context,
      builder: (_) => _GoalDialog(initial: g),
    );
    if (result == null) return;
    await repo.updateGoal(g.id, title: result.title, kind: result.kind, priority: result.priority);
  }

  Future<void> _deleteGoal(Goal g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete goal?'),
        content: Text('"${g.title}" and its steps will be removed. Tasks already planned from it stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await repo.deleteGoal(g.id);
  }

  Future<void> _carryOver() async {
    final n = await repo.carryOver(addDays(_week, -7), _week);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Carried over $n unfinished goal${n == 1 ? '' : 's'}.')));
  }

  Future<void> _review(String week) async {
    final goals = await repo.loadWeek(week);
    final existing = await repo.reviewFor(week);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _ReviewPage(repo: repo, week: week, label: _range(week), goals: goals, existing: existing),
      ),
    );
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final theme = Theme.of(context);
    final isCurrent = _week == repo.currentWeek;

    return Scaffold(
      appBar: AppBar(title: const Text('Week')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Previous week',
                onPressed: () => _shiftWeek(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text('Sun–Fri ${_range(_week)}', style: theme.textTheme.titleMedium),
                    if (isCurrent) Text('This week', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              IconButton(tooltip: 'Next week', onPressed: () => _shiftWeek(1), icon: const Icon(Icons.chevron_right)),
            ],
          ),
          if (_toReview != null) _reviewBanner(_toReview!),
          _capacityCard(),
          if (_carryable > 0 && _week.compareTo(addDays(repo.currentWeek, -1)) >= 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _carryOver,
                icon: const Icon(Icons.redo),
                label: Text('Carry over $_carryable unfinished from last week'),
              ),
            ),
          const SizedBox(height: 8),
          if (_goals.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No goals for this week yet. Add the tasks, topics and actions you want done by Friday.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          for (final g in _goals) _goalCard(g),
          if (_draft != null && _goals.isNotEmpty) ..._draftSection(_draft!),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        // Plan has a FAB too and both live in the same IndexedStack.
        heroTag: 'add_goal',
        onPressed: _addGoal,
        icon: const Icon(Icons.add),
        label: const Text('Add goal'),
      ),
    );
  }

  Widget _reviewBanner(String week) => Card(
    color: Theme.of(context).colorScheme.primaryContainer,
    child: ListTile(
      leading: const Icon(Icons.star_outline),
      title: const Text('How did the week go?'),
      subtitle: Text('Rate Sun–Fri ${_range(week)} so the app learns your pace.'),
      trailing: FilledButton(onPressed: () => _review(week), child: const Text('Rate')),
    ),
  );

  Widget _capacityCard() {
    final c = _capacity!;
    final usual = c.itemsPerWeek.round();
    final planned = _plannedUnits;
    final over = planned - usual;
    final cs = Theme.of(context).colorScheme;
    final warn = over > 0;
    final low = _goals.where((g) => g.priority == Priority.low).length;
    return Card(
      color: warn ? cs.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.weeksObserved == 0
                  ? 'Starting estimate: about $usual items a week. It adjusts after each Friday review.'
                  : 'You usually finish about $usual items a week '
                        '(learned from ${c.weeksObserved} week${c.weeksObserved == 1 ? '' : 's'}'
                        '${c.recentRate == null ? '' : ', ${(c.recentRate! * 100).round()}% of what you planned'}).',
            ),
            const SizedBox(height: 4),
            Text(
              'This week: $planned item${planned == 1 ? '' : 's'} in ${_goals.length} goal${_goals.length == 1 ? '' : 's'}. '
              'Suggesting ${c.perDay} a day.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (warn) ...[
              const SizedBox(height: 6),
              Text(
                "That's $over more than you usually finish. "
                '${low > 0 ? 'Consider dropping some Low priority goals.' : 'Consider lowering the priority of some, or dropping a few.'}',
                style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _goalCard(Goal g) {
    final theme = Theme.of(context);
    final stepCtrl = _stepFields.putIfAbsent(g.id, TextEditingController.new);
    final scheduled = <String, String>{};
    for (final e in _draft?.days.entries ?? const <MapEntry<String, List<BucketItem>>>[]) {
      for (final i in e.value) {
        if (!_draft!.forecast.contains(i.key)) scheduled[i.key] = e.key;
      }
    }
    String? dayOf(String key) {
      final d = scheduled[key];
      return d == null ? null : DateFormat('EEE').format(parseDateKey(d));
    }

    TextStyle? doneStyle(bool done) =>
        done ? const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.grey) : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.only(left: 8),
              leading: g.steps.isEmpty
                  ? Checkbox(value: g.done, onChanged: (v) => repo.setItemDone(g.id, null, v ?? false))
                  : Icon(kindIcon(g.kind)),
              title: Text(g.title, style: doneStyle(g.done)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    PriorityTag(g.priority),
                    Text(
                      [
                        g.kind.name,
                        if (g.steps.isNotEmpty) '${g.unitsDone}/${g.units} steps',
                        if (g.steps.isEmpty && dayOf(g.id) != null) 'planned ${dayOf(g.id)}',
                        if (g.rating != null) 'rated ${g.rating!.label.toLowerCase()}',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'edit' => _editGoal(g),
                  'delete' => _deleteGoal(g),
                  _ => null,
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
            for (final s in g.steps)
              Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Row(
                  children: [
                    Checkbox(
                      visualDensity: VisualDensity.compact,
                      value: s.done,
                      onChanged: (v) => repo.setItemDone(g.id, s.id, v ?? false),
                    ),
                    Expanded(child: Text(s.title, style: doneStyle(s.done))),
                    if (dayOf(s.id) != null) Text(dayOf(s.id)!, style: theme.textTheme.bodySmall),
                    IconButton(
                      tooltip: 'Remove step',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => repo.deleteStep(s.id),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(52, 0, 12, 0),
              child: TextField(
                controller: stepCtrl,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: g.steps.isEmpty ? 'Too big? Split it: add a step' : 'Add a step',
                  prefixIcon: const Icon(Icons.subdirectory_arrow_right, size: 18),
                ),
                onSubmitted: (t) {
                  if (t.trim().isEmpty) return;
                  stepCtrl.clear();
                  repo.addStep(g.id, t);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _draftSection(WeekDraft draft) {
    final theme = Theme.of(context);
    return [
      const SizedBox(height: 16),
      Text('Week plan', style: theme.textTheme.titleMedium),
      Text(
        'Picked tasks, and where the rest would land at ${draft.perDay} a day. '
        'You still choose each evening on the Plan tab.',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      for (final e in draft.days.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 44,
                child: Text(
                  DateFormat('EEE').format(parseDateKey(e.key)),
                  style: TextStyle(fontWeight: e.key == repo.today ? FontWeight.bold : FontWeight.normal),
                ),
              ),
              Expanded(
                child: e.value.isEmpty
                    ? Text('—', style: theme.textTheme.bodySmall)
                    : Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final i in e.value)
                            Chip(
                              visualDensity: VisualDensity.compact,
                              avatar: draft.forecast.contains(i.key)
                                  ? const Icon(Icons.schedule, size: 14)
                                  : Icon(i.done ? Icons.check : Icons.push_pin, size: 14),
                              label: Text(
                                i.title,
                                style: TextStyle(fontSize: 12, color: priorityColor(context, i.priority)),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      if (draft.overflow.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          "Won't fit by Friday at your pace: ${draft.overflow.map((i) => i.title).join(', ')}",
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ],
    ];
  }
}

class _GoalDialog extends StatefulWidget {
  const _GoalDialog({this.initial});
  final Goal? initial;

  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  late final _title = TextEditingController(text: widget.initial?.title ?? '');
  late GoalKind _kind = widget.initial?.kind ?? GoalKind.task;
  late Priority _priority = widget.initial?.priority ?? Priority.medium;

  void _submit() {
    if (_title.text.trim().isEmpty) return;
    Navigator.pop(context, (title: _title.text, kind: _kind, priority: _priority));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'New goal' : 'Edit goal'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Goal', hintText: 'e.g. Finish lab report'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          SegmentedButton<GoalKind>(
            segments: const [
              ButtonSegment(value: GoalKind.task, label: Text('Task')),
              ButtonSegment(value: GoalKind.study, label: Text('Study')),
              ButtonSegment(value: GoalKind.action, label: Text('Action')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.single),
          ),
          const SizedBox(height: 12),
          const Text('Importance'),
          const SizedBox(height: 4),
          SegmentedButton<Priority>(
            segments: [for (final p in Priority.values) ButtonSegment(value: p, label: Text(p.label))],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.single),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

/// Friday evening: how far did each goal get, and how was the week overall?
class _ReviewPage extends StatefulWidget {
  const _ReviewPage({
    required this.repo,
    required this.week,
    required this.label,
    required this.goals,
    required this.existing,
  });

  final Repository repo;
  final String week;
  final String label;
  final List<Goal> goals;
  final WeekReview? existing;

  @override
  State<_ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<_ReviewPage> {
  late final Map<String, GoalRating> _ratings = {
    for (final g in widget.goals)
      g.id:
          g.rating ??
          (g.done
              ? GoalRating.done
              : g.unitsDone > 0
              ? GoalRating.partial
              : GoalRating.notDone),
  };
  late int? _score = widget.existing?.score;

  Future<void> _save() async {
    if (_score == null) return;
    await widget.repo.saveReview(widget.week, score: _score!, ratings: _ratings);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Review ${widget.label}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text('How much did you achieve this week?', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (var s = 1; s <= 5; s++)
                ChoiceChip(label: Text('$s'), selected: _score == s, onSelected: (_) => setState(() => _score = s)),
            ],
          ),
          Text('1 = hardly anything, 5 = everything I set out to do', style: theme.textTheme.bodySmall),
          const SizedBox(height: 20),
          Text('Each goal', style: theme.textTheme.titleMedium),
          for (final g in widget.goals)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(g.title)),
                      if (g.steps.isNotEmpty)
                        Text('${g.unitsDone}/${g.units} steps ', style: theme.textTheme.bodySmall),
                      PriorityTag(g.priority),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SegmentedButton<GoalRating>(
                    segments: [for (final r in GoalRating.values) ButtonSegment(value: r, label: Text(r.label))],
                    selected: {_ratings[g.id]!},
                    onSelectionChanged: (s) => setState(() => _ratings[g.id] = s.single),
                  ),
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'save_review',
        onPressed: _score == null ? null : _save,
        icon: const Icon(Icons.check),
        label: const Text('Save review'),
      ),
    );
  }
}
