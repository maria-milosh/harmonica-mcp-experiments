import fs from 'node:fs';
import path from 'node:path';
import { HarmonicaClient } from '../dist/client.js';
import { loadPilotConfig } from './pilot_config.mjs';

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    sourceSessionId: null,
    topic: null,
    goal: null,
    config: null,
    extractions: null,
  };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--source-session' && args[i + 1]) {
      out.sourceSessionId = args[++i];
    } else if (arg === '--topic' && args[i + 1]) {
      out.topic = args[++i];
    } else if (arg === '--goal' && args[i + 1]) {
      out.goal = args[++i];
    } else if (arg === '--config' && args[i + 1]) {
      out.config = args[++i];
    } else if (arg === '--extractions' && args[i + 1]) {
      out.extractions = args[++i];
    }
  }
  return out;
}

function buildPrompt(topic, description, optionLabels, ideas) {
  const optionList = Object.values(optionLabels || {});
  const optionLines = optionList.map((opt) => `- ${opt}`).join('\n');
  const ideasList = ideas.map((idea, idx) => `${idx + 1}. ${idea}`).join('\n');
  return [
    `You are a neutral moderator helping understand a participant's position on the following topic: ${topic}. You are speaking with one participant at a time. Progress the conversation in two parts.`,
    ``,
    `PART 1 — Understand this participant's view
    Start by understanding which option this participant would choose and why.

    The options are:`,
    description,
    optionList.length ? `\nOptions to discuss:\n${optionLines}` : '',
    `Guide the conversation naturally. Ask the participant which option they would choose and invite them to explain their reasoning. You may ask one or two follow-up questions to draw out their thinking, but don't over-probe.

    Move to Part 2 when the participant has:
    1. Clearly stated which option they vote for.
    2. Expressed their reasoning in at least a sentence or two.

    ---

    PART 2 — Cross-pollination

    Now share what other participants in this session have said, and invite reflection.

    Below is a list of neutral rephrasings of other participants' reasoning. Present them one at a time. For each idea:
    - Introduce it simply, e.g. "Someone in your group shared the following idea:"
    - State the idea.
    - Ask the participant what they think — whether they agree, disagree, find it surprising, or whether it changes or adds to their own thinking.
    - Wait for their response before moving to the next idea.
    - You may ask one brief follow-up if their response is very short or unclear, but don't over-probe.
    - Then move on to the next idea.

    Once all ideas have been discussed, ask the participant to restate their vote and reasoning in 1-2 sentences — it may have changed. Then thank the participant and close the conversation.
    ---
    Do not express your own opinion. Do not suggest that any option is better or worse than another. Stay neutral throughout.`,
    ``,
    `Only conclude the session after the participant has responded with their final vote and reasoning.`,
    ``,
    `Rephrasings to present:`,
    ideasList,
  ].join('\n');
}

async function main() {
  const { sourceSessionId, topic, goal, config, extractions } = parseArgs();
  if (!sourceSessionId) {
    console.error('Missing --source-session');
    process.exit(1);
  }
  const apiKey = process.env.HARMONICA_API_KEY;
  if (!apiKey) {
    console.error('Missing HARMONICA_API_KEY');
    process.exit(1);
  }

  const inPath = extractions ?? path.resolve('data', 'responses', `phase1_${sourceSessionId}_extractions.json`);
  if (!fs.existsSync(inPath)) {
    console.error(`Extractions not found: ${inPath}`);
    process.exit(1);
  }
  const rows = JSON.parse(fs.readFileSync(inPath, 'utf8'));
  const ideas = rows
    .map((row) => row.reasoning)
    .filter((text) => typeof text === 'string' && text.trim().length > 0);
  if (!ideas.length) {
    console.error('No reasoning texts found in extractions.');
    process.exit(1);
  }
  const pilot = loadPilotConfig(config ?? 'example_pilot.yaml');

  const client = new HarmonicaClient({
    baseUrl: process.env.HARMONICA_API_URL || 'https://app.harmonica.chat',
    apiKey,
  });
  const source = await client.getSession(sourceSessionId);
  const baseTopic = topic ?? pilot?.pilotName ?? source.topic.replace(/^P1\s*:?\s*/i, '');
  const sessionTopic = `P2 ${baseTopic}`;
  const sessionGoal = goal ?? pilot?.topicDescription ?? `Reflect on ideas from ${baseTopic}`;

  const promptTopic = pilot?.topicDescription ?? baseTopic;
  const prompt = buildPrompt(
    promptTopic,
    pilot?.topicDescription ?? sessionGoal,
    pilot?.optionLabels ?? {},
    ideas,
  );
  const session = await client.createSession({
    topic: sessionTopic,
    goal: sessionGoal,
    prompt,
  });

  console.log('Session created:');
  console.log(`  Topic:    ${session.topic}`);
  console.log(`  ID:       ${session.id}`);
  console.log(`  Status:   ${session.status}`);
  console.log(`  Join URL: ${session.join_url}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
