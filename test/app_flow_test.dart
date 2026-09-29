import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telos/data/models.dart';
import 'package:telos/data/repository.dart';
import 'package:telos/main.dart';
import 'package:telos/services/notifications.dart';
import 'package:telos/ui/home.dart';

void main() {
  sqfliteFfiInit();

  testWidgets('plan today, then complete and time the MIT', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    final repo = (await tester.runAsync(
      () => Repository.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
        clock: () => DateTime(2026, 9, 29, 9, 30), // morning → plans today
      ),
    ))!;

    // Let real (ffi) DB futures settle, then rebuild.
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    final shell = HomeController();
    await tester.pumpWidget(TelosApp(repo: repo, notifications: Notifications(() {}), shell: shell));
    await settle();
    expect(find.text('Nothing planned for today.'), findsOneWidget);

    await tester.tap(find.text('Plan now'));
    await settle();
    expect(find.text('Save for today'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Most important task'), 'Finish thesis intro');
    await tester.enterText(find.widgetWithText(TextField, 'Optional task 1'), 'Email supervisor');
    await tester.enterText(find.widgetWithText(TextField, 'New subject'), 'Maths');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Maths'), 'Ch 4 exercises');

    await tester.tap(find.text('Save for today'));
    await settle();

    // Saving today's plan jumps to Today.
    expect(shell.tab.value, HomeTab.today);
    expect(find.text('Finish thesis intro'), findsOneWidget);
    expect(find.text('Email supervisor'), findsOneWidget);
    expect(find.text('Maths · Ch 4 exercises'), findsOneWidget);

    // Start the MIT timer, then tick it done.
    await tester.tap(find.byTooltip('Start timer').first);
    await settle();
    expect((await tester.runAsync(repo.runningTimer)), isNotNull);

    await tester.tap(find.byType(Checkbox).first);
    await settle();
    final plan = (await tester.runAsync(() => repo.loadDay('2026-09-29')))!;
    expect(plan.mit!.done, isTrue);
    expect((await tester.runAsync(repo.runningTimer)), isNull);
    final title = tester.widget<Text>(find.text('Finish thesis intro'));
    expect(title.style?.decoration, TextDecoration.lineThrough);

    // Progress shows the streak.
    await tester.tap(find.text('Progress'));
    await settle();
    expect(find.text('day MIT streak'), findsOneWidget);
    final levels = (await tester.runAsync(() => repo.heatmap('2026-09-29', '2026-09-29')))!;
    expect(levels['2026-09-29'], DayLevel.mitDone);

    await tester.runAsync(repo.close);
  });
}
