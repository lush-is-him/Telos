import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telos/data/models.dart';
import 'package:telos/data/repository.dart';
import 'package:telos/services/sync.dart';

/// A second, separate phone database (in-memory paths are shared, so use a file).
Future<Repository> _freshPhone(DateTime Function() clock) async {
  final path = '${Directory.systemTemp.createTempSync('telos').path}/phone2.db';
  return Repository.open(path, factory: databaseFactoryFfi, clock: clock);
}

void main() {
  sqfliteFfiInit();
  late DateTime now;
  late Repository repo;

  setUp(() async {
    now = DateTime(2026, 9, 29, 21, 0);
    repo = await Repository.open(inMemoryDatabasePath, factory: databaseFactoryFfi, clock: () => now);
  });
  tearDown(() => repo.close());

  test('pending changes: first push sends everything, then only what changed', () async {
    await repo.savePlan(
      date: '2026-09-30',
      mit: TaskDraft(title: 'A'),
      secondaries: [TaskDraft(title: 'B')],
    );
    var batch = await repo.pendingChanges(null);
    expect(batch.rows.keys, containsAll(['day', 'task']));
    expect(batch.rows['task'], hasLength(2));
    await repo.markPushed(batch);

    now = now.add(const Duration(minutes: 1));
    final plan = await repo.loadDay('2026-09-30');
    await repo.setTaskDone(plan.mit!.id, true);
    batch = await repo.pendingChanges(await repo.getSetting(syncCursorKey));
    expect(batch.rows.keys, ['task']);
    expect(batch.rows['task']!.single['id'], plan.mit!.id);
  });

  test('deletes become tombstones until pushed', () async {
    await repo.savePlan(date: '2026-09-30', mit: TaskDraft(title: 'A'), secondaries: [TaskDraft(title: 'B')]);
    final plan = await repo.loadDay('2026-09-30');
    await repo.savePlan(date: '2026-09-30', mit: TaskDraft(id: plan.mit!.id, title: 'A'));

    final batch = await repo.pendingChanges(null);
    expect(batch.deletes.single['key'], plan.secondaries.single.id);
    await repo.markPushed(batch);
    expect((await repo.pendingChanges(batch.cursor)).deletes, isEmpty);
  });

  test('timestamps are fixed width so string order is time order', () {
    final a = isoUtc(DateTime.utc(2026, 9, 29, 10, 0, 0, 123));
    final b = isoUtc(DateTime.utc(2026, 9, 29, 10, 0, 0, 123, 456));
    expect(a, '2026-09-29T10:00:00.123000Z');
    expect(a.compareTo(b), lessThan(0));
  });

  test('push posts rows with bearer token and advances the cursor', () async {
    await repo.setSetting(serverUrlKey, 'http://pc:8000');
    await repo.setSetting(serverTokenKey, 'secret');
    await repo.savePlan(date: '2026-09-30', mit: TaskDraft(title: 'A'));

    late Map<String, dynamic> sent;
    final client = MockClient((req) async {
      expect(req.url.toString(), 'http://pc:8000/sync/push');
      expect(req.headers['Authorization'], 'Bearer secret');
      sent = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('{"ok": true}', 200);
    });
    expect(await SyncService(repo, client: client).push(), isNull);
    expect((sent['rows'] as Map)['task'], hasLength(1));
    expect(await repo.getSetting(syncCursorKey), isNotNull);
  });

  test('failed push keeps changes queued', () async {
    await repo.setSetting(serverUrlKey, 'http://pc:8000');
    await repo.setSetting(serverTokenKey, 'secret');
    await repo.savePlan(date: '2026-09-30', mit: TaskDraft(title: 'A'));
    final client = MockClient((_) async => http.Response('down', 503));
    expect(await SyncService(repo, client: client).push(), contains('503'));
    expect(await repo.getSetting(syncCursorKey), isNull);
    expect((await repo.pendingChanges(null)).rows['task'], hasLength(1));
  });

  test('descriptive stats: weekday rates, neglected subjects, typical minutes', () async {
    for (var i = 0; i < 4; i++) {
      final date = addDays('2026-09-21', i); // Mon..Thu
      await repo.savePlan(
        date: date,
        mit: TaskDraft(title: 'M', category: Category.project),
        study: [StudyDraft(subject: 'Stats', workToDo: 'Ex $i')],
      );
      final plan = await repo.loadDay(date);
      if (i.isEven) await repo.setTaskDone(plan.mit!.id, true);
      await repo.addManualMinutes(ItemKind.task, plan.mit!.id, 30 + i * 10);
    }
    final wd = await repo.mitByWeekday();
    expect(wd[1], (planned: 1, done: 1));
    expect(wd[2], (planned: 1, done: 0));
    expect(await repo.neglectedSubjects(), ['Stats']);
    expect(await repo.typicalMinutes(Category.project), isNull); // only 2 done
  });

  // Runs against a live server: TELOS_SERVER=http://127.0.0.1:8765 TELOS_TOKEN=... flutter test test/sync_test.dart
  final server = Platform.environment['TELOS_SERVER'];
  test('integration: push, edit, delete, then restore a new phone', () async {
    await repo.setSetting(serverUrlKey, server!);
    await repo.setSetting(serverTokenKey, Platform.environment['TELOS_TOKEN']!);
    final sync = SyncService(repo);
    expect(await sync.ping(), isTrue);

    await repo.savePlan(
      date: '2026-09-30',
      mit: TaskDraft(title: 'Write intro', category: Category.project),
      secondaries: [TaskDraft(title: 'Email'), TaskDraft(title: 'Gym')],
      study: [StudyDraft(subject: 'Maths', workToDo: 'Ch 4')],
    );
    expect(await sync.push(), isNull);

    now = now.add(const Duration(hours: 12));
    var plan = await repo.loadDay('2026-09-30');
    await repo.startTimer(ItemKind.task, plan.mit!.id);
    now = now.add(const Duration(minutes: 42));
    await repo.setTaskDone(plan.mit!.id, true);
    await repo.savePlan(
      date: '2026-09-30',
      mit: TaskDraft(id: plan.mit!.id, title: 'Write intro'),
      secondaries: [TaskDraft(id: plan.secondaries.first.id, title: 'Email')],
      study: [StudyDraft(id: plan.study.single.id, subject: 'Maths', workToDo: 'Ch 4')],
    );
    expect(await sync.push(), isNull);

    final phone2 = await _freshPhone(() => now);
    await phone2.setSetting(serverUrlKey, server);
    await phone2.setSetting(serverTokenKey, Platform.environment['TELOS_TOKEN']!);
    await SyncService(phone2).restore();
    plan = await phone2.loadDay('2026-09-30');
    expect(plan.mit!.done, isTrue);
    expect(plan.mit!.timeSpentMinutes, 42);
    expect(plan.secondaries.map((t) => t.title), ['Email']);
    expect(plan.study.single.subject, 'Maths');
    await phone2.close();
  }, skip: server == null ? 'set TELOS_SERVER to run against a live server' : false);
}
