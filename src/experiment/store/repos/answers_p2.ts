import { randomUUID } from 'crypto';
import type Database from 'better-sqlite3';
import { openDb } from '../db.js';

export function insertAnswerP2(params: {
  sessionId: string;
  participantId: string;
  messageId: string;
  answerText: string;
}, dbInstance?: Database.Database) {
  const db = dbInstance ?? openDb();
  const answerId = randomUUID();
  db.prepare(
    'INSERT OR IGNORE INTO answers_p2 (id, session_id, participant_id, message_id, answer_text) VALUES (?, ?, ?, ?, ?)',
  ).run(answerId, params.sessionId, params.participantId, params.messageId, params.answerText);

  const existing = db.prepare(
    'SELECT id FROM answers_p2 WHERE session_id = ? AND message_id = ?',
  ).get(params.sessionId, params.messageId) as { id: string } | undefined;

  if (!existing) {
    return { answerId, stored: false };
  }
  return { answerId: existing.id, stored: existing.id === answerId };
}

export function countAnswersP2ForSession(sessionId: string, dbInstance?: Database.Database) {
  const db = dbInstance ?? openDb();
  const row = db.prepare(
    'SELECT COUNT(1) as count FROM answers_p2 WHERE session_id = ?',
  ).get(sessionId) as { count: number };
  return row.count;
}
