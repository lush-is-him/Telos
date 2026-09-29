import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/models.dart';
import '../data/repository.dart';

/// Evening planning: one MIT, up to two secondaries, any study items.
/// Kept to a single page so it takes ~20 seconds.
class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key, required this.repo, required this.requests, required this.onSaved});

  final Repository repo;

  /// Bumped when the app wants this screen reset to its default date
  /// (e.g. the nightly notification was tapped).
  final ValueListenable<int> requests;
  final ValueChanged<String> onSaved;

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _TaskRow {
  _TaskRow({this.id, String title = '', this.category}) : title = TextEditingController(text: title);
  final String? id;
  final TextEditingController title;
  Category? category;
}

class _StudyRow {
  _StudyRow({this.id, required this.subject, String work = ''}) : work = TextEditingController(text: work);
  final String? id;
  final String subject;
  final TextEditingController work;
}

class _PlanScreenState extends State<PlanScreen> {
  String? _date;
  _TaskRow _mit = _TaskRow();
  List<_TaskRow> _secondaries = [_TaskRow(), _TaskRow()];
  List<_StudyRow> _study = [];
  List<String> _subjects = [];
  final _newSubject = TextEditingController();
  bool _saving = false;

  Repository get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    widget.requests.addListener(_resetToDefault);
    _resetToDefault();
  }

  @override
  void dispose() {
    widget.requests.removeListener(_resetToDefault);
    super.dispose();
  }

  Future<void> _resetToDefault() async => _loadDate(await repo.defaultPlanDate());

  Future<void> _loadDate(String date) async {
    final plan = await repo.loadDay(date);
    final subjects = await repo.subjects();
    if (!mounted) return;
    setState(() {
      _date = date;
      _subjects = subjects;
      _mit = _TaskRow(id: plan.mit?.id, title: plan.mit?.title ?? '', category: plan.mit?.category);
      _secondaries = [
        for (final t in plan.secondaries) _TaskRow(id: t.id, title: t.title, category: t.category),
        for (var i = plan.secondaries.length; i < 2; i++) _TaskRow(),
      ];
      _study = [for (final s in plan.study) _StudyRow(id: s.id, subject: s.subject, work: s.workToDo)];
    });
  }

  void _addStudy(String subject) {
    subject = subject.trim();
    if (subject.isEmpty) return;
    setState(() {
      _study.add(_StudyRow(subject: subject));
      if (!_subjects.contains(subject)) _subjects.insert(0, subject);
    });
    _newSubject.clear();
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_mit.title.text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Name your most important task first.')));
      return;
    }
    final date = _date!;
    setState(() => _saving = true);
    try {
      await repo.savePlan(
        date: date,
        mit: TaskDraft(id: _mit.id, title: _mit.title.text, category: _mit.category),
        secondaries: [
          for (final s in _secondaries)
            if (s.title.text.trim().isNotEmpty) TaskDraft(id: s.id, title: s.title.text, category: s.category),
        ],
        study: [
          for (final s in _study)
            if (s.work.text.trim().isNotEmpty) StudyDraft(id: s.id, subject: s.subject, workToDo: s.work.text),
        ],
      );
      await _loadDate(date);
      messenger.showSnackBar(SnackBar(content: Text('Saved plan for ${_label(date)}.')));
      widget.onSaved(date);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _label(String date) {
    if (date == repo.today) return 'today';
    if (date == addDays(repo.today, 1)) return 'tomorrow';
    return DateFormat('EEE d MMM').format(parseDateKey(date));
  }

  @override
  Widget build(BuildContext context) {
    final date = _date;
    if (date == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final today = repo.today;
    final tomorrow = addDays(today, 1);

    return Scaffold(
      appBar: AppBar(title: const Text('Plan')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: today, label: const Text('Today')),
              ButtonSegment(value: tomorrow, label: const Text('Tomorrow')),
            ],
            selected: {date},
            onSelectionChanged: (s) => _loadDate(s.single),
          ),
          const SizedBox(height: 20),
          _taskField(_mit, label: 'Most important task'),
          const SizedBox(height: 16),
          for (final (i, row) in _secondaries.indexed) ...[
            _taskField(row, label: 'Optional task ${i + 1}'),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 8),
          Text('Study', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final s in _subjects)
                ActionChip(label: Text(s), avatar: const Icon(Icons.add, size: 16), onPressed: () => _addStudy(s)),
              SizedBox(
                width: 160,
                child: TextField(
                  controller: _newSubject,
                  decoration: const InputDecoration(hintText: 'New subject', isDense: true),
                  textCapitalization: TextCapitalization.words,
                  onSubmitted: _addStudy,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final row in _study)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: row.work,
                autofocus: row.id == null,
                decoration: InputDecoration(
                  labelText: row.subject,
                  hintText: 'Work to do, e.g. Chapter 4 exercises',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _study.remove(row)),
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving ? null : _save,
        icon: const Icon(Icons.check),
        label: Text('Save for ${_label(date)}'),
      ),
    );
  }

  Widget _taskField(_TaskRow row, {required String label}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: row.title,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final c in Category.values)
              ChoiceChip(
                label: Text(c.name),
                visualDensity: VisualDensity.compact,
                selected: row.category == c,
                onSelected: (sel) => setState(() => row.category = sel ? c : null),
              ),
          ],
        ),
      ],
    );
  }
}
