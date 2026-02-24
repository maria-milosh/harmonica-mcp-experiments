import fs from 'node:fs';

function readBlock(text, key) {
  const re = new RegExp(`${key}:\\s*\\|\\n((?:\\s{4}.*\\n)+)`, 'm');
  const match = text.match(re);
  if (!match) return null;
  return match[1].split('\n')
    .map((line) => line.replace(/^ {4}/, ''))
    .join('\n')
    .trim();
}

function readList(text, key) {
  const re = new RegExp(`^${key}:\\s*\\n((?:\\s{2,4}-\\s*[^\\n]+\\n)+)`, 'm');
  const match = text.match(re);
  if (!match) return [];
  return match[1].trim().split('\n')
    .map((line) => line.replace(/^\s{2,4}-\s*/, '').trim())
    .filter(Boolean);
}

function readNestedBlock(text, parentKey) {
  const re = new RegExp(`^${parentKey}:\\s*\\n((?:\\s{2,4}.*\\n)+)`, 'm');
  const match = text.match(re);
  if (!match) return null;
  return match[1].split('\n').map((line) => line.replace(/^\s{2}/, '')).join('\n');
}

function readScalar(text, key) {
  const re = new RegExp(`^${key}:\\s*"?([^"\\n#]+)"?`, 'm');
  const match = text.match(re);
  return match ? match[1].trim() : null;
}

function readMap(text, key) {
  const re = new RegExp(`^${key}:\\s*\\n((?:\\s{4}[^\\n]+\\n)+)`, 'm');
  const match = text.match(re);
  if (!match) return {};
  const lines = match[1].trim().split('\n');
  const out = {};
  for (const line of lines) {
    const m = line.match(/^\s{4}([^:]+):\s*"?([^"]+)"?$/);
    if (m) out[m[1].trim()] = m[2].trim();
  }
  return out;
}

function readNestedScalar(text, parentKey, childKey) {
  const block = readNestedBlock(text, parentKey);
  if (!block) return null;
  return readScalar(block, childKey);
}

function readNestedList(text, parentKey, childKey) {
  const block = readNestedBlock(text, parentKey);
  if (!block) return [];
  return readList(block, childKey);
}

function readNestedMap(text, parentKey, childKey) {
  const block = readNestedBlock(text, parentKey);
  if (!block) return {};
  return readMap(block, childKey);
}

export function loadPilotConfig(path) {
  if (!path || !fs.existsSync(path)) return null;
  const text = fs.readFileSync(path, 'utf8');
  const description = readBlock(text, 'description');
  const pilotName = readScalar(text, 'pilot_name');
  const pilotId = readScalar(text, 'pilot_id');
  const expected = readScalar(text, 'expected_participants');
  const options = readNestedList(text, 'topic', 'options');
  const extractionModel = readNestedScalar(text, 'extraction', 'model');
  const rephrasingModel = readNestedScalar(text, 'extraction', 'rephrasing_model');
  const voteNullIfAmbiguous = readNestedScalar(text, 'extraction', 'vote_null_if_ambiguous');
  const apiSleepSeconds = readScalar(text, 'api_sleep_seconds');
  const defaultModel = readScalar(text, 'model');
  const optionLabels = readNestedMap(text, 'topic', 'option_labels');
  return {
    pilotId,
    pilotName,
    expectedParticipants: expected ? Number(expected) : null,
    topicDescription: description,
    options,
    extractionModel: extractionModel ?? null,
    rephrasingModel: rephrasingModel ?? null,
    defaultModel: defaultModel ?? null,
    apiSleepSeconds: apiSleepSeconds ? Number(apiSleepSeconds) : null,
    voteNullIfAmbiguous: voteNullIfAmbiguous === 'true',
    optionLabels,
  };
}
