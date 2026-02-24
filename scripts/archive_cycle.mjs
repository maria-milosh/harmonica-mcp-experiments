import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';

function timestamp() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}_${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

function moveIfExists(src, destDir) {
  if (!fs.existsSync(src)) return;
  const dest = path.join(destDir, path.basename(src));
  fs.renameSync(src, dest);
}

function listResponseFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((f) => f.startsWith('phase1_') || f.startsWith('phase2_'))
    .map((f) => path.join(dir, f));
}

function parseArgs() {
  const args = process.argv.slice(2);
  const out = { label: null };
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--label' && args[i + 1]) out.label = args[++i];
  }
  return out;
}

async function main() {
  const { label } = parseArgs();
  const responsesDir = path.resolve('data', 'responses');
  const archiveRoot = path.resolve('data', 'archive');
  const dirName = label ? `${timestamp()}_${label}` : timestamp();
  const archiveDir = path.join(archiveRoot, dirName);

  ensureDir(archiveDir);
  const files = listResponseFiles(responsesDir);
  if (!files.length) {
    console.log('No phase response files found to archive.');
    return;
  }

  try {
    const status = execSync('node scripts/pilot_status.mjs --config example_pilot.yaml', {
      encoding: 'utf8',
    });
    fs.writeFileSync(path.join(archiveDir, 'pilot_status.txt'), status);
  } catch (err) {
    const message = err?.stdout || err?.stderr || String(err);
    fs.writeFileSync(path.join(archiveDir, 'pilot_status.txt'), message);
  }

  for (const file of files) {
    moveIfExists(file, archiveDir);
  }

  console.log(`Archived ${files.length} files to ${archiveDir}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
