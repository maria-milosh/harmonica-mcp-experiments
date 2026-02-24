import fs from 'node:fs';
import path from 'node:path';
import { loadPilotConfig } from './pilot_config.mjs';
import { HarmonicaClient } from '../dist/client.js';

function parseArgs() {
  const args = process.argv.slice(2);
  const out = { config: null };
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--config' && args[i + 1]) out.config = args[++i];
  }
  return out;
}

function readJson(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return null;
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function findLatestFile(dir, prefix) {
  if (!fs.existsSync(dir)) return null;
  const files = fs.readdirSync(dir)
    .filter((f) => f.startsWith(prefix) && f.endsWith('.json') && !f.includes('_extractions'))
    .map((f) => ({ name: f, time: fs.statSync(path.join(dir, f)).mtimeMs }))
    .sort((a, b) => b.time - a.time);
  return files.length ? path.join(dir, files[0].name) : null;
}

function extractSessionId(filePath) {
  if (!filePath) return null;
  const base = path.basename(filePath);
  const match = base.match(/^phase\d+_(hst_[^_]+)\.json$/);
  return match ? match[1] : null;
}

function summarizeParticipants(payload) {
  const participants = payload?.participants ?? payload?.data ?? [];
  const total = participants.length;
  const finished = participants.filter((p) => p.active === false).length;
  return { total, finished };
}

function summarizeExtractions(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return { status: 'not run', nullVotes: 0, total: 0 };
  const rows = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  const total = rows.length;
  const nullVotes = rows.filter((r) => r.vote == null).length;
  if (nullVotes > 0) {
    return { status: `complete (${nullVotes} null votes flagged)`, nullVotes, total };
  }
  return { status: 'complete', nullVotes, total };
}

function printStatus(lines) {
  console.log(lines.join('\n'));
}

function nextStepHint(state) {
  if (!state.phase1.created) return 'Run: npm run phase1:create -- --config example_pilot.yaml';
  if (!state.phase1.completed) return 'Run: npm run session:monitor -- --session-id <PHASE1_ID> --phase 1 --max-users N';
  if (!state.extractions.complete) return 'Run: npm run reasoning:extract -- --session-id <PHASE1_ID> --phase 1 --config example_pilot.yaml';
  if (!state.phase2.created) return 'Run: npm run phase2:create -- --source-session <PHASE2_ID> --config example_pilot.yaml';
  if (!state.phase2.completed) return 'Run: npm run session:monitor -- --session-id <PHASE2_ID> --phase 2 --max-users N';
  return 'All session-reliant steps complete. To run Phase 2 extractions: npm run reasoning:extract -- --session-id hst_... --phase 2 --config example_pilot.yaml';
}

async function main() {
  const { config } = parseArgs();
  const pilot = loadPilotConfig(config ?? 'example_pilot.yaml') ?? {};
  const responsesDir = path.resolve('data', 'responses');
  const phase1Path = findLatestFile(responsesDir, 'phase1_');
  const phase2Path = findLatestFile(responsesDir, 'phase2_');
  const phase1Id = extractSessionId(phase1Path);
  const phase2Id = extractSessionId(phase2Path);

  const phase1Payload = readJson(phase1Path);
  const phase2Payload = readJson(phase2Path);
  let phase1Counts = summarizeParticipants(phase1Payload);
  let phase2Counts = summarizeParticipants(phase2Payload);

  const apiKey = process.env.HARMONICA_API_KEY;
  if (apiKey && (phase1Id || phase2Id)) {
    const client = new HarmonicaClient({
      baseUrl: process.env.HARMONICA_API_URL || 'https://app.harmonica.chat',
      apiKey,
    });
    try {
      if (phase1Id) {
        const res = await client.getSessionResponses(phase1Id);
        phase1Counts = summarizeParticipants(res);
      }
      if (phase2Id) {
        const res = await client.getSessionResponses(phase2Id);
        phase2Counts = summarizeParticipants(res);
      }
    } catch (err) {
      console.error('Warning: failed to fetch live session responses:', err?.message ?? err);
    }
  }

  const extractionsPath = phase1Id
    ? path.join(responsesDir, `phase1_${phase1Id}_extractions.json`)
    : null;
  const extractions = summarizeExtractions(extractionsPath);
  const phase2ExtractionsPath = phase2Id
    ? path.join(responsesDir, `phase2_${phase2Id}_extractions.json`)
    : null;
  const phase2Extractions = summarizeExtractions(phase2ExtractionsPath);

  const expected = pilot.expectedParticipants ?? 'unknown';
  const phase1Created = Boolean(phase1Id);
  const phase1Completed = phase1Created && phase1Counts.finished >= (pilot.expectedParticipants ?? 0) && pilot.expectedParticipants != null;
  const phase2Created = Boolean(phase2Id);
  const phase2Completed = phase2Created && phase2Counts.finished >= (pilot.expectedParticipants ?? 0) && pilot.expectedParticipants != null;

  const lines = [];
  const header = `Pilot: ${pilot.pilotId ?? 'unknown'} — ${pilot.pilotName ?? 'unknown'}`;
  lines.push(header);
  lines.push('─'.repeat(header.length));
  lines.push(`Phase 1 session: ${phase1Created ? 'created' : 'not created'}${phase1Id ? ` (id: ${phase1Id})` : ''}`);
  lines.push(`Participants: ${phase1Counts.finished} / ${expected} completed`);
  lines.push(`Extractions: ${extractions.status}`);
  lines.push(`Phase 2 session: ${phase2Created ? 'created' : 'not created'}${phase2Id ? ` (id: ${phase2Id})` : ''}`);
  lines.push(`Participants: ${phase2Counts.finished} / ${expected} completed`);
  lines.push(`Phase 2 extractions: ${phase2Extractions.status}`);
  lines.push('─'.repeat(header.length));

  const state = {
    phase1: { created: phase1Created, completed: phase1Completed },
    phase2: { created: phase2Created, completed: phase2Completed },
    extractions: { complete: extractions.status.startsWith('complete') },
  };
  lines.push(`Next step: ${nextStepHint(state)}`);

  printStatus(lines);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
