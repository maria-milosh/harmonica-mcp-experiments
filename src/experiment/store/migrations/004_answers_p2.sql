PRAGMA foreign_keys = ON;

ALTER TABLE answers RENAME TO answers_p1;

DROP INDEX IF EXISTS idx_answers_session_message;
CREATE UNIQUE INDEX IF NOT EXISTS idx_answers_p1_session_message
  ON answers_p1(session_id, message_id);

CREATE TABLE IF NOT EXISTS answers_p2 (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  participant_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  answer_text TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (participant_id) REFERENCES participants(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_answers_p2_session_message
  ON answers_p2(session_id, message_id);
