import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'data/repository.dart';
import 'services/notifications.dart';
import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final repo = await Repository.open(p.join(await getDatabasesPath(), 'telos.db'));
  await repo.recordAppOpen();

  final shell = HomeController();
  final notifications = Notifications(shell.openPlan);
  await notifications.init();
  await notifications.schedulePlanReminder(await loadReminderTime(repo));
  if (await notifications.launchedFromPlanReminder()) shell.openPlan();

  runApp(TelosApp(repo: repo, notifications: notifications, shell: shell));
}

class TelosApp extends StatelessWidget {
  const TelosApp({super.key, required this.repo, required this.notifications, required this.shell});

  final Repository repo;
  final Notifications notifications;
  final HomeController shell;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D6B), brightness: b),
      useMaterial3: true,
    );
    return MaterialApp(
      title: 'Telos',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: HomeShell(repo: repo, notifications: notifications, controller: shell),
    );
  }
}
