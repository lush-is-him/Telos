import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Payload that deep-links a notification tap to the Plan screen.
const planPayload = 'plan';

/// Payload that opens the Friday week review.
const reviewPayload = 'review';

const _planReminderId = 1;
const _morningNudgeId = 2;
const _weekReviewId = 3;

/// Friday evening, when the week (Sunday to Friday) is rated.
const weekReviewTime = TimeOfDay(hour: 18, minute: 0);

/// Nightly "plan tomorrow" reminder. Uses inexact scheduling on Android: a
/// planning nudge doesn't need to-the-minute precision, and this avoids the
/// exact-alarm permission.
class Notifications {
  Notifications(this.onOpenPlan, {this.onOpenReview});

  final VoidCallback onOpenPlan;
  final VoidCallback? onOpenReview;
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
        android: AndroidInitializationSettings('ic_stat_telos'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload == planPayload) onOpenPlan();
        if (r.payload == reviewPayload) onOpenReview?.call();
      },
    );

    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// What a cold start from a notification tap should open, if anything.
  Future<String?> launchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    return details?.didNotificationLaunchApp == true ? details?.notificationResponse?.payload : null;
  }

  /// Weekly "rate your week" reminder, Fridays at [weekReviewTime].
  Future<void> scheduleWeekReview() async {
    await _plugin.cancel(id: _weekReviewId);
    final now = tz.TZDateTime.now(tz.local);
    var at = tz.TZDateTime(tz.local, now.year, now.month, now.day, weekReviewTime.hour, weekReviewTime.minute);
    while (at.weekday != DateTime.friday || !at.isAfter(now)) {
      at = at.add(const Duration(days: 1));
    }
    await _plugin.zonedSchedule(
      id: _weekReviewId,
      scheduledDate: at,
      title: 'Rate your week',
      body: 'How much of this week\'s goals did you get done? It tunes next week\'s suggestions.',
      payload: reviewPayload,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'week_review',
          'Weekly review',
          channelDescription: 'Friday evening reminder to rate the week',
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
    );
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

  /// Optional morning "open today's MIT" nudge; null turns it off.
  Future<void> scheduleMorningNudge(TimeOfDay? time) async {
    await _plugin.cancel(id: _morningNudgeId);
    if (time == null) return;
    final now = tz.TZDateTime.now(tz.local);
    var at = tz.TZDateTime(tz.local, now.year, now.month, now.day, time.hour, time.minute);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    await _plugin.zonedSchedule(
      id: _morningNudgeId,
      scheduledDate: at,
      title: "Today's MIT",
      body: 'Start the timer on the one thing that matters today.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'morning_nudge',
          'Morning nudge',
          channelDescription: "Optional reminder to open today's MIT",
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }
}
