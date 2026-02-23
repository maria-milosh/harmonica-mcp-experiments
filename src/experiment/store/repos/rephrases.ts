import { randomUUID } from 'crypto';
import type Database from 'better-sqlite3';
import { openDb } from '../db.js';

export function insertRephrase(params: {
  sessionId: string;
  participantId: string;
  answerId: string;
  rephraseText: string;
  redactionNotes?: string | null;
}, dbInstance?: Database.Database) {
  const db = dbInstance ?? openDb();
  const existing = db.prepare(
    `SELECT id FROM rephrases
     WHERE session_id = ? AND participant_id = ? AND answer_id = ? AND rephrase_text = ?`,
  ).get(
    params.sessionId,
    params.participantId,
    params.answerId,
    params.rephraseText,
  ) as { id: string } | undefined;

  if (existing) {
    return { rephraseId: existing.id, stored: false };
  }
  const rephraseId = randomUUID();
  db.prepare(
    'INSERT INTO rephrases (id, session_id, participant_id, answer_id, rephrase_text, redaction_notes) VALUES (?, ?, ?, ?, ?, ?)',
  ).run(
    rephraseId,
    params.sessionId,
    params.participantId,
    params.answerId,
    params.rephraseText,
    params.redactionNotes ?? null,
  );

  return { rephraseId, stored: true };
}

export function listRephrasesForSession(
  sessionId: string,
  dbInstance?: Database.Database,
) {
  const db = dbInstance ?? openDb();
  return db.prepare(
    `SELECT id as rephraseId, participant_id as participantId, rephrase_text as text
     FROM rephrases
     WHERE session_id = ?
     ORDER BY created_at ASC`,
  ).all(sessionId) as Array<{ rephraseId: string; participantId: string; text: string }>;
}
