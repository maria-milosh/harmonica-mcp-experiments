import { setTimeout as sleep } from 'node:timers/promises';
import { HarmonicaClient } from '../dist/client.js';
import { openDb } from '../dist/experiment/store/db.js';
import { registerParticipant } from '../dist/experiment/store/repos/participants.js';
import { insertAnswerP1 } from '../dist/experiment/store/repos/answers_p1.js';
import { insertAnswerP2, countAnswersP2ForSession } from '../dist/experiment/store/repos/answers_p2.js';
import { insertRephrase } from '../dist/experiment/store/repos/rephrases.js';
import { listRephrasesForSession } from '../dist/experiment/store/repos/rephrases.js';
import { getMonitorState, setMonitorStopRequested } from '../dist/experiment/store/repos/monitor_state.js';

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    intervalMs: 60_000,
    maxRephrases: 5,
    maxAnswers: null,
    maxRephrasesSet: false,
    maxAnswersSet: false,
    maxUsers: 1,
    maxUsersSet: false,
    stopMode: 'users',
    sessionId: null,
    stop: false,
    debug: false,
    phase: 1,
  };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--interval' && args[i + 1]) {
      out.intervalMs = Number(args[++i]) * 1000;
    } else if (arg === '--max-rephrases' && args[i + 1]) {
      out.maxRephrases = Number(args[++i]);
      out.maxRephrasesSet = true;
    } else if (arg === '--max-answers' && args[i + 1]) {
      out.maxAnswers = Number(args[++i]);
      out.maxAnswersSet = true;
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
    } else if (arg === '--stop-mode' && args[i + 1]) {
      out.stopMode = args[++i];
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

async function processSession(client, session, maxRephrases, maxAnswers, debug, phase, stopMode, maxUsers) {
  const db = openDb();
  const state = getMonitorState(session.id, db);
  if (state?.stopRequested) {
    return { stopped: true, reason: 'stop_flag', detail: state.stoppedReason ?? 'manual' };
  }

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
  let newCount = 0;

  const txn = db.transaction(() => {
    for (const participant of responses.data) {
      const participantId = registerParticipant(session.id, participant.participant_id).participantId;
      for (const message of participant.messages) {
        if (message.role !== 'user') continue;
        if (phase === 2) {
          const answer = insertAnswerP2({
            sessionId: session.id,
            participantId,
            messageId: message.id,
            answerText: message.content,
          }, db);
          if (answer.stored) newCount += 1;
          continue;
        }
        const answer = insertAnswerP1({
          sessionId: session.id,
          participantId,
          messageId: message.id,
          answerText: message.content,
        }, db);
        if (!answer.stored) continue;
        insertRephrase({
          sessionId: session.id,
          participantId,
          answerId: answer.answerId,
          rephraseText: message.content,
          redactionNotes: null,
        }, db);
        newCount += 1;
      }
    }
  });

  txn();

  if (stopMode === 'users') {
    if (finishedCount >= maxUsers) {
      setMonitorStopRequested(session.id, `Reached ${maxUsers} finished participants`, db);
      return { stopped: true, reason: 'threshold', newCount, total: finishedCount };
    }
    return { stopped: false, newCount, total: finishedCount };
  }

  if (phase === 2) {
    const count = countAnswersP2ForSession(session.id, db);
    const target = maxAnswers ?? maxRephrases;
    if (count >= target) {
      setMonitorStopRequested(session.id, `Reached ${target} reflections`, db);
      return { stopped: true, reason: 'threshold', newCount, total: count };
    }
    return { stopped: false, newCount, total: count };
  }

  const rephrases = listRephrasesForSession(session.id, db);
  if (rephrases.length >= maxRephrases) {
    setMonitorStopRequested(session.id, `Reached ${maxRephrases} rephrases`, db);
    return { stopped: true, reason: 'threshold', newCount, total: rephrases.length };
  }

  return { stopped: false, newCount, total: rephrases.length };
}

async function main() {
  const {
    intervalMs,
    maxRephrases,
    maxAnswers,
    maxRephrasesSet,
    maxAnswersSet,
    maxUsers,
    maxUsersSet,
    stopMode,
    sessionId,
    stop,
    debug,
    phase,
  } = parseArgs();
  if (!sessionId) {
    console.error('Missing --session-id');
    process.exit(1);
  }
  if (![1, 2].includes(phase)) {
    console.error('Invalid --phase. Use 1 or 2.');
    process.exit(1);
  }
  if (!['users', 'answers'].includes(stopMode)) {
    console.error('Invalid --stop-mode. Use "users" or "answers".');
    process.exit(1);
  }
  if (stopMode === 'users' && !maxUsersSet) {
    console.error('Stop mode "users" requires --max-users.');
    process.exit(1);
  }
  if (stopMode === 'answers') {
    if (phase === 2 && !maxAnswersSet) {
      console.error('Phase 2 with stop-mode answers requires --max-answers.');
      process.exit(1);
    }
    if (phase === 2 && maxRephrasesSet) {
      console.error('Phase 2 does not accept --max-rephrases. Use --max-answers.');
      process.exit(1);
    }
  }

  if (stop) {
    if (!sessionId) {
      console.error('Provide --session-id when using --stop');
      process.exit(1);
    }
    setMonitorStopRequested(sessionId, 'manual stop');
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

  let targetLabel = 'max_users';
  let targetValue = maxUsers;
  if (stopMode === 'answers') {
    targetLabel = phase === 2 ? 'max_answers' : 'max_rephrases';
    targetValue = phase === 2 ? maxAnswers : maxRephrases;
  }
  console.log(`Session monitor running for ${sessionId}. phase=${phase} interval=${intervalMs / 1000}s stop_mode=${stopMode} ${targetLabel}=${targetValue}`);
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      const session = await fetchSession(client, sessionId);
      const result = await processSession(client, session, maxRephrases, maxAnswers, debug, phase, stopMode, maxUsers);
      if (result.stopped) {
        if (result.reason === 'stop_flag') {
          console.log(`[${session.id}] stopped: ${result.detail}`);
          console.log(`[${session.id}] stop flag set in DB. Exiting.`);
          process.exit(0);
        }
        console.log(`[${session.id}] stopped: ${result.reason}`);
        if (result.reason === 'threshold') {
          if (stopMode === 'users') {
            console.log(`[${session.id}] reached ${maxUsers} finished participants. Exiting.`);
          } else {
            const label = phase === 2 ? 'reflections' : 'rephrases';
            const target = phase === 2 ? maxAnswers : maxRephrases;
            console.log(`[${session.id}] reached ${target} ${label}. Exiting.`);
          }
          process.exit(0);
        }
        if (result.reason === 'manual') {
          console.log(`[${session.id}] manual stop requested. Exiting.`);
          process.exit(0);
        }
      } else if (result.newCount > 0) {
        if (stopMode === 'users') {
          console.log(`[${session.id}] stored ${result.newCount} new answers (finished=${result.total})`);
        } else {
          const label = phase === 2 ? 'reflections' : 'rephrases';
          console.log(`[${session.id}] stored ${result.newCount} new answers (total ${label}=${result.total})`);
        }
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
