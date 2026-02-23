import { HarmonicaClient } from '../dist/client.js';
import { listRephrasesForSession } from '../dist/experiment/store/repos/rephrases.js';
import { openDb } from '../dist/experiment/store/db.js';

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    sourceSessionId: null,
    topic: null,
    goal: null,
  };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--source-session' && args[i + 1]) {
      out.sourceSessionId = args[++i];
    } else if (arg === '--topic' && args[i + 1]) {
      out.topic = args[++i];
    } else if (arg === '--goal' && args[i + 1]) {
      out.goal = args[++i];
    }
  }
  return out;
}

function buildPrompt(topic, ideas) {
  const list = ideas.map((idea, idx) => `${idx + 1}. ${idea}`).join('\n');
  return [
    `You are a neutral facilitator guiding a reflective conversation. A group of people has been discussing ${topic}. You are speaking with one participant at a time.`,
    ``,
    `Your job in this conversation is to share what others in the group have said, and invite this participant to reflect on those ideas.`,
    `Below is a list of ideas shared by other participants, already rephrased for neutrality. Present them one at a time. For each idea:`,
    `* Introduce it simply, e.g. "Someone in your group shared the following idea:"`,
    `* State the idea.`,
    `* Ask the participant what they think — whether they agree, disagree, find it surprising, or whether it changes or adds to their own thinking.`,
    `* Wait for their response before moving to the next idea.`,
    `* You may ask one brief follow-up if their response is very short or unclear, but don't over-probe.`,
    `* Then move on to the next idea.`,
    `Once all ideas have been discussed, ask the participant to state their own opinion in 1-2 sentences. Then thank the participant and close the conversation.`,
    `Do not: editorialize, express your own opinion, suggest that any idea is better or worse than another, or reveal how many people held a particular view.`,
    ``,
    `Ideas to present:`,
    list,
  ].join('\n');
}

async function main() {
  const { sourceSessionId, topic, goal } = parseArgs();
  if (!sourceSessionId) {
    console.error('Missing --source-session');
    process.exit(1);
  }
  const apiKey = process.env.HARMONICA_API_KEY;
  if (!apiKey) {
    console.error('Missing HARMONICA_API_KEY');
    process.exit(1);
  }

  const db = openDb();
  const rephrases = listRephrasesForSession(sourceSessionId, db);
  if (!rephrases.length) {
    console.error('No rephrases found for source session.');
    process.exit(1);
  }
  const ideas = rephrases.map((r) => r.text);

  const client = new HarmonicaClient({
    baseUrl: process.env.HARMONICA_API_URL || 'https://app.harmonica.chat',
    apiKey,
  });
  const source = await client.getSession(sourceSessionId);
  const baseTopic = topic ?? source.topic.replace(/^P1\s*:?\s*/i, '');
  const sessionTopic = `P2 ${baseTopic}`;
  const sessionGoal = goal ?? `Reflect on ideas from ${baseTopic}`;

  const prompt = buildPrompt(baseTopic, ideas);
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
