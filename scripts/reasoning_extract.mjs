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

function buildTranscript(messages) {
  return messages
    .filter((m) => m.role === 'user')
    .map((m) => m.content)
    .map((text) => text.replace(/\s+/g, ' ').trim())
    .filter((text) => text.length > 0 && text !== 'User shared the following context:')
    .map((text) => `USER: ${text}`)
    .join('\n');
}

function buildPrompt(options, optionLabels, voteNullIfAmbiguous, transcript) {
  const optionList = options.map((opt) => `- ${opt}`).join('\n');
  const labelList = options.map((opt) => {
    const label = optionLabels?.[opt];
    return label ? `${opt}: ${label}` : `${opt}`;
  }).join('\n');
  return [
    `You are extracting a participant's vote and reasoning from a conversation transcript.`,
    `Return strictly a JSON object with keys "vote" and "reasoning" and no other text.`,
    ``,
    `Allowed vote options (return the exact key):`,
    optionList,
    ``,
    `Option labels for reference:`,
    labelList,
    ``,
    // voteNullIfAmbiguous
    //   ? `If the participant never clearly chose one option, set "vote" to null and "reasoning" to null.`
    //   : `If the participant never clearly chose one option, set "vote" to null and "reasoning" to null.`,
    // `If the participant expresses a preference (e.g., "prefer", "most beneficial", "priority", "I choose X"), treat that as a clear vote.`,
    `Reasoning must be a neutral 1-2 sentence written by you to rephrase why they chose that option, without personal attribution.`,
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

function normalizeVote(vote, options, optionLabels, voteNullIfAmbiguous) {
  if (vote == null) return null;
  const normalized = String(vote).trim();
  if (options.includes(normalized)) return normalized;

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

  const mapped = map.get(normalizeKey(normalized));
  if (mapped) return mapped;
  if (!voteNullIfAmbiguous) return null;
  return null;
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
  const participants = payload.participants ?? payload.data ?? [];
  const results = [];
  const raw = [];

  for (const participant of participants) {
    const transcript = buildTranscript(participant.messages ?? []);
    const prompt = buildPrompt(pilot.options, pilot.optionLabels, pilot.voteNullIfAmbiguous, transcript);
    const response = await callExtractor(apiUrl, apiKey, model, prompt);
    const text = extractTextFromResponse(response);
    if (!text) {
      throw new Error('No content returned by extractor.');
    }
    const parsed = parseJsonStrict(text);
    const vote = normalizeVote(parsed.vote, pilot.options, pilot.optionLabels, pilot.voteNullIfAmbiguous);
    const reasoning = vote ? parsed.reasoning ?? null : null;
    if (debug) {
      raw.push({
        user_id: participant.participant_id,
        session_id: resolvedSessionId,
        raw_text: text,
        parsed,
      });
    }
    results.push({
      user_id: participant.participant_id,
      session_id: sessionId,
      vote,
      reasoning,
      created_at: new Date().toISOString(),
    });
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
  console.log(`Wrote ${results.length} rows to ${outPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
