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
    printPrompt: false,
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
    } else if (arg === '--print-prompt') {
      out.printPrompt = true;
    }
  }
  return out;
}

function buildPrompt(topic, description, optionLabels, ideas) {
  const optionList = Object.values(optionLabels || {});
  const optionLines = optionList.map((opt) => `- ${opt}`).join('\n');
  const ideasList = ideas.map((idea, idx) => `${idx + 1}. ${idea}`).join('\n');
  return [
    `You are a neutral moderator helping understand a participant's position on the following topic: ${topic}. You are speaking with one participant at a time. Your job is to understand how this participant ranks the options initially and after exposure to others' opinions, and why. Progress the conversation in two parts.`,
    `Discussion happens in this context:`,
    description,
    optionList.length ? `\nOptions to discuss:\n${optionLines}` : '',
    `PART 1 — Understand this participant's initial ranking.`,
    `Start by understanding how this participant would rank all options and why.`,
    `Guide the conversation naturally and be curious. First, remind the participants about the task. Then ask the participant to share any immediate reflections about the projects - is there any option that stands out? Help them reflect, if needed, and ask clarifying questions. Then ask them to rank all options from most preferred to least preferred, for example in a format like "Option B > Option A > Option C". Then invite them to explain their reasoning behind their top choice - why is it better than others. You may ask one or two follow-up questions to draw out their thinking, but don't over-probe.

    Move to Part 2 when the participant has:
    1. Clearly stated a full ranking across all options.
    2. Expressed their reasoning for the top choice in at least a sentence or two.

    ---

    PART 2 — Cross-pollination.

    Now share what other participants in this session have said, and invite reflection.

    Below is a list of neutral rephrasings of other participants' reasoning. Present them one at a time. For each idea:
    - Introduce it simply, e.g. "Someone in your group shared the following idea:"
    - State the idea.
    - Ask the participant what they think — whether they agree, disagree, find it surprising, or whether it changes or adds to their own thinking.
    - Wait for their response before moving to the next idea.
    - You may ask one brief follow-up if their response is very short or unclear, but don't over-probe.
    - Then move on to the next idea.

    Once all ideas have been discussed, proceed to the next part.
    ---

    PART 1 — Understand this participant's ranking after cross-pollination.
    Now that they reflected on others' reasonings, ask the participant to rank all options from most preferred to least preferred. Then invite them to explain their reasoning behind their top choice — it may have changed. Then thank the participant and close the conversation.
    IMPORTANT: Only conclude the session after the participant has responded with their final ranking and reasoning.
    
    ---
    Do not express your own opinion. Do not suggest that any option is better or worse than another. Stay neutral throughout.`,
    `Opinions to present in Part 2:`,
    ideasList,
  ].join('\n');
}

async function main() {
  const { sourceSessionId, topic, goal, config, extractions, printPrompt } = parseArgs();
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

  const promptTopic = pilot?.pilotName ?? baseTopic;
  const prompt = buildPrompt(
    promptTopic,
    pilot?.topicDescription ?? sessionGoal,
    pilot?.optionLabels ?? {},
    ideas,
  );
  if (printPrompt) {
    console.log(prompt);
    process.exit(0);
  }
  const session = await client.createSession({
    topic: sessionTopic,
    goal: sessionGoal,
    prompt,
  });

  const outDir = path.resolve('data', 'responses');
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'phase2_current.txt'), session.id);

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
