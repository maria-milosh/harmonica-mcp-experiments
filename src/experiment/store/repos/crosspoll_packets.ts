import type Database from 'better-sqlite3';
import { openDb } from '../db.js';

type PacketItem = {
  fromParticipantId: string;
  rephraseId: string;
  text: string;
};

type StoredPacket = {
  sessionId: string;
  snapshotId: string;
  version: number;
  availableCount: number;
  items: PacketItem[];
  updatedAt: string;
};

function toRowPacket(items: PacketItem[]) {
  return JSON.stringify({ items });
}

function fromRowPacket(packetJson: string): PacketItem[] {
  const parsed = JSON.parse(packetJson) as { items?: PacketItem[] };
  return Array.isArray(parsed.items) ? parsed.items : [];
}

export function upsertCrosspollPacket(params: {
  sessionId: string;
  snapshotId: string;
  items: PacketItem[];
  availableCount: number;
  meta?: Record<string, unknown>;
}, dbInstance?: Database.Database) {
  const db = dbInstance ?? openDb();
  const existing = db
    .prepare(
      'SELECT snapshot_id as snapshotId, version, updated_at as updatedAt FROM crosspoll_packets WHERE session_id = ?',
    )
    .get(params.sessionId) as { snapshotId: string; version: number; updatedAt: string } | undefined;

  if (existing && existing.snapshotId === params.snapshotId) {
    return {
      snapshotId: existing.snapshotId,
      version: existing.version,
      updatedAt: existing.updatedAt,
    };
  }

  const version = existing ? existing.version + 1 : 1;
  const updatedAt = new Date().toISOString();
  const packetJson = toRowPacket(params.items);
  const metaJson = JSON.stringify(params.meta ?? {});

  db.prepare(
    `INSERT INTO crosspoll_packets (session_id, snapshot_id, version, packet_json, available_count, meta_json, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(session_id) DO UPDATE SET
       snapshot_id = excluded.snapshot_id,
       version = excluded.version,
       packet_json = excluded.packet_json,
       available_count = excluded.available_count,
       meta_json = excluded.meta_json,
       updated_at = excluded.updated_at`,
  ).run(
    params.sessionId,
    params.snapshotId,
    version,
    packetJson,
    params.availableCount,
    metaJson,
    updatedAt,
  );

  return { snapshotId: params.snapshotId, version, updatedAt };
}

export function getCrosspollPacket(
  sessionId: string,
  dbInstance?: Database.Database,
): StoredPacket | null {
  const db = dbInstance ?? openDb();
  const row = db
    .prepare(
      `SELECT session_id as sessionId, snapshot_id as snapshotId, version,
              packet_json as packetJson, available_count as availableCount,
              updated_at as updatedAt
       FROM crosspoll_packets WHERE session_id = ?`,
    )
    .get(sessionId) as
    | {
        sessionId: string;
        snapshotId: string;
        version: number;
        packetJson: string;
        availableCount: number;
        updatedAt: string;
      }
    | undefined;

  if (!row) return null;
  return {
    sessionId: row.sessionId,
    snapshotId: row.snapshotId,
    version: row.version,
    availableCount: row.availableCount,
    items: fromRowPacket(row.packetJson),
    updatedAt: row.updatedAt,
  };
}
