import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telos/data/models.dart';
import 'package:telos/data/repository.dart';
import 'package:telos/data/schema.dart';

void main() {
  sqfliteFfiInit();

  late DateTime now;
  late Repository repo;

  setUp(() async {
    now = DateTime(2026, 9, 29, 21, 0); // Tuesday evening
    repo = await Repository.open(inMemoryDatabasePath, factory: databaseFactoryFfi, clock: () => now);
  });

  tearDown(() => repo.close());

  test('evening planning targets tomorrow and marks night-before', () async {
    final date = await repo.defaultPlanDate();
    expect(date, '2026-09-30');

    await repo.savePlan(
      date: date,
      mit: TaskDraft(title: 'Write chapter 2', category: Category.project),
      secondaries: [
        TaskDraft(title: 'Email tutor'),
        TaskDraft(title: 'Groceries'),
      ],
      study: [StudyDraft(subject: 'Maths', workToDo: 'Ch 4 exercises')],
    );

    final plan = await repo.loadDay(date);
    expect(plan.mit!.title, 'Write chapter 2');
    expect(plan.mit!.plannedTheNightBefore, isTrue);
    expect(plan.secondaries, hasLength(2));
    expect(plan.study.single.status, StudyStatus.notStarted);
    expect(await repo.subjects(), ['Maths']);
  });

  test('same-day planning is not night-before', () async {
    now = DateTime(2026, 9, 29, 9, 0);
    expect(await repo.defaultPlanDate(), '2026-09-29');
    await repo.savePlan(
      date: '2026-09-29',
      mit: TaskDraft(title: 'x'),
    );
    expect((await repo.loadDay('2026-09-29')).mit!.plannedTheNightBefore, isFalse);
  });

  test('re-saving keeps ids and progress, deletes removed rows', () async {
    await repo.savePlan(
      date: '2026-09-30',
      mit: TaskDraft(title: 'A'),
      secondaries: [
        TaskDraft(title: 'B'),
        TaskDraft(title: 'C'),
      ],
    );
    var plan = await repo.loadDay('2026-09-30');
    await repo.setTaskDone(plan.secondaries.first.id, true);

    await repo.savePlan(
      date: '2026-09-30',
      mit: TaskDraft(id: plan.mit!.id, title: 'A edited'),
      secondaries: [
        TaskDraft(id: plan.secondaries.first.id, title: 'B'),
        TaskDraft(title: 'D'),
      ],
    );
    plan = await repo.loadDay('2026-09-30');
    expect(plan.mit!.title, 'A edited');
    expect(plan.secondaries.map((t) => t.title), ['B', 'D']);
    expect(plan.secondaries.first.done, isTrue);
  });

  test('plan rejects a third secondary task', () async {
    await repo.savePlan(
      date: '2026-09-30',
      mit: TaskDraft(title: 'A'),
      secondaries: [
        TaskDraft(title: 'B'),
        TaskDraft(title: 'C'),
      ],
    );
    final plan = await repo.loadDay('2026-09-30');
    expect(
      () => repo.savePlan(
        date: '2026-09-30',
        mit: TaskDraft(id: plan.mit!.id, title: 'A'),
        secondaries: [
          for (final s in plan.secondaries) TaskDraft(id: s.id, title: s.title),
          TaskDraft(title: 'E'),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('timers roll minutes into the item; only one runs at a time', () async {
    await repo.savePlan(
      date: '2026-09-29',
      mit: TaskDraft(title: 'A'),
      study: [StudyDraft(subject: 'Physics', workToDo: 'Problem set')],
    );
    var plan = await repo.loadDay('2026-09-29');

    await repo.startTimer(ItemKind.task, plan.mit!.id);
    now = now.add(const Duration(minutes: 25));
    await repo.startTimer(ItemKind.study, plan.study.single.id); // stops the MIT timer
    now = now.add(const Duration(minutes: 40));
    await repo.setStudyStatus(plan.study.single.id, StudyStatus.done); // stops study timer

    expect(await repo.runningTimer(), isNull);
    plan = await repo.loadDay('2026-09-29');
    expect(plan.mit!.timeSpentMinutes, 25);
    expect(plan.study.single.timeSpentMinutes, 40);
    expect(plan.study.single.status, StudyStatus.done);

    await repo.addManualMinutes(ItemKind.task, plan.mit!.id, 15);
    await repo.addManualMinutes(ItemKind.task, plan.mit!.id, -100);
    expect((await repo.loadDay('2026-09-29')).mit!.timeSpentMinutes, 0);
  });

  test('sub-minute sessions are discarded', () async {
    await repo.savePlan(
      date: '2026-09-29',
      mit: TaskDraft(title: 'A'),
    );
    final id = (await repo.loadDay('2026-09-29')).mit!.id;
    await repo.startTimer(ItemKind.task, id);
    now = now.add(const Duration(seconds: 20));
    await repo.stopTimer();
    expect((await repo.loadDay('2026-09-29')).mit!.timeSpentMinutes, 0);
    expect(await repo.runningTimer(), isNull);
  });

  test('heatmap levels and streak', () async {
    Future<void> day(String date, {bool mit = false, bool sec = false}) async {
      await repo.savePlan(
        date: date,
        mit: TaskDraft(title: 'M'),
        secondaries: [TaskDraft(title: 'S')],
      );
      final p = await repo.loadDay(date);
      if (mit) await repo.setTaskDone(p.mit!.id, true);
      if (sec) await repo.setTaskDone(p.secondaries.single.id, true);
    }

    await day('2026-09-25', mit: true);
    await day('2026-09-26', sec: true);
    await day('2026-09-27');
    await day('2026-09-28', mit: true);
    await day('2026-09-29', mit: true);

    final map = await repo.heatmap('2026-09-24', '2026-09-30');
    expect(map['2026-09-24'], isNull);
    expect(map['2026-09-25'], DayLevel.mitDone);
    expect(map['2026-09-26'], DayLevel.secondaryDone);
    expect(map['2026-09-27'], DayLevel.logged);
    expect(await repo.mitStreak(), 2);
  });

  test('schema enforces 1 MIT, 2 secondaries, 1 running timer', () async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    for (final stmt in schemaV1) {
      await db.execute(stmt);
    }
    const ts = '2026-09-29T00:00:00Z';
    await db.insert('day', {'date': '2026-09-30', 'created_at': ts, 'updated_at': ts});
    Future<void> task(String id, String type) => db.insert('task', {
      'id': id,
      'date': '2026-09-30',
      'type': type,
      'title': id,
      'created_at': ts,
      'updated_at': ts,
    });

    await task('m1', 'mit');
    await expectLater(task('m2', 'mit'), throwsA(isA<DatabaseException>()));
    await task('s1', 'secondary');
    await task('s2', 'secondary');
    await expectLater(task('s3', 'secondary'), throwsA(isA<DatabaseException>()));

    Future<void> session(String id) =>
        db.insert('time_session', {'id': id, 'task_id': 'm1', 'started_at': ts, 'updated_at': ts});
    await session('t1');
    await expectLater(session('t2'), throwsA(isA<DatabaseException>()));
    await db.close();
  });
}
