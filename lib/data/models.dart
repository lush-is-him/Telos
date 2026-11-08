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
    this.goalId,
    this.stepId,
  });

  final String id;
  final String date;
  final TaskType type;
  final String? goalId;
  final String? stepId;
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
    goalId: r['goal_id'] as String?,
    stepId: r['step_id'] as String?,
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
  TaskDraft({this.id, required this.title, this.category, this.goalId, this.stepId});
  final String? id;
  final String title;
  final Category? category;

  /// Set when the task was picked from the weekly bucket.
  final String? goalId;
  final String? stepId;
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

// ------------------------------------------------------------------ weekly goals

enum Priority {
  high(3),
  medium(2),
  low(1);

  const Priority(this.weight);
  final int weight;

  String get label => '${name[0].toUpperCase()}${name.substring(1)}';
}

enum GoalKind {
  task(Category.project),
  study(Category.study),
  action(Category.admin);

  const GoalKind(this.category);

  /// The category a picked task gets, so existing analysis keeps working.
  final Category category;
}

/// The Friday answer for one goal.
enum GoalRating {
  done('done', 'Done'),
  partial('partial', 'Partly'),
  notDone('not_done', 'Not done');

  const GoalRating(this.db, this.label);
  final String db;
  final String label;

  static GoalRating? fromDb(Object? s) => s == null ? null : values.firstWhere((v) => v.db == s);
}

class GoalStep {
  GoalStep({required this.id, required this.goalId, required this.position, required this.title, this.done = false});
  final String id;
  final String goalId;
  final int position;
  final String title;
  final bool done;

  factory GoalStep.fromRow(Map<String, Object?> r) => GoalStep(
    id: r['id'] as String,
    goalId: r['goal_id'] as String,
    position: r['position'] as int,
    title: r['title'] as String,
    done: r['status'] == 'done',
  );
}

class Goal {
  Goal({
    required this.id,
    required this.weekStart,
    required this.title,
    required this.kind,
    required this.priority,
    this.done = false,
    this.rating,
    this.steps = const [],
  });

  final String id;
  final String weekStart;
  final String title;
  final GoalKind kind;
  final Priority priority;
  final bool done;
  final GoalRating? rating;
  final List<GoalStep> steps;

  /// How many bucket items this goal contributes: its steps, or itself.
  int get units => steps.isEmpty ? 1 : steps.length;
  int get unitsDone => steps.isEmpty ? (done ? 1 : 0) : steps.where((s) => s.done).length;

  factory Goal.fromRow(Map<String, Object?> r, List<GoalStep> steps) => Goal(
    id: r['id'] as String,
    weekStart: r['week_start'] as String,
    title: r['title'] as String,
    kind: GoalKind.values.byName(r['kind'] as String),
    priority: Priority.values.byName(r['priority'] as String),
    done: r['status'] == 'done',
    rating: GoalRating.fromDb(r['rating']),
    steps: steps,
  );
}

/// One pickable thing in the bucket: a step, or a goal that has no steps.
class BucketItem {
  BucketItem({required this.goal, this.step, this.scheduledFor});
  final Goal goal;
  final GoalStep? step;

  /// Date of an open task already holding this item, if any.
  final String? scheduledFor;

  String? get stepId => step?.id;
  String get key => step?.id ?? goal.id;
  Priority get priority => goal.priority;
  bool get done => step?.done ?? goal.done;

  /// Title used when picked into a day: "Goal: step" for steps.
  String get title => step == null ? goal.title : '${goal.title}: ${step!.title}';
}

/// What the app has learned about how much gets done in a week.
class Capacity {
  Capacity({required this.itemsPerWeek, required this.weeksObserved, this.recentRate});

  /// Expected bucket items finished per week (shrunk towards a prior while
  /// there is little history).
  final double itemsPerWeek;
  final int weeksObserved;

  /// Share of planned items finished over the observed weeks.
  final double? recentRate;

  /// Six working days (Sunday to Friday); suggest at most three a day, the
  /// size of a day's plan.
  int get perDay => (itemsPerWeek / 6).round().clamp(1, 3);
}

class WeekReview {
  WeekReview({required this.weekStart, required this.score});
  final String weekStart;
  final int score;
}

/// One past week: bucket items planned and achieved (rating-adjusted).
class WeekResult {
  WeekResult({required this.week, required this.planned, required this.achieved});
  final String week;
  final int planned;
  final double achieved;
}

/// The week laid out Sunday to Friday.
class WeekDraft {
  WeekDraft({required this.days, required this.overflow, required this.forecast, required this.perDay});

  /// Date -> items on that day: picked ones, then ones the app placed.
  final Map<String, List<BucketItem>> days;

  /// Items that don't fit by Friday at the learned pace.
  final List<BucketItem> overflow;

  /// Keys of items placed by the app (not yet picked into a day).
  final Set<String> forecast;
  final int perDay;
}
