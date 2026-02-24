import { HarmonicaClient } from '../dist/client.js';
import { loadPilotConfig } from './pilot_config.mjs';

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    topic: null,
    goal: null,
    prompt: null,
    config: null,
  };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--topic' && args[i + 1]) {
      out.topic = args[++i];
    } else if (arg === '--goal' && args[i + 1]) {
      out.goal = args[++i];
    } else if (arg === '--prompt' && args[i + 1]) {
      out.prompt = args[++i];
    } else if (arg === '--config' && args[i + 1]) {
      out.config = args[++i];
    }
  }
  return out;
}

function buildPrompt(topic, description, optionLabels) {
  const options = Object.values(optionLabels || {});
  const list = options.length ? options.map((opt) => `- ${opt}`).join('\n') : '';
  return [
    `You are a neutral moderator helping understand a participant's position on the following topic: ${topic}. Your job is to understand which option this participant would choose and why.`,
    ``,
    description,
    options.length ? `\nOptions to discuss:\n${list}` : '',
    `Guide the conversation naturally. Ask the participant which option they would choose and invite them to explain their reasoning. You may ask one or two follow-up questions to draw out their thinking, but don't over-probe.

    The conversation is complete when the participant has:
    1. Clearly stated which option they vote for.
    2. Expressed their reasoning in at least a sentence or two.

    Once both conditions are met, thank the participant and close the conversation.

    Do not express your own opinion. Do not suggest that any option is better or worse than another. Stay neutral throughout.`
  ].join('\n').trim();
}

async function main() {
  const { topic, goal, prompt, config } = parseArgs();
  const apiKey = process.env.HARMONICA_API_KEY;
  if (!apiKey) {
    console.error('Missing HARMONICA_API_KEY');
    process.exit(1);
  }

  const pilot = loadPilotConfig(config ?? 'example_pilot.yaml');
  const baseTopic = topic ?? pilot?.pilotName ?? 'Pilot Session';
  const sessionTopic = baseTopic.startsWith('P1') ? baseTopic : `P1 ${baseTopic}`;
  const sessionGoal = goal ?? pilot?.topicDescription ?? 'Collect initial ideas and opinions.';
  const sessionPrompt = prompt ?? buildPrompt(baseTopic, pilot?.topicDescription ?? sessionGoal, pilot?.optionLabels ?? {});

  const client = new HarmonicaClient({
    baseUrl: process.env.HARMONICA_API_URL || 'https://app.harmonica.chat',
    apiKey,
  });

  const session = await client.createSession({
    topic: sessionTopic,
    goal: sessionGoal,
    prompt: sessionPrompt,
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
