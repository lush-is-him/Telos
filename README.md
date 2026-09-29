# Telos

Plan tomorrow in 20 seconds, do it today, watch the heatmap fill in.

- **Evening:** one MIT (most important task), up to two optional tasks, and study work per subject.
- **Daytime:** start/stop timers, tick things off, mark study items partial/done.
- **Over time:** a heatmap of MIT days, and later a small model that predicts whether tomorrow's MIT gets done.

No mood, sleep or journaling. The app only records work and time.

## Status

Phase 0 + Phase 1 (local MVP) are done. Flutter, Android/iOS, with on-device SQLite as the source of truth.

| Screen   | What it does |
|----------|--------------|
| Today    | MIT + secondaries with strikethrough when done; study items cycle not started → partial → done; one play/pause timer at a time; long-press any row to add or correct minutes manually. |
| Plan     | Today/Tomorrow toggle; MIT required, two optional tasks, optional category chips; reusable subject chips with one "work to do" each. |
| Progress | MIT streak and a 26-week heatmap (tap a day to open it). Also where you set the nightly reminder time (default 21:00). |

A nightly local notification opens the Plan screen.

## Layout

```
lib/
  data/schema.dart        SQLite DDL (constraints enforced in the DB, not just the UI)
  data/models.dart
  data/repository.dart    all reads/writes; screens listen to `revision`
  services/notifications.dart
  ui/                     home shell + three screens
test/
  repository_test.dart    planning, timers, heatmap, schema constraints
  app_flow_test.dart      plan → Today → timer → done → Progress, over real SQLite
```

## Data rules

- Dates are local `YYYY-MM-DD`. Timestamps are UTC ISO-8601. Every row has `updated_at` so last-write-wins sync (Phase 3) can be a straight copy.
- The DB enforces 1 MIT per day, at most 2 secondaries per day (trigger), and 1 running timer at a time (partial unique index).
- Stopping a timer closes its `time_session` and adds the minutes to the item's `time_spent_minutes`. Sessions under a minute are dropped. Marking an item done stops its timer.
- `planned_the_night_before` is set when a row is created for a date later than today. Editing the plan the next morning doesn't change it.
- Unfinished tasks don't roll over to the next day.
- Heatmap level is always derived and never stored: MIT done > secondary done > planned, nothing done > no plan.

## Run

```bash
flutter pub get
flutter test
flutter run            # with an Android device/emulator attached
```

## Next

- **Phase 2:** deadlines UI (the table already exists), optional morning nudge, weekday completion bars.
- **Phase 3:** FastAPI + Postgres on the Ubuntu box over Tailscale, bearer-token auth, push dirty rows / pull on open, weekly `pg_dump` with an off-box copy.
- **Phase 4:** feature table and logistic regression for P(MIT done), once there are about 90 MIT days.
