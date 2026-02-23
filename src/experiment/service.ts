import { registerParticipant } from './store/repos/participants.js';
import { insertAnswer } from './store/repos/answers.js';
import { insertRephrase, listRephrasesForSession } from './store/repos/rephrases.js';
import { insertExposure } from './store/repos/exposures.js';
import { insertOutcome } from './store/repos/outcomes.js';
import { getCrosspollPacket, upsertCrosspollPacket } from './store/repos/crosspoll_packets.js';
import { insertCrosspollDisplay } from './store/repos/crosspoll_displays.js';
import { snapshotIdFromRephraseIds } from './snapshot.js';
import { openDb } from './store/db.js';

export function xpRegisterParticipant(sessionId: string, harmonicaParticipantId: string) {
  return registerParticipant(sessionId, harmonicaParticipantId);
}

export function xpStoreInitialAnswer(params: {
  sessionId: string;
  participantId: string;
  messageId: string;
  answerText: string;
}) {
  return insertAnswer({
    sessionId: params.sessionId,
    participantId: params.participantId,
    messageId: params.messageId,
    answerText: params.answerText,
  });
}

export function xpStoreRephrase(params: {
  sessionId: string;
  participantId: string;
  answerId: string;
  rephraseText: string;
  redactionNotes?: string | null;
}) {
  const db = openDb();
  const txn = db.transaction(() => {
    const result = insertRephrase({
      sessionId: params.sessionId,
      participantId: params.participantId,
      answerId: params.answerId,
      rephraseText: params.rephraseText,
      redactionNotes: params.redactionNotes ?? null,
    }, db);
    if (result.stored) {
      rebuildAndUpsertCrosspollPacket(params.sessionId, db);
    }
    return result;
  });

  return txn();
}

export function xpGetCrossPollinationPacket(params: {
  sessionId: string;
  minAvailable?: number;
  sinceSnapshotId?: string;
}) {
  const packet = getCrosspollPacket(params.sessionId);
  if (!packet) {
    return { ok: false, reason: 'NoPacketYet' as const };
  }
  if (params.sinceSnapshotId && params.sinceSnapshotId === packet.snapshotId) {
    return { ok: false, reason: 'NoNewPacket' as const, snapshot_id: packet.snapshotId };
  }
  const minAvailable = params.minAvailable ?? 1;
  if (packet.availableCount < minAvailable) {
    return {
      ok: false,
      reason: 'NotEnoughPerspectives' as const,
      available_count: packet.availableCount,
      min_available: minAvailable,
    };
  }
  return {
    ok: true,
    snapshot_id: packet.snapshotId,
    version: packet.version,
    as_of: packet.updatedAt,
    available_count: packet.availableCount,
    items: packet.items.map((item) => ({
      from_participant_id: item.fromParticipantId,
      rephrase_id: item.rephraseId,
      text: item.text,
    })),
  };
}

export function xpLogExposure(params: {
  sessionId: string;
  participantId: string;
  snapshotId: string;
  exposureType: 'initial' | 'refresh';
  rephraseIds: string[];
}) {
  return insertExposure({
    sessionId: params.sessionId,
    participantId: params.participantId,
    snapshotId: params.snapshotId,
    exposureType: params.exposureType,
    rephraseIds: params.rephraseIds,
  });
}

export function xpStoreOutcome(params: {
  sessionId: string;
  participantId: string;
  reflectionText: string;
  votePayload: Record<string, unknown>;
  whyChanged?: string | null;
}) {
  return insertOutcome({
    sessionId: params.sessionId,
    participantId: params.participantId,
    reflectionText: params.reflectionText,
    votePayload: params.votePayload,
    whyChanged: params.whyChanged ?? null,
  });
}

export function xpUpsertCrosspollPacket(params: {
  sessionId: string;
  items: Array<{ fromParticipantId: string; rephraseId: string; text: string }>;
  availableCount: number;
  meta?: Record<string, unknown>;
}) {
  const snapshotId = snapshotIdFromRephraseIds(
    params.items.map((item) => item.rephraseId),
  );
  const result = upsertCrosspollPacket({
    sessionId: params.sessionId,
    snapshotId,
    items: params.items,
    availableCount: params.availableCount,
    meta: params.meta,
  });
  return { ok: true, snapshot_id: result.snapshotId, version: result.version, updated_at: result.updatedAt };
}

function rebuildAndUpsertCrosspollPacket(
  sessionId: string,
  db: ReturnType<typeof openDb>,
) {
  const rephrases = listRephrasesForSession(sessionId, db);
  const items = rephrases.map((r) => ({
    fromParticipantId: r.participantId,
    rephraseId: r.rephraseId,
    text: r.text,
  }));
  const snapshotId = snapshotIdFromRephraseIds(items.map((i) => i.rephraseId));

  const existing = getCrosspollPacket(sessionId, db);
  if (existing && existing.snapshotId === snapshotId) {
    return existing;
  }

  const meta = { as_of: new Date().toISOString() };
  return upsertCrosspollPacket({
    sessionId,
    snapshotId,
    items,
    availableCount: items.length,
    meta,
  }, db);
}

export function xpLogCrosspollDisplay(params: {
  sessionId: string;
  snapshotId: string;
  rephraseIds: string[];
  displayType: 'initial' | 'refresh';
  viewerParticipantId?: string | null;
  messageId?: string | null;
}) {
  const result = insertCrosspollDisplay({
    sessionId: params.sessionId,
    snapshotId: params.snapshotId,
    displayType: params.displayType,
    rephraseIds: params.rephraseIds,
    viewerParticipantId: params.viewerParticipantId ?? null,
    messageId: params.messageId ?? null,
  });
  return { ok: true, exposure_id: result.exposureId };
}
