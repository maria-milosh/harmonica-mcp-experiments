import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const dataDir = path.resolve('data', 'crosspoll-smoke');
fs.rmSync(dataDir, { recursive: true, force: true });
fs.mkdirSync(dataDir, { recursive: true });

process.env.CROSSPOLL_DATA_DIR = dataDir;

const {
  xpUpsertCrosspollPacket,
  xpGetCrossPollinationPacket,
} = await import('../dist/experiment/service.js');

const sessionId = 'session_smoke';

const empty = xpGetCrossPollinationPacket({ sessionId, minAvailable: 1 });
assert.equal(empty.ok, false);
assert.equal(empty.reason, 'NoPacketYet');

const upsert1 = xpUpsertCrosspollPacket({
  sessionId,
  availableCount: 2,
  items: [
    { fromParticipantId: 'p1', rephraseId: 'r1', text: 'One' },
    { fromParticipantId: 'p2', rephraseId: 'r2', text: 'Two' },
  ],
});
assert.equal(upsert1.ok, true);
assert.equal(upsert1.version, 1);

const got1 = xpGetCrossPollinationPacket({ sessionId, minAvailable: 1 });
assert.equal(got1.ok, true);
assert.equal(got1.snapshot_id, upsert1.snapshot_id);
assert.equal(got1.items.length, 2);

const upsert1b = xpUpsertCrosspollPacket({
  sessionId,
  availableCount: 2,
  items: [
    { fromParticipantId: 'p2', rephraseId: 'r2', text: 'Two' },
    { fromParticipantId: 'p1', rephraseId: 'r1', text: 'One' },
  ],
});
assert.equal(upsert1b.version, 1);
assert.equal(upsert1b.snapshot_id, upsert1.snapshot_id);

const noNew = xpGetCrossPollinationPacket({ sessionId, sinceSnapshotId: upsert1.snapshot_id });
assert.equal(noNew.ok, false);
assert.equal(noNew.reason, 'NoNewPacket');

const upsert2 = xpUpsertCrosspollPacket({
  sessionId,
  availableCount: 3,
  items: [
    { fromParticipantId: 'p1', rephraseId: 'r1', text: 'One' },
    { fromParticipantId: 'p2', rephraseId: 'r2', text: 'Two' },
    { fromParticipantId: 'p3', rephraseId: 'r3', text: 'Three' },
  ],
});
assert.equal(upsert2.version, 2);
assert.notEqual(upsert2.snapshot_id, upsert1.snapshot_id);

console.log('xp_packet_smoke passed');
