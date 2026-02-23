PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS crosspoll_packets (
  session_id TEXT PRIMARY KEY,
  snapshot_id TEXT NOT NULL,
  version INTEGER NOT NULL,
  packet_json TEXT NOT NULL,
  available_count INTEGER NOT NULL,
  meta_json TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS crosspoll_displays (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  snapshot_id TEXT NOT NULL,
  display_type TEXT NOT NULL,
  viewer_participant_id TEXT,
  message_id TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (viewer_participant_id) REFERENCES participants(id)
);

CREATE TABLE IF NOT EXISTS crosspoll_display_items (
  display_id TEXT NOT NULL,
  rephrase_id TEXT NOT NULL,
  PRIMARY KEY (display_id, rephrase_id),
  FOREIGN KEY (display_id) REFERENCES crosspoll_displays(id),
  FOREIGN KEY (rephrase_id) REFERENCES rephrases(id)
);

CREATE INDEX IF NOT EXISTS idx_crosspoll_packets_session ON crosspoll_packets(session_id);
CREATE INDEX IF NOT EXISTS idx_crosspoll_displays_session ON crosspoll_displays(session_id);
CREATE INDEX IF NOT EXISTS idx_crosspoll_display_items_display ON crosspoll_display_items(display_id);
