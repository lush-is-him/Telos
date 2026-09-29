import 'dart:async';

import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../services/notifications.dart';
import '../services/sync.dart';
import 'plan_screen.dart';
import 'progress_screen.dart';
import 'today_screen.dart';

const planReminderKey = 'plan_reminder_time';
const morningNudgeKey = 'morning_nudge_time';
const defaultReminder = TimeOfDay(hour: 21, minute: 0);
const defaultMorningNudge = TimeOfDay(hour: 8, minute: 0);

Future<TimeOfDay?> loadTime(Repository repo, String key) async {
  final raw = await repo.getSetting(key);
  if (raw == null || raw.isEmpty) return null;
  final [h, m] = raw.split(':').map(int.parse).toList();
  return TimeOfDay(hour: h, minute: m);
}

Future<TimeOfDay> loadReminderTime(Repository repo) async => await loadTime(repo, planReminderKey) ?? defaultReminder;

Future<void> saveTime(Repository repo, String key, TimeOfDay? t) =>
    repo.setSetting(key, t == null ? '' : '${t.hour}:${t.minute}');

enum HomeTab { today, plan, progress }

/// Lets things outside the widget tree (notification taps) switch tabs.
/// Bumping [planRequests] also resets the Plan screen to its default date.
class HomeController {
  final tab = ValueNotifier<HomeTab>(HomeTab.today);
  final planRequests = ValueNotifier<int>(0);

  void openPlan() {
    planRequests.value++;
    tab.value = HomeTab.plan;
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.repo,
    required this.notifications,
    required this.controller,
    required this.sync,
  });

  final Repository repo;
  final Notifications notifications;
  final HomeController controller;
  final SyncService sync;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// Pushes to the home server a few seconds after any change, and whenever the
/// app comes to the foreground or goes to the background.
class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.repo.revision.addListener(_scheduleSync);
    widget.sync.push();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.repo.revision.removeListener(_scheduleSync);
    _debounce?.cancel();
    super.dispose();
  }

  void _scheduleSync() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), widget.sync.push);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || state == AppLifecycleState.paused) {
      widget.sync.push();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ValueListenableBuilder<HomeTab>(
      valueListenable: c.tab,
      builder: (context, tab, _) => Scaffold(
        body: IndexedStack(
          index: tab.index,
          children: [
            TodayScreen(repo: widget.repo, sync: widget.sync, onPlan: c.openPlan),
            PlanScreen(
              repo: widget.repo,
              requests: c.planRequests,
              onSaved: (date) {
                if (date == widget.repo.today) c.tab.value = HomeTab.today;
              },
            ),
            ProgressScreen(repo: widget.repo, notifications: widget.notifications, sync: widget.sync),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab.index,
          onDestinationSelected: (i) => c.tab.value = HomeTab.values[i],
          destinations: const [
            NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: 'Today'),
            NavigationDestination(
              icon: Icon(Icons.edit_note_outlined),
              selectedIcon: Icon(Icons.edit_note),
              label: 'Plan',
            ),
            NavigationDestination(
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view),
              label: 'Progress',
            ),
          ],
        ),
      ),
    );
  }
}
