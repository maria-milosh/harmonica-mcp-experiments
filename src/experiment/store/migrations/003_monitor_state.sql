PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS monitor_state (
  session_id TEXT PRIMARY KEY,
  stop_requested INTEGER NOT NULL DEFAULT 0,
  stopped_reason TEXT,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

DELETE FROM answers
WHERE rowid NOT IN (
  SELECT MIN(rowid)
  FROM answers
  GROUP BY session_id, message_id
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_answers_session_message
  ON answers(session_id, message_id);
