import { randomUUID } from 'crypto';
import { openDb } from '../db.js';

export function insertExposure(params: {
  sessionId: string;
  participantId: string;
  snapshotId: string;
  exposureType: 'initial' | 'refresh';
  rephraseIds: string[];
}) {
  const db = openDb();
  const exposureId = randomUUID();

  const insert = db.transaction(() => {
    db.prepare(
      'INSERT INTO exposures (id, session_id, participant_id, snapshot_id, exposure_type) VALUES (?, ?, ?, ?, ?)',
    ).run(exposureId, params.sessionId, params.participantId, params.snapshotId, params.exposureType);

    const stmt = db.prepare(
      'INSERT INTO exposure_items (exposure_id, rephrase_id) VALUES (?, ?)',
    );
    for (const rephraseId of params.rephraseIds) {
      stmt.run(exposureId, rephraseId);
    }
  });

  insert();
  return { exposureId };
}
