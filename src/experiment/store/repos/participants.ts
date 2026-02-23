import { randomUUID } from 'crypto';
import { openDb } from '../db.js';

export function registerParticipant(sessionId: string, harmonicaParticipantId: string) {
  const db = openDb();
  const existing = db
    .prepare('SELECT id FROM participants WHERE session_id = ? AND harmonica_participant_id = ?')
    .get(sessionId, harmonicaParticipantId) as { id: string } | undefined;

  if (existing) {
    return { participantId: existing.id };
  }

  const participantId = randomUUID();
  db.prepare(
    'INSERT INTO participants (id, session_id, harmonica_participant_id) VALUES (?, ?, ?)',
  ).run(participantId, sessionId, harmonicaParticipantId);

  return { participantId };
}
