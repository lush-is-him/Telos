/// SQLite schema for the on-device source of truth.
///
/// Conventions (kept identical on the server later so sync is a plain copy):
/// - calendar dates are local `YYYY-MM-DD` TEXT
/// - timestamps are UTC ISO-8601 TEXT
/// - booleans are INTEGER 0/1
const schemaVersion = 1;

const schemaV1 = <String>[
  '''
  CREATE TABLE day (
    date           TEXT PRIMARY KEY,
    planned_at     TEXT,
    first_open_at  TEXT,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
  )''',
  '''
  CREATE TABLE task (
    id                        TEXT PRIMARY KEY,
    date                      TEXT NOT NULL REFERENCES day(date),
    type                      TEXT NOT NULL CHECK (type IN ('mit', 'secondary')),
    title                     TEXT NOT NULL CHECK (length(trim(title)) > 0),
    category                  TEXT CHECK (category IN ('study', 'project', 'admin', 'other')),
    status                    TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done')),
    completed_at              TEXT,
    time_spent_minutes        INTEGER NOT NULL DEFAULT 0,
    planned_the_night_before  INTEGER NOT NULL DEFAULT 0,
    created_at                TEXT NOT NULL,
    updated_at                TEXT NOT NULL
  )''',
  "CREATE UNIQUE INDEX one_mit_per_day ON task(date) WHERE type = 'mit'",
  '''
  CREATE TRIGGER max_two_secondaries
  BEFORE INSERT ON task
  WHEN NEW.type = 'secondary'
    AND (SELECT COUNT(*) FROM task WHERE date = NEW.date AND type = 'secondary') >= 2
  BEGIN
    SELECT RAISE(ABORT, 'at most 2 secondary tasks per day');
  END''',
  '''
  CREATE TABLE study_item (
    id                        TEXT PRIMARY KEY,
    date                      TEXT NOT NULL REFERENCES day(date),
    subject                   TEXT NOT NULL,
    work_to_do                TEXT NOT NULL CHECK (length(trim(work_to_do)) > 0),
    work_completed            TEXT NOT NULL DEFAULT 'not_started'
                              CHECK (work_completed IN ('not_started', 'partial', 'done')),
    time_spent_minutes        INTEGER NOT NULL DEFAULT 0,
    planned_the_night_before  INTEGER NOT NULL DEFAULT 0,
    created_at                TEXT NOT NULL,
    updated_at                TEXT NOT NULL
  )''',
  '''
  CREATE TABLE subject (
    name        TEXT PRIMARY KEY,
    last_used   TEXT,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  )''',
  '''
  CREATE TABLE deadline (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    subject     TEXT,
    due_date    TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  )''',
  '''
  CREATE TABLE time_session (
    id             TEXT PRIMARY KEY,
    task_id        TEXT REFERENCES task(id) ON DELETE CASCADE,
    study_item_id  TEXT REFERENCES study_item(id) ON DELETE CASCADE,
    started_at     TEXT NOT NULL,
    ended_at       TEXT,
    minutes        INTEGER,
    updated_at     TEXT NOT NULL,
    CHECK ((task_id IS NOT NULL AND study_item_id IS NULL) OR
           (task_id IS NULL AND study_item_id IS NOT NULL))
  )''',
  // Only one timer may run at a time.
  'CREATE UNIQUE INDEX one_running_session ON time_session((ended_at IS NULL)) WHERE ended_at IS NULL',
  'CREATE INDEX time_session_task ON time_session(task_id)',
  'CREATE INDEX time_session_study ON time_session(study_item_id)',
  'CREATE INDEX study_item_date ON study_item(date)',
  '''
  CREATE TABLE setting (
    key    TEXT PRIMARY KEY,
    value  TEXT NOT NULL
  )''',
];
