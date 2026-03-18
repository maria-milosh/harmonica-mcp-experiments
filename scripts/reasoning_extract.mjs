import fs from 'node:fs';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { loadPilotConfig } from './pilot_config.mjs';

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    sessionId: null,
    input: null,
    output: null,
    config: null,
    phase: null,
    debug: false,
  };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--session-id' && args[i + 1]) {
      out.sessionId = args[++i];
    } else if (arg === '--input' && args[i + 1]) {
      out.input = args[++i];
    } else if (arg === '--output' && args[i + 1]) {
      out.output = args[++i];
    } else if (arg === '--config' && args[i + 1]) {
      out.config = args[++i];
    } else if (arg === '--phase' && args[i + 1]) {
      out.phase = Number(args[++i]);
    } else if (arg === '--debug') {
      out.debug = true;
    }
  }
  return out;
}

function buildTranscript(messages, includeAssistant = false) {
  return messages
    .filter((m) => includeAssistant || m.role === 'user')
    .map((m) => ({
      role: m.role,
      content: String(m.content ?? '').replace(/\s+/g, ' ').trim(),
    }))
    .filter((m) => m.content.length > 0 && m.content !== 'User shared the following context:')
    .map((m) => `${String(m.role).toUpperCase()}: ${m.content}`)
    .join('\n');
}

function buildPhase1Prompt(options, optionLabels, transcript) {
  const optionList = options.map((opt) => `- ${opt}`).join('\n');
  const labelList = options.map((opt) => {
    const label = optionLabels?.[opt];
    return label ? `${opt}: ${label}` : `${opt}`;
  }).join('\n');
  return [
    `You are extracting a participant's vote ranking and reasoning behind their most preferred option from a conversation transcript.`,
    `Return strictly a JSON object with keys "vote_ranking" and "reasoning" and no other text.`,
    ``,
    `Allowed vote options (return the exact key):`,
    optionList,
    ``,
    `Option labels for reference:`,
    labelList,
    ``,
    `If the participant does not clearly provide a complete ranking across all options, set "vote_ranking" to null.`,
    `When the ranking is clear, "vote_ranking" must be an array containing every allowed option exactly once, ordered from most preferred to least preferred.`,
    `Reasoning behind their top choice must be a neutral 1-2 sentence written by you to rephrase why they chose their most preferred option, without personal attribution.`,
    ``,
    `Transcript:`,
    transcript,
  ].join('\n');
}

function buildPhase2Prompt(options, optionLabels, transcript) {
  const optionList = options.map((opt) => `- ${opt}`).join('\n');
  const labelList = options.map((opt) => {
    const label = optionLabels?.[opt];
    return label ? `${opt}: ${label}` : `${opt}`;
  }).join('\n');
  return [
    `You are extracting a participant's initial and final vote rankings and reasoning from a Phase 2 cross-pollination conversation transcript.`,
    `Return strictly a JSON object with keys "initial_vote_ranking", "initial_reasoning", "final_vote_ranking", and "final_reasoning" and no other text.`,
    ``,
    `Allowed vote options (return the exact key):`,
    optionList,
    ``,
    `Option labels for reference:`,
    labelList,
    ``,
    `The transcript includes assistant and user messages. Use the assistant turns to identify the two stages:`,
    `- "initial" means the participant's ranking and reasoning before cross-pollination begins.`,
    `- "final" means the participant's ranking and reasoning after cross-pollination, when they restate their view at the end.`,
    `For each ranking, return an array containing every allowed option exactly once, ordered from most preferred to least preferred.`,
    `If the participant does not clearly provide a complete initial ranking, set "initial_vote_ranking" to null and "initial_reasoning" to null.`,
    `If the participant does not clearly provide a complete final ranking, set "final_vote_ranking" to null and "final_reasoning" to null.`,
    `If the participant explicitly says their final view is unchanged, copy the initial ranking into "final_vote_ranking" and write a neutral 1-2 sentence "final_reasoning" that reflects that the reasoning remained the same or was reinforced.`,
    `Each reasoning field must be a neutral 1-2 sentence written by you without personal attribution.`,
    ``,
    `Transcript:`,
    transcript,
  ].join('\n');
}

function extractTextFromResponse(payload) {
  if (payload?.choices?.[0]?.message?.content) return payload.choices[0].message.content;
  if (payload?.choices?.[0]?.text) return payload.choices[0].text;
  if (payload?.output?.[0]?.content?.[0]?.text) return payload.output[0].content[0].text;
  return null;
}

function parseJsonStrict(text) {
  const trimmed = text.trim()
    .replace(/^```json\s*/i, '')
    .replace(/^```\s*/i, '')
    .replace(/```$/i, '')
    .trim();
  const match = trimmed.match(/\{[\s\S]*\}/);
  if (!match) {
    throw new Error('No JSON object found in extractor output.');
  }
  return JSON.parse(match[0]);
}

function normalizeKey(value) {
  return String(value).toLowerCase().replace(/[^a-z0-9]/g, '');
}

function buildOptionMap(options, optionLabels) {
  const map = new Map();
  for (const opt of options) {
    map.set(normalizeKey(opt), opt);
  }
  if (optionLabels) {
    for (const [key, label] of Object.entries(optionLabels)) {
      if (options.includes(key)) {
        map.set(normalizeKey(label), key);
      }
    }
  }
  return map;
}

function normalizeRankingValue(value, optionMap) {
  if (typeof value !== 'string') return null;
  return optionMap.get(normalizeKey(value.trim())) ?? null;
}

function parseRankingInput(ranking) {
  if (ranking == null) return null;
  if (Array.isArray(ranking)) return ranking;
  if (typeof ranking === 'string') {
    return ranking
      .split(/\s*(?:>|,|;|\n)\s*/g)
      .map((item) => item.trim())
      .filter(Boolean);
  }
  return null;
}

function normalizeVoteRanking(ranking, options, optionLabels, rankingNullIfAmbiguous) {
  const parts = parseRankingInput(ranking);
  if (!parts || parts.length === 0) return null;

  const optionMap = buildOptionMap(options, optionLabels);
  const normalized = parts.map((part) => normalizeRankingValue(part, optionMap));
  if (normalized.some((value) => value == null)) return null;

  const unique = Array.from(new Set(normalized));
  const complete = unique.length === options.length && options.every((opt) => unique.includes(opt));
  if (!complete) return null;

  if (!rankingNullIfAmbiguous) return unique;
  return unique;
}

function coerceParsedRanking(parsed) {
  if (parsed?.vote_ranking != null) return parsed.vote_ranking;
  if (parsed?.ranking != null) return parsed.ranking;
  if (parsed?.vote != null) return parsed.vote;
  return null;
}

function coercePhase2Ranking(parsed, keyPrefix) {
  if (parsed?.[`${keyPrefix}_vote_ranking`] != null) return parsed[`${keyPrefix}_vote_ranking`];
  if (parsed?.[`${keyPrefix}_ranking`] != null) return parsed[`${keyPrefix}_ranking`];
  if (parsed?.[`${keyPrefix}_vote`] != null) return parsed[`${keyPrefix}_vote`];
  return null;
}

function buildExtractionResult(parsed, resolvedPhase, pilot, resolvedSessionId, participantId) {
  if (resolvedPhase === 2) {
    const initialVoteRanking = normalizeVoteRanking(
      coercePhase2Ranking(parsed, 'initial'),
      pilot.options,
      pilot.optionLabels,
      pilot.rankingNullIfAmbiguous,
    );
    const finalVoteRanking = normalizeVoteRanking(
      coercePhase2Ranking(parsed, 'final'),
      pilot.options,
      pilot.optionLabels,
      pilot.rankingNullIfAmbiguous,
    );
    return {
      user_id: participantId,
      session_id: resolvedSessionId,
      initial_vote_ranking: initialVoteRanking,
      initial_reasoning: initialVoteRanking ? parsed.initial_reasoning ?? null : null,
      final_vote_ranking: finalVoteRanking,
      final_reasoning: finalVoteRanking ? parsed.final_reasoning ?? null : null,
      created_at: new Date().toISOString(),
    };
  }

  const voteRanking = normalizeVoteRanking(
    coerceParsedRanking(parsed),
    pilot.options,
    pilot.optionLabels,
    pilot.rankingNullIfAmbiguous,
  );
  return {
    user_id: participantId,
    session_id: resolvedSessionId,
    vote_ranking: voteRanking,
    reasoning: voteRanking ? parsed.reasoning ?? null : null,
    created_at: new Date().toISOString(),
  };
}

async function callExtractor(apiUrl, apiKey, model, prompt) {
  const res = await fetch(apiUrl, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model,
      temperature: 0,
      messages: [
        { role: 'system', content: 'Return only JSON.' },
        { role: 'user', content: prompt },
      ],
    }),
  });

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`Extractor API error: ${res.status} ${body}`);
  }

  return res.json();
}

async function main() {
  const { sessionId, input, output, config, phase, debug } = parseArgs();
  if (!sessionId && !input) {
    console.error('Provide --session-id or --input');
    process.exit(1);
  }

  const pilot = loadPilotConfig(config ?? 'example_pilot.yaml');
  if (!pilot?.options || pilot.options.length === 0) {
    console.error('No topic.options found in pilot config.');
    process.exit(1);
  }

  const apiUrl = process.env.EXTRACTION_API_URL ?? 'https://api.openai.com/v1/chat/completions';
  const apiKey = process.env.EXTRACTION_API_KEY ?? process.env.OPENAI_API_KEY;
  const model = pilot.extractionModel ?? pilot.defaultModel;
  if (!apiKey) {
    console.error('Missing EXTRACTION_API_KEY or OPENAI_API_KEY');
    process.exit(1);
  }
  if (!model) {
    console.error('Missing extraction model in config (extraction.model or model).');
    process.exit(1);
  }

  let resolvedSessionId = sessionId;
  let resolvedPhase = phase;
  if (input && (!resolvedSessionId || !resolvedPhase)) {
    const base = path.basename(input);
    const match = base.match(/^phase(\d+)_([^\.]+)\.json$/);
    if (match) {
      resolvedPhase = resolvedPhase ?? Number(match[1]);
      resolvedSessionId = resolvedSessionId ?? match[2];
    }
  }
  if (!resolvedPhase) {
    console.error('Provide --phase (e.g., 1 or 2) or use --input with a phase-prefixed filename.');
    process.exit(1);
  }
  if (!resolvedSessionId) {
    console.error('Provide --session-id or use --input with a phase-prefixed filename.');
    process.exit(1);
  }

  const inPath = input ?? path.resolve('data', 'responses', `phase${resolvedPhase}_${resolvedSessionId}.json`);
  const outPath = output ?? path.resolve('data', 'responses', `phase${resolvedPhase}_${resolvedSessionId}_extractions.json`);
  if (!fs.existsSync(inPath)) {
    console.error(`Input not found: ${inPath}`);
    process.exit(1);
  }

  const payload = JSON.parse(fs.readFileSync(inPath, 'utf8'));
  const allParticipants = payload.participants ?? payload.data ?? [];
  const hasActiveField = allParticipants.some((participant) =>
    Object.prototype.hasOwnProperty.call(participant, 'active'));
  const participants = hasActiveField
    ? allParticipants.filter((participant) => participant?.active === false)
    : allParticipants;
  const results = [];
  const raw = [];

  for (const participant of participants) {
    const transcript = buildTranscript(participant.messages ?? [], resolvedPhase === 2);
    const prompt = resolvedPhase === 2
      ? buildPhase2Prompt(pilot.options, pilot.optionLabels, transcript)
      : buildPhase1Prompt(pilot.options, pilot.optionLabels, transcript);
    const response = await callExtractor(apiUrl, apiKey, model, prompt);
    const text = extractTextFromResponse(response);
    if (!text) {
      throw new Error('No content returned by extractor.');
    }
    const parsed = parseJsonStrict(text);
    if (debug) {
      raw.push({
        user_id: participant.participant_id,
        session_id: resolvedSessionId,
        raw_text: text,
        parsed,
      });
    }
    results.push(buildExtractionResult(
      parsed,
      resolvedPhase,
      pilot,
      resolvedSessionId,
      participant.participant_id,
    ));
    if (pilot.apiSleepSeconds) {
      await sleep(pilot.apiSleepSeconds * 1000);
    }
  }

  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(results, null, 2));
  if (debug) {
    const rawPath = outPath.replace(/_extractions\.json$/, '_extractions_raw.json');
    fs.writeFileSync(rawPath, JSON.stringify(raw, null, 2));
  }
  console.log(
    `Wrote ${results.length} rows to ${outPath} `
    + `(processed ${participants.length}/${allParticipants.length} participants: finished only).`,
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
