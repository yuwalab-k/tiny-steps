-- Tiny Steps database schema (draft)
PRAGMA foreign_keys = ON;

-- Goals: tree structure via adjacency list
CREATE TABLE IF NOT EXISTS goals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  parent_id INTEGER REFERENCES goals(id) ON DELETE RESTRICT,
  title TEXT NOT NULL,
  deadline DATE,
  sort_order INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  completed INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_goals_parent_id ON goals(parent_id);

-- Tasks: leaf items under a goal
CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  goal_id INTEGER NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  repeat_type TEXT NOT NULL DEFAULT 'none' CHECK (repeat_type IN ('none','daily','weekly')),
  points INTEGER NOT NULL DEFAULT 1 CHECK (points >= 0),
  duration_min INTEGER NOT NULL DEFAULT 15,
  priority TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('high','medium','low')),
  active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_tasks_goal_id ON tasks(goal_id);
CREATE INDEX IF NOT EXISTS idx_tasks_repeat_type ON tasks(repeat_type);
CREATE INDEX IF NOT EXISTS idx_tasks_priority ON tasks(priority);

-- Task logs: immutable history of task execution
CREATE TABLE IF NOT EXISTS task_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT,
  log_date DATE NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('done','undone')),
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_task_logs_date ON task_logs(log_date);
CREATE INDEX IF NOT EXISTS idx_task_logs_task_date ON task_logs(task_id, log_date);

-- Event logs: immutable history for all operations
CREATE TABLE IF NOT EXISTS event_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_type TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id INTEGER,
  payload_json TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_event_logs_created_at ON event_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_event_logs_type ON event_logs(event_type);

-- Immutability: prevent deletes/updates on logs
CREATE TRIGGER IF NOT EXISTS trg_task_logs_no_delete
BEFORE DELETE ON task_logs
BEGIN
  SELECT RAISE(ABORT, 'task_logs are immutable');
END;

CREATE TRIGGER IF NOT EXISTS trg_task_logs_no_update
BEFORE UPDATE ON task_logs
BEGIN
  SELECT RAISE(ABORT, 'task_logs are immutable');
END;

CREATE TRIGGER IF NOT EXISTS trg_event_logs_no_delete
BEFORE DELETE ON event_logs
BEGIN
  SELECT RAISE(ABORT, 'event_logs are immutable');
END;

CREATE TRIGGER IF NOT EXISTS trg_event_logs_no_update
BEFORE UPDATE ON event_logs
BEGIN
  SELECT RAISE(ABORT, 'event_logs are immutable');
END;

-- AI chat messages
CREATE TABLE IF NOT EXISTS ai_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  role TEXT NOT NULL CHECK (role IN ('user','assistant','system')),
  content TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_ai_messages_created_at ON ai_messages(created_at);

-- AI pending suggestions (confirmation required)
CREATE TABLE IF NOT EXISTS ai_pending (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  goal_id INTEGER REFERENCES goals(id) ON DELETE SET NULL,
  suggestions_json TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_ai_pending_created_at ON ai_pending(created_at);
