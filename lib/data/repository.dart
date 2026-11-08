import 'dart:math' show max, pow;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'schema.dart';

String dateKey(DateTime local) =>
    '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';

/// Fixed-width UTC timestamp (always 6 fractional digits) so string order
/// equals time order — the sync cursor relies on that.
String isoUtc(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final frac = (u.millisecond * 1000 + u.microsecond).toString().padLeft(6, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}.${frac}Z';
}

DateTime parseDateKey(String key) {
  final p = key.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

String addDays(String key, int days) {
  final d = parseDateKey(key);
  return dateKey(DateTime(d.year, d.month, d.day + days));
}

/// All reads and writes go through here. Screens listen to [revision] and
/// reload whenever it changes.
const syncCursorKey = 'sync_cursor';

class SyncBatch {
  SyncBatch({required this.rows, required this.deletes, required this.cursor});
  final Map<String, List<Map<String, Object?>>> rows;
  final List<Map<String, Object?>> deletes;
  final String? cursor;

  bool get isEmpty => rows.isEmpty && deletes.isEmpty;
}

class Repository {
  Repository(this._db, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Database _db;
  final DateTime Function() _clock;
  final _uuid = const Uuid();
  final revision = ValueNotifier<int>(0);

  static Future<Repository> open(String path, {DatabaseFactory? factory, DateTime Function()? clock}) async {
    final db = await (factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async {
          for (final stmt in [...schemaV1, ...schemaV2, ...schemaV3]) {
            await db.execute(stmt);
          }
        },
        onUpgrade: (db, from, _) async {
          if (from < 2) {
            for (final stmt in schemaV2) {
              await db.execute(stmt);
            }
          }
          if (from < 3) {
            for (final stmt in schemaV3) {
              await db.execute(stmt);
            }
          }
        },
      ),
    );
    return Repository(db, clock: clock);
  }

  Future<void> close() => _db.close();

  DateTime get _now => _clock();
  String get _ts => isoUtc(_now);
  String get today => dateKey(_now);

  void _changed() => revision.value++;

  // ---------------------------------------------------------------- days

  Future<void> _ensureDay(DatabaseExecutor tx, String date) async {
    await tx.execute('INSERT OR IGNORE INTO day (date, created_at, updated_at) VALUES (?, ?, ?)', [date, _ts, _ts]);
  }

  /// Stamps `first_open_at` for today the first time the app is opened.
  Future<void> recordAppOpen() async {
    await _ensureDay(_db, today);
    await _db.execute('UPDATE day SET first_open_at = ?, updated_at = ? WHERE date = ? AND first_open_at IS NULL', [
      _ts,
      _ts,
      today,
    ]);
  }

  Future<DayPlan> loadDay(String date) async {
    final tasks = (await _db.query(
      'task',
      where: 'date = ?',
      whereArgs: [date],
      orderBy: 'created_at',
    )).map(Task.fromRow).toList();
    final study = (await _db.query(
      'study_item',
      where: 'date = ?',
      whereArgs: [date],
      orderBy: 'created_at',
    )).map(StudyItem.fromRow).toList();
    return DayPlan(
      date: date,
      mit: tasks.where((t) => t.type == TaskType.mit).firstOrNull,
      secondaries: tasks.where((t) => t.type == TaskType.secondary).toList(),
      study: study,
    );
  }

  /// Planning after 15:00, or once today already has an MIT, targets tomorrow.
  Future<String> defaultPlanDate() async {
    final todayPlan = await loadDay(today);
    if (todayPlan.mit == null && _now.hour < 15) return today;
    return addDays(today, 1);
  }

  // ---------------------------------------------------------------- planning

  /// Replaces the plan for [date] with the given drafts. Existing rows keep
  /// their ids (and timers/progress); rows missing from the drafts are deleted.
  Future<void> savePlan({
    required String date,
    required TaskDraft mit,
    List<TaskDraft> secondaries = const [],
    List<StudyDraft> study = const [],
  }) async {
    if (mit.title.trim().isEmpty) throw ArgumentError('MIT is required');
    if (secondaries.length > 2) throw ArgumentError('At most 2 secondary tasks');

    final ts = _ts;
    final nightBefore = today.compareTo(date) < 0 ? 1 : 0;

    await _db.transaction((tx) async {
      await _ensureDay(tx, date);
      await tx.execute('UPDATE day SET planned_at = COALESCE(planned_at, ?), updated_at = ? WHERE date = ?', [
        ts,
        ts,
        date,
      ]);

      // Deletes first so the secondary-count trigger sees the final state.
      final keepTasks = [mit.id, ...secondaries.map((s) => s.id)].whereType<String>().toList();
      await tx.delete(
        'task',
        where: 'date = ? AND id NOT IN (${_placeholders(keepTasks.length)})',
        whereArgs: [date, ...keepTasks],
      );
      final keepStudy = study.map((s) => s.id).whereType<String>().toList();
      await tx.delete(
        'study_item',
        where: 'date = ? AND id NOT IN (${_placeholders(keepStudy.length)})',
        whereArgs: [date, ...keepStudy],
      );

      Future<void> upsertTask(TaskDraft d, TaskType type) async {
        if (d.id != null) {
          await tx.update(
            'task',
            {
              'title': d.title.trim(),
              'category': d.category?.name,
              'goal_id': d.goalId,
              'step_id': d.stepId,
              'updated_at': ts,
            },
            where: 'id = ?',
            whereArgs: [d.id],
          );
        } else {
          await tx.insert('task', {
            'id': _uuid.v4(),
            'date': date,
            'type': type.name,
            'title': d.title.trim(),
            'category': d.category?.name,
            'goal_id': d.goalId,
            'step_id': d.stepId,
            'planned_the_night_before': nightBefore,
            'created_at': ts,
            'updated_at': ts,
          });
        }
      }

      await upsertTask(mit, TaskType.mit);
      for (final s in secondaries) {
        await upsertTask(s, TaskType.secondary);
      }

      for (final s in study) {
        final subject = s.subject.trim();
        if (s.id != null) {
          await tx.update(
            'study_item',
            {'subject': subject, 'work_to_do': s.workToDo.trim(), 'updated_at': ts},
            where: 'id = ?',
            whereArgs: [s.id],
          );
        } else {
          await tx.insert('study_item', {
            'id': _uuid.v4(),
            'date': date,
            'subject': subject,
            'work_to_do': s.workToDo.trim(),
            'planned_the_night_before': nightBefore,
            'created_at': ts,
            'updated_at': ts,
          });
        }
        await tx.execute(
          '''INSERT INTO subject (name, last_used, created_at, updated_at) VALUES (?, ?, ?, ?)
             ON CONFLICT(name) DO UPDATE SET
               last_used = MAX(COALESCE(last_used, ''), excluded.last_used),
               updated_at = excluded.updated_at''',
          [subject, date, ts, ts],
        );
      }
    });
    _changed();
  }

  /// Subjects ordered by most recently used, for the reusable chips.
  Future<List<String>> subjects() async {
    final rows = await _db.query('subject', columns: ['name'], orderBy: 'last_used DESC, name');
    return rows.map((r) => r['name'] as String).toList();
  }

  // ---------------------------------------------------------------- doing

  Future<void> setTaskDone(String id, bool done) async {
    await _db.transaction((tx) async {
      if (done) await _stopRunning(tx, onlyItem: id);
      await tx.update(
        'task',
        {'status': done ? 'done' : 'open', 'completed_at': done ? _ts : null, 'updated_at': _ts},
        where: 'id = ?',
        whereArgs: [id],
      );
      // A task picked from the weekly bucket ticks its goal or step too.
      final link = await tx.query('task', columns: ['goal_id', 'step_id'], where: 'id = ?', whereArgs: [id]);
      final goalId = link.firstOrNull?['goal_id'] as String?;
      if (goalId != null) await _setItemDone(tx, goalId, link.first['step_id'] as String?, done);
    });
    _changed();
  }

  Future<void> setStudyStatus(String id, StudyStatus status) async {
    await _db.transaction((tx) async {
      if (status == StudyStatus.done) await _stopRunning(tx, onlyItem: id);
      await tx.update('study_item', {'work_completed': status.db, 'updated_at': _ts}, where: 'id = ?', whereArgs: [id]);
    });
    _changed();
  }

  // ---------------------------------------------------------------- timers

  Future<RunningTimer?> runningTimer() async {
    final rows = await _db.query('time_session', where: 'ended_at IS NULL');
    if (rows.isEmpty) return null;
    final r = rows.first;
    final isTask = r['task_id'] != null;
    return RunningTimer(
      r['id'] as String,
      isTask ? ItemKind.task : ItemKind.study,
      (isTask ? r['task_id'] : r['study_item_id']) as String,
      DateTime.parse(r['started_at'] as String),
    );
  }

  /// Starts a timer on an item, stopping whatever was running before.
  Future<void> startTimer(ItemKind kind, String itemId) async {
    await _db.transaction((tx) async {
      await _stopRunning(tx);
      await tx.insert('time_session', {
        'id': _uuid.v4(),
        'task_id': kind == ItemKind.task ? itemId : null,
        'study_item_id': kind == ItemKind.study ? itemId : null,
        'started_at': _ts,
        'updated_at': _ts,
      });
    });
    _changed();
  }

  Future<void> stopTimer() async {
    await _db.transaction(_stopRunning);
    _changed();
  }

  /// Closes the running session and rolls its minutes into the item. Sessions
  /// under a minute are discarded rather than stored as zero.
  Future<void> _stopRunning(Transaction tx, {String? onlyItem}) async {
    final rows = await tx.query('time_session', where: 'ended_at IS NULL');
    if (rows.isEmpty) return;
    final r = rows.first;
    final taskId = r['task_id'] as String?;
    final studyId = r['study_item_id'] as String?;
    if (onlyItem != null && onlyItem != taskId && onlyItem != studyId) return;

    final started = DateTime.parse(r['started_at'] as String);
    final minutes = (_now.difference(started).inSeconds / 60).round();
    if (minutes <= 0) {
      await tx.delete('time_session', where: 'id = ?', whereArgs: [r['id']]);
      return;
    }
    await tx.update(
      'time_session',
      {'ended_at': _ts, 'minutes': minutes, 'updated_at': _ts},
      where: 'id = ?',
      whereArgs: [r['id']],
    );
    await _addMinutes(tx, taskId != null ? ItemKind.task : ItemKind.study, (taskId ?? studyId)!, minutes);
  }

  /// Manual adjustment for work done away from the timer. Negative values
  /// correct mistakes; totals never go below zero.
  Future<void> addManualMinutes(ItemKind kind, String itemId, int minutes) async {
    await _db.transaction((tx) => _addMinutes(tx, kind, itemId, minutes));
    _changed();
  }

  Future<void> _addMinutes(DatabaseExecutor tx, ItemKind kind, String id, int minutes) => tx.execute(
    'UPDATE ${kind == ItemKind.task ? 'task' : 'study_item'} '
    'SET time_spent_minutes = MAX(0, time_spent_minutes + ?), updated_at = ? WHERE id = ?',
    [minutes, _ts, id],
  );

  // ---------------------------------------------------------------- progress

  /// Heatmap levels for every date in [from, to] that has anything logged.
  Future<Map<String, DayLevel>> heatmap(String from, String to) async {
    final rows = await _db.rawQuery(
      '''
      SELECT date, MAX(CASE
          WHEN type = 'mit' AND status = 'done' THEN 3
          WHEN type = 'secondary' AND status = 'done' THEN 2
          ELSE 1 END) AS lvl
      FROM task WHERE date BETWEEN ? AND ? GROUP BY date
      UNION ALL
      SELECT DISTINCT date, 1 FROM study_item WHERE date BETWEEN ? AND ?
    ''',
      [from, to, from, to],
    );
    final out = <String, DayLevel>{};
    for (final r in rows) {
      final level = DayLevel.values[r['lvl'] as int];
      final date = r['date'] as String;
      final prev = out[date];
      if (prev == null || level.index > prev.index) out[date] = level;
    }
    return out;
  }

  /// Consecutive days with the MIT done, ending today (or yesterday if today
  /// isn't done yet, so the streak doesn't look broken mid-day).
  Future<int> mitStreak() async {
    final rows = await _db.query(
      'task',
      columns: ['date'],
      where: "type = 'mit' AND status = 'done'",
      orderBy: 'date DESC',
    );
    final done = rows.map((r) => r['date'] as String).toSet();
    var cursor = done.contains(today) ? today : addDays(today, -1);
    var streak = 0;
    while (done.contains(cursor)) {
      streak++;
      cursor = addDays(cursor, -1);
    }
    return streak;
  }

  /// MIT completion rate per weekday (1 = Monday) over the last [weeks] weeks.
  /// Descriptive only: `planned` is how many MITs existed that weekday.
  Future<Map<int, ({int planned, int done})>> mitByWeekday({int weeks = 12}) async {
    final rows = await _db.rawQuery("SELECT date, status FROM task WHERE type = 'mit' AND date BETWEEN ? AND ?", [
      addDays(today, -7 * weeks),
      today,
    ]);
    final out = {for (var d = 1; d <= 7; d++) d: (planned: 0, done: 0)};
    for (final r in rows) {
      final wd = parseDateKey(r['date'] as String).weekday;
      final prev = out[wd]!;
      out[wd] = (planned: prev.planned + 1, done: prev.done + (r['status'] == 'done' ? 1 : 0));
    }
    return out;
  }

  /// Subjects planned at least [minPlanned] times in the last [days] days
  /// without a single item marked done.
  Future<List<String>> neglectedSubjects({int days = 14, int minPlanned = 3}) async {
    final rows = await _db.rawQuery(
      """SELECT subject FROM study_item WHERE date BETWEEN ? AND ?
         GROUP BY subject
         HAVING COUNT(*) >= ? AND SUM(work_completed = 'done') = 0
         ORDER BY subject""",
      [addDays(today, -days), today, minPlanned],
    );
    return rows.map((r) => r['subject'] as String).toList();
  }

  /// Median minutes for completed tasks in [category] — the analysis found this
  /// simple rule estimates duration as well as the learned models did.
  Future<int?> typicalMinutes(Category? category) async {
    if (category == null) return null;
    final rows = await _db.query(
      'task',
      columns: ['time_spent_minutes'],
      where: "category = ? AND status = 'done' AND time_spent_minutes > 0",
      whereArgs: [category.name],
      orderBy: 'time_spent_minutes',
    );
    if (rows.length < 3) return null;
    return rows[rows.length ~/ 2]['time_spent_minutes'] as int;
  }

  // ---------------------------------------------------------------- deadlines

  Future<List<Deadline>> upcomingDeadlines() async {
    final rows = await _db.query('deadline', where: 'due_date >= ?', whereArgs: [today], orderBy: 'due_date');
    return rows.map(Deadline.fromRow).toList();
  }

  Future<void> addDeadline({required String title, required String dueDate, String? subject}) async {
    await _db.insert('deadline', {
      'id': _uuid.v4(),
      'title': title.trim(),
      'subject': (subject?.trim().isEmpty ?? true) ? null : subject!.trim(),
      'due_date': dueDate,
      'created_at': _ts,
      'updated_at': _ts,
    });
    _changed();
  }

  Future<void> deleteDeadline(String id) async {
    await _db.delete('deadline', where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  // ---------------------------------------------------------------- weekly goals

  /// Weeks run Sunday to Friday and are keyed by their Sunday. Saturday is the
  /// day off between weeks, so it already belongs to the coming week: goals
  /// set on a Saturday are for the next six days.
  static String weekStartOf(String date) {
    final d = parseDateKey(date);
    if (d.weekday == DateTime.saturday) return addDays(date, 1);
    return addDays(date, -(d.weekday % 7));
  }

  /// Sunday to Friday of the week starting [weekStart].
  static List<String> weekDays(String weekStart) => [for (var i = 0; i < 6; i++) addDays(weekStart, i)];

  String get currentWeek => weekStartOf(today);

  /// Goals for a week, highest priority first, each with its steps in order.
  Future<List<Goal>> loadWeek(String weekStart) => _goals(_db, weekStart);

  Future<List<Goal>> _goals(DatabaseExecutor tx, String weekStart) async {
    final rows = await tx.rawQuery(
      '''SELECT * FROM goal WHERE week_start = ?
         ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, created_at''',
      [weekStart],
    );
    if (rows.isEmpty) return [];
    final steps = await tx.rawQuery(
      'SELECT s.* FROM goal_step s JOIN goal g ON g.id = s.goal_id WHERE g.week_start = ? ORDER BY s.position',
      [weekStart],
    );
    final byGoal = <String, List<GoalStep>>{};
    for (final r in steps) {
      final step = GoalStep.fromRow(r);
      byGoal.putIfAbsent(step.goalId, () => []).add(step);
    }
    return [for (final r in rows) Goal.fromRow(r, byGoal[r['id']] ?? const [])];
  }

  Future<String> addGoal({
    required String weekStart,
    required String title,
    GoalKind kind = GoalKind.task,
    Priority priority = Priority.medium,
  }) async {
    if (title.trim().isEmpty) throw ArgumentError('A goal needs a title');
    final id = _uuid.v4();
    await _db.insert('goal', {
      'id': id,
      'week_start': weekStart,
      'title': title.trim(),
      'kind': kind.name,
      'priority': priority.name,
      'created_at': _ts,
      'updated_at': _ts,
    });
    _changed();
    return id;
  }

  Future<void> updateGoal(String id, {String? title, GoalKind? kind, Priority? priority}) async {
    if (title != null && title.trim().isEmpty) throw ArgumentError('A goal needs a title');
    await _db.update(
      'goal',
      {
        if (title != null) 'title': title.trim(),
        if (kind != null) 'kind': kind.name,
        if (priority != null) 'priority': priority.name,
        'updated_at': _ts,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  /// Deletes a goal and its steps. Tasks already picked from it stay, unlinked.
  Future<void> deleteGoal(String id) async {
    await _db.transaction((tx) async {
      await tx.update(
        'task',
        {'goal_id': null, 'step_id': null, 'updated_at': _ts},
        where: 'goal_id = ?',
        whereArgs: [id],
      );
      await tx.delete('goal', where: 'id = ?', whereArgs: [id]);
    });
    _changed();
  }

  /// Splits a goal: adds a step at the end.
  Future<void> addStep(String goalId, String title) async {
    if (title.trim().isEmpty) throw ArgumentError('A step needs a title');
    await _db.transaction((tx) async {
      final pos =
          Sqflite.firstIntValue(
            await tx.rawQuery('SELECT COALESCE(MAX(position), -1) + 1 FROM goal_step WHERE goal_id = ?', [goalId]),
          ) ??
          0;
      await tx.insert('goal_step', {
        'id': _uuid.v4(),
        'goal_id': goalId,
        'position': pos,
        'title': title.trim(),
        'created_at': _ts,
        'updated_at': _ts,
      });
      await _refreshGoalStatus(tx, goalId);
    });
    _changed();
  }

  Future<void> deleteStep(String stepId) async {
    await _db.transaction((tx) async {
      final rows = await tx.query('goal_step', columns: ['goal_id'], where: 'id = ?', whereArgs: [stepId]);
      if (rows.isEmpty) return;
      await tx.update('task', {'step_id': null, 'updated_at': _ts}, where: 'step_id = ?', whereArgs: [stepId]);
      await tx.delete('goal_step', where: 'id = ?', whereArgs: [stepId]);
      await _refreshGoalStatus(tx, rows.first['goal_id'] as String);
    });
    _changed();
  }

  /// Ticks a bucket item directly (e.g. it got done without being planned).
  Future<void> setItemDone(String goalId, String? stepId, bool done) async {
    await _db.transaction((tx) => _setItemDone(tx, goalId, stepId, done));
    _changed();
  }

  Future<void> _setItemDone(DatabaseExecutor tx, String goalId, String? stepId, bool done) async {
    final status = done ? 'done' : 'open';
    if (stepId != null) {
      await tx.update('goal_step', {'status': status, 'updated_at': _ts}, where: 'id = ?', whereArgs: [stepId]);
      await _refreshGoalStatus(tx, goalId);
    } else {
      await tx.update(
        'goal',
        {'status': status, 'updated_at': _ts},
        where: 'id = ? AND status != ?',
        whereArgs: [goalId, status],
      );
    }
  }

  /// A goal with steps is done exactly when all its steps are.
  Future<void> _refreshGoalStatus(DatabaseExecutor tx, String goalId) async {
    final r = (await tx.rawQuery(
      "SELECT COUNT(*) AS n, COALESCE(SUM(status = 'done'), 0) AS d FROM goal_step WHERE goal_id = ?",
      [goalId],
    )).first;
    final n = r['n'] as int;
    if (n == 0) return;
    final status = r['d'] == n ? 'done' : 'open';
    await tx.update(
      'goal',
      {'status': status, 'updated_at': _ts},
      where: 'id = ? AND status != ?',
      whereArgs: [goalId, status],
    );
  }

  /// Open bucket items of [goals], in recommendation order: priority first,
  /// then each goal's next step before anyone's second step (so one big goal
  /// doesn't crowd out the others at the same priority), then goal age.
  List<BucketItem> _rank(List<Goal> goals, Map<String, String> scheduled) {
    final ranked = <(int, int, int, BucketItem)>[];
    for (final (gi, g) in goals.indexed) {
      if (g.steps.isEmpty) {
        if (!g.done) ranked.add((-g.priority.weight, 0, gi, BucketItem(goal: g, scheduledFor: scheduled[g.id])));
        continue;
      }
      var rank = 0;
      for (final s in g.steps) {
        if (s.done) continue;
        ranked.add((-g.priority.weight, rank++, gi, BucketItem(goal: g, step: s, scheduledFor: scheduled[s.id])));
      }
    }
    ranked.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      if (c != 0) return c;
      final r = a.$2.compareTo(b.$2);
      return r != 0 ? r : a.$3.compareTo(b.$3);
    });
    return [for (final r in ranked) r.$4];
  }

  /// Item key -> date of the open task holding it, for tasks from today on.
  Future<Map<String, String>> _scheduledItems(String weekStart) async {
    final rows = await _db.rawQuery(
      '''SELECT t.date, t.goal_id, t.step_id FROM task t JOIN goal g ON g.id = t.goal_id
         WHERE g.week_start = ? AND t.status = 'open' AND t.date >= ?''',
      [weekStart, today],
    );
    return {for (final r in rows) (r['step_id'] ?? r['goal_id']) as String: r['date'] as String};
  }

  /// The bucket as seen when planning [date]: open items of that date's week
  /// that aren't already planned for another day, best first. The first
  /// [Capacity.perDay] are the suggestion; the person picks.
  Future<({List<BucketItem> items, Set<String> suggested})> bucket(String date) async {
    final week = weekStartOf(date);
    final goals = await loadWeek(week);
    final items = _rank(
      goals,
      await _scheduledItems(week),
    ).where((i) => i.scheduledFor == null || i.scheduledFor == date).toList();
    final perDay = (await capacity()).perDay;
    return (items: items, suggested: items.take(perDay).map((i) => i.key).toSet());
  }

  /// The week laid out day by day: what's already planned on each day, and,
  /// from the next day still to be planned, the remaining items spread at the
  /// learned daily pace. Whatever doesn't fit by Friday is `overflow`;
  /// `forecast` holds the keys of items placed by the app rather than picked.
  Future<WeekDraft> weekDraft(String weekStart) async {
    final goals = await loadWeek(weekStart);
    final byKey = <String, BucketItem>{};
    for (final g in goals) {
      if (g.steps.isEmpty) byKey[g.id] = BucketItem(goal: g);
      for (final s in g.steps) {
        byKey[s.id] = BucketItem(goal: g, step: s);
      }
    }
    final days = {for (final d in weekDays(weekStart)) d: <BucketItem>[]};
    final picked = await _db.rawQuery(
      '''SELECT t.date, t.goal_id, t.step_id FROM task t JOIN goal g ON g.id = t.goal_id
         WHERE g.week_start = ? ORDER BY t.date, t.type, t.created_at''',
      [weekStart],
    );
    for (final r in picked) {
      final item = byKey[(r['step_id'] ?? r['goal_id']) as String];
      if (item != null && days.containsKey(r['date'])) days[r['date']]!.add(item);
    }

    final queue = _rank(goals, await _scheduledItems(weekStart)).where((i) => i.scheduledFor == null).toList();
    final perDay = (await capacity()).perDay;
    final firstOpen = await defaultPlanDate();
    final forecast = <String>{};
    for (final d in days.keys) {
      if (d.compareTo(firstOpen) < 0) continue;
      while (days[d]!.length < perDay && queue.isNotEmpty) {
        final item = queue.removeAt(0);
        days[d]!.add(item);
        forecast.add(item.key);
      }
    }
    return WeekDraft(days: days, overflow: queue, forecast: forecast, perDay: perDay);
  }

  /// Weeks before the current one, newest first, with how many items were
  /// planned and how many were achieved. The Friday rating counts: a goal
  /// rated "done" counts in full even if its steps weren't ticked, "partly"
  /// counts at least half.
  Future<List<WeekResult>> weekHistory({int weeks = 12}) async {
    final rows = await _db.rawQuery(
      'SELECT DISTINCT week_start FROM goal WHERE week_start < ? ORDER BY week_start DESC LIMIT ?',
      [currentWeek, weeks],
    );
    final out = <WeekResult>[];
    for (final r in rows) {
      final week = r['week_start'] as String;
      var planned = 0;
      var achieved = 0.0;
      for (final g in await loadWeek(week)) {
        planned += g.units;
        achieved += switch (g.rating) {
          GoalRating.done => g.units.toDouble(),
          GoalRating.partial => max(g.unitsDone.toDouble(), g.units / 2),
          _ => g.unitsDone.toDouble(),
        };
      }
      out.add(WeekResult(week: week, planned: planned, achieved: achieved));
    }
    return out;
  }

  /// Prior belief about items per week before there is any history, and how
  /// many weeks of evidence it is worth.
  static const capacityPrior = 12.0;
  static const capacityPriorWeeks = 2.0;

  /// How many items a week actually get done: a recency-weighted average of
  /// past weeks (each week back counts 0.8 as much), shrunk towards
  /// [capacityPrior] while history is short. With one data point per week a
  /// richer model would only fit noise; this is the honest estimate until
  /// there are a few months of weeks.
  ///
  /// A week where everything planned got done only says capacity was *at
  /// least* that much, so it counts as one item more.
  Future<Capacity> capacity() async {
    final history = await weekHistory();
    var weighted = capacityPrior * capacityPriorWeeks;
    var weights = capacityPriorWeeks;
    var planned = 0;
    var achieved = 0.0;
    for (final (i, w) in history.indexed) {
      if (w.planned == 0) continue;
      final weight = pow(0.8, i).toDouble();
      weighted += weight * (w.achieved >= w.planned ? w.achieved + 1 : w.achieved);
      weights += weight;
      planned += w.planned;
      achieved += w.achieved;
    }
    return Capacity(
      itemsPerWeek: weighted / weights,
      weeksObserved: history.length,
      recentRate: planned == 0 ? null : achieved / planned,
    );
  }

  /// The week that should be rated now, if any: this week from Friday 15:00,
  /// the week just ended on Saturday, or last week if its review was missed.
  Future<String?> weekToReview() async {
    final wd = _now.weekday;
    final String week;
    if (wd == DateTime.friday && _now.hour >= 15) {
      week = currentWeek;
    } else if (wd == DateTime.saturday) {
      week = addDays(today, -6);
    } else if (wd == DateTime.friday) {
      return null;
    } else {
      week = addDays(currentWeek, -7);
    }
    final goals = Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM goal WHERE week_start = ?', [week]));
    if (goals == 0) return null;
    return await reviewFor(week) == null ? week : null;
  }

  Future<WeekReview?> reviewFor(String weekStart) async {
    final rows = await _db.query('week_review', where: 'week_start = ?', whereArgs: [weekStart]);
    if (rows.isEmpty) return null;
    return WeekReview(weekStart: weekStart, score: rows.first['score'] as int);
  }

  /// Friday evening: an overall 1-5 score and how far each goal got.
  Future<void> saveReview(String weekStart, {required int score, required Map<String, GoalRating> ratings}) async {
    if (score < 1 || score > 5) throw ArgumentError('Score is 1 to 5');
    await _db.transaction((tx) async {
      await tx.execute(
        '''INSERT INTO week_review (week_start, score, reviewed_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(week_start) DO UPDATE SET score = excluded.score, reviewed_at = excluded.reviewed_at,
             updated_at = excluded.updated_at''',
        [weekStart, score, _ts, _ts, _ts],
      );
      for (final e in ratings.entries) {
        await tx.update(
          'goal',
          {'rating': e.value.db, 'updated_at': _ts},
          where: 'id = ? AND week_start = ?',
          whereArgs: [e.key, weekStart],
        );
      }
    });
    _changed();
  }

  /// Copies unfinished goals (with only their open steps) from [fromWeek] into
  /// [toWeek]. Goals whose title already exists there are skipped, so running
  /// it twice is harmless. Returns how many goals were copied.
  Future<int> carryOver(String fromWeek, String toWeek) async {
    final existing = {for (final g in await loadWeek(toWeek)) g.title.toLowerCase()};
    var n = 0;
    await _db.transaction((tx) async {
      for (final g in await _goals(tx, fromWeek)) {
        if (g.done || existing.contains(g.title.toLowerCase())) continue;
        final id = _uuid.v4();
        await tx.insert('goal', {
          'id': id,
          'week_start': toWeek,
          'title': g.title,
          'kind': g.kind.name,
          'priority': g.priority.name,
          'created_at': _ts,
          'updated_at': _ts,
        });
        var pos = 0;
        for (final s in g.steps.where((s) => !s.done)) {
          await tx.insert('goal_step', {
            'id': _uuid.v4(),
            'goal_id': id,
            'position': pos++,
            'title': s.title,
            'created_at': _ts,
            'updated_at': _ts,
          });
        }
        n++;
      }
    });
    if (n > 0) _changed();
    return n;
  }

  // ---------------------------------------------------------------- sync

  /// Rows changed after [cursor] (an `updated_at` value), plus pending deletes.
  Future<SyncBatch> pendingChanges(String? cursor) async {
    final rows = <String, List<Map<String, Object?>>>{};
    var maxUpdated = cursor;
    for (final table in syncedTables.keys) {
      final r = await _db.query(
        table,
        where: cursor == null ? null : 'updated_at > ?',
        whereArgs: cursor == null ? null : [cursor],
      );
      if (r.isEmpty) continue;
      rows[table] = r;
      for (final row in r) {
        final u = row['updated_at'] as String;
        if (maxUpdated == null || u.compareTo(maxUpdated) > 0) maxUpdated = u;
      }
    }
    final deletes = await _db.query('tombstone');
    return SyncBatch(rows: rows, deletes: deletes, cursor: maxUpdated);
  }

  /// Called after the server accepted [batch].
  Future<void> markPushed(SyncBatch batch) async {
    await _db.transaction((tx) async {
      for (final d in batch.deletes) {
        await tx.delete(
          'tombstone',
          where: 'entity = ? AND key = ? AND deleted_at = ?',
          whereArgs: [d['entity'], d['key'], d['deleted_at']],
        );
      }
      if (batch.cursor != null) {
        await tx.insert('setting', {
          'key': syncCursorKey,
          'value': batch.cursor,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<bool> hasAnyPlans() async => Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM task')) != 0;

  /// Loads a full server snapshot into an empty database (new phone).
  Future<int> restore(Map<String, List<Map<String, Object?>>> snapshot) async {
    if (await hasAnyPlans()) throw StateError('Restore only works on an empty database');
    var n = 0;
    await _db.transaction((tx) async {
      for (final table in syncedTables.keys) {
        for (final row in snapshot[table] ?? const []) {
          await tx.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
          n++;
        }
      }
      String? max;
      for (final rows in snapshot.values) {
        for (final r in rows) {
          final u = r['updated_at'] as String?;
          if (u != null && (max == null || u.compareTo(max) > 0)) max = u;
        }
      }
      if (max != null) {
        await tx.insert('setting', {'key': syncCursorKey, 'value': max}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await tx.delete('tombstone');
    });
    _changed();
    return n;
  }

  // ---------------------------------------------------------------- settings

  Future<String?> getSetting(String key) async {
    final rows = await _db.query('setting', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    await _db.insert('setting', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static String _placeholders(int n) => n == 0 ? "''" : List.filled(n, '?').join(', ');
}
