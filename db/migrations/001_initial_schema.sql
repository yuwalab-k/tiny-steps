-- Migration 001: Initial schema
-- Mandala Chart (Tiny Steps) の初期テーブル作成

PRAGMA foreign_keys = ON;

-- 不要になった旧テーブルの削除
DROP TABLE IF EXISTS ai_pending;
DROP TABLE IF EXISTS ai_messages;
DROP TABLE IF EXISTS event_logs;
DROP TABLE IF EXISTS task_logs;
DROP TABLE IF EXISTS tasks;

-- goals テーブル
CREATE TABLE IF NOT EXISTS goals (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  parent_id  INTEGER REFERENCES goals(id),
  title      TEXT NOT NULL,
  completed  INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  archived   INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_goals_parent ON goals(parent_id);

-- 初期データ: ルートゴールが存在しない場合のみ挿入
INSERT INTO goals (title)
  SELECT 'メインゴール'
  WHERE NOT EXISTS (SELECT 1 FROM goals WHERE archived = 0);
