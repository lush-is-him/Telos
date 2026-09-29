import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Payload that deep-links a notification tap to the Plan screen.
const planPayload = 'plan';

const _planReminderId = 1;

/// Nightly "plan tomorrow" reminder. Uses inexact scheduling on Android: a
/// planning nudge doesn't need to-the-minute precision, and this avoids the
/// exact-alarm permission.
class Notifications {
  Notifications(this.onOpenPlan);

  final VoidCallback onOpenPlan;
  final _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Fall back to UTC; the reminder will still fire, just possibly offset.
    }

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload == planPayload) onOpenPlan();
      },
    );

    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// True when the app was cold-started by tapping the plan reminder.
  Future<bool> launchedFromPlanReminder() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    return details?.didNotificationLaunchApp == true && details?.notificationResponse?.payload == planPayload;
  }

  Future<void> schedulePlanReminder(TimeOfDay time) async {
    await _plugin.cancel(id: _planReminderId);
    final now = tz.TZDateTime.now(tz.local);
    var at = tz.TZDateTime(tz.local, now.year, now.month, now.day, time.hour, time.minute);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));

    await _plugin.zonedSchedule(
      id: _planReminderId,
      scheduledDate: at,
      title: 'Plan tomorrow',
      body: 'One MIT, up to two more. Twenty seconds.',
      payload: planPayload,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'plan_reminder',
          'Planning reminder',
          channelDescription: 'Nightly reminder to plan tomorrow',
          importance: Importance.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }
}
