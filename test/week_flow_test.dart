import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telos/data/models.dart';
import 'package:telos/data/repository.dart';
import 'package:telos/main.dart';
import 'package:telos/services/notifications.dart';
import 'package:telos/services/sync.dart';
import 'package:telos/ui/home.dart';

void main() {
  sqfliteFfiInit();

  testWidgets('weekly goals: write, split, pick suggestions into tomorrow, rate on Friday', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    var now = DateTime(2026, 11, 8, 20, 0); // Sunday evening → plans Monday
    final repo = (await tester.runAsync(
      () => Repository.open(inMemoryDatabasePath, factory: databaseFactoryFfi, clock: () => now),
    ))!;

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    final shell = HomeController();
    await tester.pumpWidget(
      TelosApp(repo: repo, notifications: Notifications(() {}), shell: shell, sync: SyncService(repo)),
    );
    await settle();

    // Write two goals on the Week tab.
    await tester.tap(find.text('Week'));
    await settle();
    expect(find.textContaining('No goals for this week yet'), findsOneWidget);

    Future<void> addGoal(String title, String priority) async {
      await tester.tap(find.text('Add goal'));
      await settle();
      await tester.enterText(find.widgetWithText(TextField, 'Goal'), title);
      await tester.tap(find.text(priority).last);
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settle();
    }

    await addGoal('Lab report', 'High');
    await addGoal('Call bank', 'Low');
    expect(find.text('Lab report'), findsWidgets); // goal card + week plan chip

    // Split the big one into steps.
    final stepField = find.widgetWithText(TextField, 'Too big? Split it: add a step').first;
    await tester.enterText(stepField, 'Method');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle();
    await tester.enterText(find.widgetWithText(TextField, 'Add a step').first, 'Graphs');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle();
    expect(find.text('Method'), findsOneWidget);
    expect(find.textContaining('0/2 steps'), findsOneWidget);
    expect(find.textContaining('Starting estimate'), findsOneWidget);

    // Plan tomorrow from the bucket.
    await tester.tap(find.text('Plan'));
    await settle();
    expect(find.text('From your week'), findsOneWidget);
    expect(find.text('Suggested'), findsNWidgets(2));
    await tester.tap(find.text('Use 2 suggested'));
    await tester.pump();
    await tester.tap(find.text('Save for tomorrow'));
    await settle();

    final plan = (await tester.runAsync(() => repo.loadDay('2026-11-09')))!;
    expect(plan.mit!.title, 'Lab report: Method');
    expect(plan.mit!.goalId, isNotNull);
    expect(plan.secondaries.single.title, 'Lab report: Graphs');

    // Doing the MIT ticks the step.
    await tester.runAsync(() => repo.setTaskDone(plan.mit!.id, true));
    final goals = (await tester.runAsync(() => repo.loadWeek('2026-11-08')))!;
    expect(goals.first.steps.first.done, isTrue);

    // Friday evening: rate the week.
    now = DateTime(2026, 11, 13, 18, 30);
    shell.openReview();
    await settle();
    expect(find.text('How much did you achieve this week?'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '3'));
    await tester.pump();
    await tester.tap(find.text('Save review'));
    await settle();
    expect((await tester.runAsync(() => repo.reviewFor('2026-11-08')))!.score, 3);
    final rated = (await tester.runAsync(() => repo.loadWeek('2026-11-08')))!;
    expect(rated.map((g) => g.rating), [GoalRating.partial, GoalRating.notDone]);

    await tester.runAsync(repo.close);
  });
}
