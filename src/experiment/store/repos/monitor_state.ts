import type Database from 'better-sqlite3';
import { openDb } from '../db.js';

export function getMonitorState(sessionId: string, dbInstance?: Database.Database) {
  const db = dbInstance ?? openDb();
  const row = db.prepare(
    'SELECT session_id as sessionId, stop_requested as stopRequested, stopped_reason as stoppedReason FROM monitor_state WHERE session_id = ?',
  ).get(sessionId) as
    | { sessionId: string; stopRequested: number; stoppedReason: string | null }
    | undefined;

  if (!row) return null;
  return {
    sessionId: row.sessionId,
    stopRequested: Boolean(row.stopRequested),
    stoppedReason: row.stoppedReason,
  };
}

export function setMonitorStopRequested(
  sessionId: string,
  stoppedReason: string,
  dbInstance?: Database.Database,
) {
  const db = dbInstance ?? openDb();
  db.prepare(
    `INSERT INTO monitor_state (session_id, stop_requested, stopped_reason, updated_at)
     VALUES (?, 1, ?, CURRENT_TIMESTAMP)
     ON CONFLICT(session_id) DO UPDATE SET
       stop_requested = 1,
       stopped_reason = excluded.stopped_reason,
       updated_at = excluded.updated_at`,
  ).run(sessionId, stoppedReason);
}
