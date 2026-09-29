import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../services/notifications.dart';
import 'plan_screen.dart';
import 'progress_screen.dart';
import 'today_screen.dart';

const _reminderKey = 'plan_reminder_time';
const defaultReminder = TimeOfDay(hour: 21, minute: 0);

Future<TimeOfDay> loadReminderTime(Repository repo) async {
  final raw = await repo.getSetting(_reminderKey);
  if (raw == null) return defaultReminder;
  final [h, m] = raw.split(':').map(int.parse).toList();
  return TimeOfDay(hour: h, minute: m);
}

Future<void> saveReminderTime(Repository repo, TimeOfDay t) => repo.setSetting(_reminderKey, '${t.hour}:${t.minute}');

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

class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.repo, required this.notifications, required this.controller});

  final Repository repo;
  final Notifications notifications;
  final HomeController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HomeTab>(
      valueListenable: controller.tab,
      builder: (context, tab, _) => Scaffold(
        body: IndexedStack(
          index: tab.index,
          children: [
            TodayScreen(repo: repo, onPlan: controller.openPlan),
            PlanScreen(
              repo: repo,
              requests: controller.planRequests,
              onSaved: (date) {
                if (date == repo.today) controller.tab.value = HomeTab.today;
              },
            ),
            ProgressScreen(repo: repo, notifications: notifications),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab.index,
          onDestinationSelected: (i) => controller.tab.value = HomeTab.values[i],
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
