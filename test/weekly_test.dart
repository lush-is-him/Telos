import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telos/data/models.dart';
import 'package:telos/data/repository.dart';
import 'package:telos/data/schema.dart';

void main() {
  sqfliteFfiInit();

  late DateTime now;
  late Repository repo;

  // 2026-11-08 is a Sunday.
  const sun = '2026-11-08';

  setUp(() async {
    now = DateTime(2026, 11, 8, 20, 0); // Sunday evening
    repo = await Repository.open(inMemoryDatabasePath, factory: databaseFactoryFfi, clock: () => now);
  });
  tearDown(() => repo.close());

  test('weeks run Sunday to Friday; Saturday belongs to the next week', () {
    expect(Repository.weekStartOf('2026-11-08'), sun); // Sunday
    expect(Repository.weekStartOf('2026-11-11'), sun); // Wednesday
    expect(Repository.weekStartOf('2026-11-13'), sun); // Friday
    expect(Repository.weekStartOf('2026-11-14'), '2026-11-15'); // Saturday
    expect(Repository.weekDays(sun), [
      '2026-11-08',
      '2026-11-09',
      '2026-11-10',
      '2026-11-11',
      '2026-11-12',
      '2026-11-13',
    ]);
  });

  test('bucket ranks by priority and spreads steps of big goals', () async {
    final big = await repo.addGoal(weekStart: sun, title: 'Lab report', priority: Priority.high);
    for (final s in ['Method', 'Graphs', 'Proofread']) {
      await repo.addStep(big, s);
    }
    await repo.addGoal(weekStart: sun, title: 'Revise vectors', kind: GoalKind.study, priority: Priority.high);
    await repo.addGoal(weekStart: sun, title: 'Call bank', kind: GoalKind.action, priority: Priority.low);
    await repo.addGoal(weekStart: sun, title: 'Gym plan', priority: Priority.medium);

    final b = await repo.bucket('2026-11-09');
    expect(b.items.map((i) => i.title), [
      'Lab report: Method',
      'Revise vectors', // first steps of every high goal before second steps
      'Lab report: Graphs',
      'Lab report: Proofread',
      'Gym plan',
      'Call bank',
    ]);
    // No history yet: prior of 12/week → 2 suggestions a day.
    expect(b.suggested, hasLength(2));
    expect(b.suggested, contains(b.items.first.key));
  });

  test('picking an item into a day takes it out of other days and ticks it when done', () async {
    final g = await repo.addGoal(weekStart: sun, title: 'Essay', priority: Priority.high);
    await repo.addStep(g, 'Outline');
    await repo.addStep(g, 'Draft');
    final first = (await repo.bucket('2026-11-09')).items.first;

    await repo.savePlan(
      date: '2026-11-09',
      mit: TaskDraft(title: first.title, category: first.goal.kind.category, goalId: g, stepId: first.stepId),
    );
    // Planned for Monday: not offered for Tuesday, still shown on Monday.
    expect((await repo.bucket('2026-11-10')).items.map((i) => i.title), ['Essay: Draft']);
    expect((await repo.bucket('2026-11-09')).items.first.scheduledFor, '2026-11-09');

    final task = (await repo.loadDay('2026-11-09')).mit!;
    expect(task.goalId, g);
    await repo.setTaskDone(task.id, true);
    var goal = (await repo.loadWeek(sun)).single;
    expect(goal.steps.first.done, isTrue);
    expect(goal.done, isFalse);

    await repo.setItemDone(g, goal.steps.last.id, true);
    goal = (await repo.loadWeek(sun)).single;
    expect(goal.done, isTrue, reason: 'all steps done');

    await repo.setTaskDone(task.id, false);
    goal = (await repo.loadWeek(sun)).single;
    expect(goal.done, isFalse);
    expect(goal.steps.first.done, isFalse);
  });

  test('week draft fills from the next day to plan and reports overflow', () async {
    for (var i = 0; i < 14; i++) {
      await repo.addGoal(weekStart: sun, title: 'Goal $i');
    }
    final draft = await repo.weekDraft(sun);
    // Sunday 20:00 with nothing planned → Monday onwards, 2 a day for 5 days.
    expect(draft.days[sun], isEmpty);
    expect(draft.days['2026-11-09'], hasLength(2));
    expect(draft.days['2026-11-13'], hasLength(2));
    expect(draft.overflow, hasLength(4));
    expect(draft.forecast, hasLength(10));
  });

  test('capacity learns from past weeks and the Friday rating', () async {
    expect((await repo.capacity()).itemsPerWeek, Repository.capacityPrior);

    // Three past weeks of 10 planned items, about 4 achieved each.
    for (final week in ['2026-10-18', '2026-10-25', '2026-11-01']) {
      final ids = [for (var i = 0; i < 10; i++) await repo.addGoal(weekStart: week, title: 'g$i')];
      for (final id in ids.take(3)) {
        await repo.setItemDone(id, null, true);
      }
      // One goal not ticked but rated "done" on Friday counts too.
      await repo.saveReview(week, score: 2, ratings: {ids[5]: GoalRating.done});
    }
    final c = await repo.capacity();
    expect(c.weeksObserved, 3);
    expect(c.recentRate, closeTo(0.4, 1e-9));
    // (12*2 + 4*(1 + .8 + .64)) / (2 + 2.44)
    expect(c.itemsPerWeek, closeTo((24 + 4 * 2.44) / 4.44, 1e-9));
    expect(c.perDay, 1);
    expect((await repo.bucket('2026-11-09')).suggested, isEmpty, reason: 'no goals this week yet');
  });

  test('review is due Friday evening and on Saturday, once', () async {
    await repo.addGoal(weekStart: sun, title: 'x');
    now = DateTime(2026, 11, 13, 10); // Friday morning
    expect(await repo.weekToReview(), isNull);
    now = DateTime(2026, 11, 13, 18); // Friday evening
    expect(await repo.weekToReview(), sun);
    now = DateTime(2026, 11, 14, 9); // Saturday
    expect(await repo.weekToReview(), sun);
    await repo.saveReview(sun, score: 4, ratings: {});
    expect(await repo.weekToReview(), isNull);
    expect((await repo.reviewFor(sun))!.score, 4);
  });

  test('carry over copies unfinished goals with their open steps, once', () async {
    final g = await repo.addGoal(weekStart: sun, title: 'Thesis', priority: Priority.high);
    await repo.addStep(g, 'Ch 1');
    await repo.addStep(g, 'Ch 2');
    final done = await repo.addGoal(weekStart: sun, title: 'Done thing');
    await repo.setItemDone(done, null, true);
    final steps = (await repo.loadWeek(sun)).first.steps;
    await repo.setItemDone(g, steps.first.id, true);

    const next = '2026-11-15';
    expect(await repo.carryOver(sun, next), 1);
    expect(await repo.carryOver(sun, next), 0);
    final copied = (await repo.loadWeek(next)).single;
    expect(copied.title, 'Thesis');
    expect(copied.priority, Priority.high);
    expect(copied.steps.map((s) => s.title), ['Ch 2']);
  });

  test('deleting a goal unlinks its tasks and syncs a tombstone', () async {
    final g = await repo.addGoal(weekStart: sun, title: 'Temp');
    await repo.savePlan(
      date: '2026-11-09',
      mit: TaskDraft(title: 'Temp', goalId: g),
    );
    await repo.deleteGoal(g);
    expect((await repo.loadDay('2026-11-09')).mit!.goalId, isNull);
    final batch = await repo.pendingChanges(null);
    expect(batch.deletes.map((d) => d['entity']), contains('goal'));
  });

  test('upgrading a v2 phone database keeps its plans and adds goals', () async {
    final path = '${Directory.systemTemp.createTempSync('telos').path}/v2.db';
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, _) async {
          for (final stmt in [...schemaV1, ...schemaV2]) {
            await db.execute(stmt);
          }
        },
      ),
    );
    const ts = '2026-11-01T00:00:00.000000Z';
    await old.insert('day', {'date': '2026-11-02', 'created_at': ts, 'updated_at': ts});
    await old.insert('task', {
      'id': 'm',
      'date': '2026-11-02',
      'type': 'mit',
      'title': 'Old MIT',
      'created_at': ts,
      'updated_at': ts,
    });
    await old.close();

    final upgraded = await Repository.open(path, factory: databaseFactoryFfi, clock: () => now);
    expect((await upgraded.loadDay('2026-11-02')).mit!.title, 'Old MIT');
    final g = await upgraded.addGoal(weekStart: sun, title: 'New goal');
    await upgraded.addStep(g, 'Step');
    expect((await upgraded.loadWeek(sun)).single.steps, hasLength(1));
    await upgraded.close();
  });
}
