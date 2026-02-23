import { randomUUID } from 'crypto';
import { openDb } from '../db.js';

export function insertOutcome(params: {
  sessionId: string;
  participantId: string;
  reflectionText: string;
  votePayload: Record<string, unknown>;
  whyChanged?: string | null;
}) {
  const db = openDb();
  const outcomeId = randomUUID();
  db.prepare(
    'INSERT INTO outcomes (id, session_id, participant_id, reflection_text, vote_payload, why_changed) VALUES (?, ?, ?, ?, ?, ?)',
  ).run(
    outcomeId,
    params.sessionId,
    params.participantId,
    params.reflectionText,
    JSON.stringify(params.votePayload),
    params.whyChanged ?? null,
  );

  return { outcomeId };
}
