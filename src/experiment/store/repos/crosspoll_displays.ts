import { randomUUID } from 'crypto';
import { openDb } from '../db.js';

export function insertCrosspollDisplay(params: {
  sessionId: string;
  snapshotId: string;
  displayType: 'initial' | 'refresh';
  rephraseIds: string[];
  viewerParticipantId?: string | null;
  messageId?: string | null;
}) {
  const db = openDb();
  const displayId = randomUUID();

  const insert = db.transaction(() => {
    db.prepare(
      `INSERT INTO crosspoll_displays
        (id, session_id, snapshot_id, display_type, viewer_participant_id, message_id)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(
      displayId,
      params.sessionId,
      params.snapshotId,
      params.displayType,
      params.viewerParticipantId ?? null,
      params.messageId ?? null,
    );

    const stmt = db.prepare(
      'INSERT INTO crosspoll_display_items (display_id, rephrase_id) VALUES (?, ?)',
    );
    for (const rephraseId of params.rephraseIds) {
      stmt.run(displayId, rephraseId);
    }
  });

  insert();
  return { exposureId: displayId };
}
