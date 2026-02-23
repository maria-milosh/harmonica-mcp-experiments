import { randomUUID } from 'crypto';
import { openDb } from '../db.js';

export function insertAnswer(params: {
  sessionId: string;
  participantId: string;
  messageId: string;
  answerText: string;
}) {
  const db = openDb();
  const answerId = randomUUID();
  db.prepare(
    'INSERT INTO answers (id, session_id, participant_id, message_id, answer_text) VALUES (?, ?, ?, ?, ?)',
  ).run(answerId, params.sessionId, params.participantId, params.messageId, params.answerText);

  return { answerId };
}
