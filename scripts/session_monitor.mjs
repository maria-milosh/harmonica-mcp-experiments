import { setTimeout as sleep } from 'node:timers/promises';
import fs from 'node:fs';
import path from 'node:path';
import { HarmonicaClient } from '../dist/client.js';
import { loadPilotConfig } from './pilot_config.mjs';

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    intervalMs: 60_000,
    maxUsers: 1,
    maxUsersSet: false,
    sessionId: null,
    stop: false,
    debug: false,
    phase: 1,
    config: null,
  };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--interval' && args[i + 1]) {
      out.intervalMs = Number(args[++i]) * 1000;
    } else if (arg === '--max-users' && args[i + 1]) {
      out.maxUsers = Number(args[++i]);
      out.maxUsersSet = true;
    } else if (arg === '--session-id' && args[i + 1]) {
      out.sessionId = args[++i];
    } else if (arg === '--stop') {
      out.stop = true;
    } else if (arg === '--debug') {
      out.debug = true;
    } else if (arg === '--phase' && args[i + 1]) {
      out.phase = Number(args[++i]);
    } else if (arg === '--config' && args[i + 1]) {
      out.config = args[++i];
    }
  }
  return out;
}

async function fetchSession(client, sessionId) {
  const session = await client.getSession(sessionId);
  if (!session.topic.trim().startsWith('P1') && !session.topic.trim().startsWith('P2')) {
    throw new Error(`Session topic must start with "P1" or "P2": ${session.topic}`);
  }
  return session;
}

async function processSession(client, session, maxUsers, debug) {
  const responses = await client.getSessionResponses(session.id);
  const finishedCount = responses.data.filter((p) => p.active === false).length;
  if (debug) {
    for (const participant of responses.data) {
      for (const message of participant.messages) {
        if (message.role !== 'user') continue;
        console.log(`[${session.id}] saw message ${message.id}: ${JSON.stringify(message.content)}`);
      }
    }
  }
  if (finishedCount >= maxUsers) {
    return { stopped: true, reason: 'threshold', total: finishedCount, responses };
  }
  return { stopped: false, total: finishedCount, responses };
}

async function main() {
  let {
    intervalMs,
    maxUsers,
    maxUsersSet,
    sessionId,
    stop,
    debug,
    phase,
    config,
  } = parseArgs();
  if (!sessionId) {
    console.error('Missing --session-id');
    process.exit(1);
  }
  if (![1, 2].includes(phase)) {
    console.error('Invalid --phase. Use 1 or 2.');
    process.exit(1);
  }
  const pilot = loadPilotConfig(config ?? 'example_pilot.yaml');
  if (!maxUsersSet && pilot?.expectedParticipants) {
    maxUsersSet = true;
    maxUsers = pilot.expectedParticipants;
  }
  if (!maxUsersSet) {
    console.error('Stop mode "users" requires --max-users.');
    process.exit(1);
  }

  if (stop) {
    if (!sessionId) {
      console.error('Provide --session-id when using --stop');
      process.exit(1);
    }
    const stopPath = path.resolve('data', 'responses', `phase${phase}_${sessionId}.stop`);
    fs.mkdirSync(path.dirname(stopPath), { recursive: true });
    fs.writeFileSync(stopPath, 'stop');
    console.log(`Stopped monitoring ${sessionId}`);
    return;
  }

  const apiKey = process.env.HARMONICA_API_KEY;
  if (!apiKey) {
    console.error('Missing HARMONICA_API_KEY');
    process.exit(1);
  }

  const client = new HarmonicaClient({
    baseUrl: process.env.HARMONICA_API_URL || 'https://app.harmonica.chat',
    apiKey,
  });

  console.log(`Session monitor running for ${sessionId}. phase=${phase} interval=${intervalMs / 1000}s max_users=${maxUsers}`);
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      const stopPath = path.resolve('data', 'responses', `phase${phase}_${sessionId}.stop`);
      if (fs.existsSync(stopPath)) {
        console.log(`[${sessionId}] stop flag file found. Exiting.`);
        process.exit(0);
      }
      const session = await fetchSession(client, sessionId);
      const result = await processSession(client, session, maxUsers, debug);
      const outDir = path.resolve('data', 'responses');
      fs.mkdirSync(outDir, { recursive: true });
      const outPath = path.join(outDir, `phase${phase}_${sessionId}.json`);
      fs.writeFileSync(outPath, JSON.stringify(result.responses, null, 2));
      if (result.stopped) {
        console.log(`[${session.id}] stopped: ${result.reason}`);
        if (result.reason === 'threshold') {
          console.log(`[${session.id}] reached ${maxUsers} finished participants. Saving responses and exiting.`);
          process.exit(0);
        }
      } else {
        console.log(`[${session.id}] finished=${result.total}/${maxUsers}`);
      }
    } catch (err) {
      console.error(`[${sessionId}] error:`, err?.message ?? err);
    }
    await sleep(intervalMs);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
