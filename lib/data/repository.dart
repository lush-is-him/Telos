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
          for (final stmt in [...schemaV1, ...schemaV2]) {
            await db.execute(stmt);
          }
        },
        onUpgrade: (db, from, _) async {
          if (from < 2) {
            for (final stmt in schemaV2) {
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
            {'title': d.title.trim(), 'category': d.category?.name, 'updated_at': ts},
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
