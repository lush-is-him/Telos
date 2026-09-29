enum TaskType { mit, secondary }

enum Category { study, project, admin, other }

enum StudyStatus {
  notStarted('not_started', 'Not started'),
  partial('partial', 'Partial'),
  done('done', 'Done');

  const StudyStatus(this.db, this.label);
  final String db;
  final String label;

  static StudyStatus fromDb(String s) => values.firstWhere((v) => v.db == s);
}

/// What a timer is attached to.
enum ItemKind { task, study }

class Task {
  Task({
    required this.id,
    required this.date,
    required this.type,
    required this.title,
    this.category,
    this.done = false,
    this.completedAt,
    this.timeSpentMinutes = 0,
    this.plannedTheNightBefore = false,
  });

  final String id;
  final String date;
  final TaskType type;
  final String title;
  final Category? category;
  final bool done;
  final DateTime? completedAt;
  final int timeSpentMinutes;
  final bool plannedTheNightBefore;

  factory Task.fromRow(Map<String, Object?> r) => Task(
    id: r['id'] as String,
    date: r['date'] as String,
    type: TaskType.values.byName(r['type'] as String),
    title: r['title'] as String,
    category: r['category'] == null ? null : Category.values.byName(r['category'] as String),
    done: r['status'] == 'done',
    completedAt: r['completed_at'] == null ? null : DateTime.parse(r['completed_at'] as String),
    timeSpentMinutes: r['time_spent_minutes'] as int,
    plannedTheNightBefore: r['planned_the_night_before'] == 1,
  );
}

class StudyItem {
  StudyItem({
    required this.id,
    required this.date,
    required this.subject,
    required this.workToDo,
    this.status = StudyStatus.notStarted,
    this.timeSpentMinutes = 0,
    this.plannedTheNightBefore = false,
  });

  final String id;
  final String date;
  final String subject;
  final String workToDo;
  final StudyStatus status;
  final int timeSpentMinutes;
  final bool plannedTheNightBefore;

  factory StudyItem.fromRow(Map<String, Object?> r) => StudyItem(
    id: r['id'] as String,
    date: r['date'] as String,
    subject: r['subject'] as String,
    workToDo: r['work_to_do'] as String,
    status: StudyStatus.fromDb(r['work_completed'] as String),
    timeSpentMinutes: r['time_spent_minutes'] as int,
    plannedTheNightBefore: r['planned_the_night_before'] == 1,
  );
}

class RunningTimer {
  RunningTimer(this.sessionId, this.kind, this.itemId, this.startedAt);
  final String sessionId;
  final ItemKind kind;
  final String itemId;
  final DateTime startedAt;
}

class DayPlan {
  DayPlan({required this.date, this.mit, this.secondaries = const [], this.study = const []});

  final String date;
  final Task? mit;
  final List<Task> secondaries;
  final List<StudyItem> study;

  bool get isEmpty => mit == null && secondaries.isEmpty && study.isEmpty;
}

/// Draft rows coming out of the Plan screen. A null id means "new".
class TaskDraft {
  TaskDraft({this.id, required this.title, this.category});
  final String? id;
  final String title;
  final Category? category;
}

class StudyDraft {
  StudyDraft({this.id, required this.subject, required this.workToDo});
  final String? id;
  final String subject;
  final String workToDo;
}

/// Heatmap cell intensity. Derived, never stored.
enum DayLevel { none, logged, secondaryDone, mitDone }

class Deadline {
  Deadline({required this.id, required this.title, required this.dueDate, this.subject});
  final String id;
  final String title;
  final String dueDate;
  final String? subject;

  factory Deadline.fromRow(Map<String, Object?> r) => Deadline(
    id: r['id'] as String,
    title: r['title'] as String,
    dueDate: r['due_date'] as String,
    subject: r['subject'] as String?,
  );
}
