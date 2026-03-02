import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.resolve(__dirname, '..');
const PORT = Number(process.env.PORT || 8000);
const DEFAULT_CONFIG = process.env.PILOT_CONFIG || 'example_pilot.yaml';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.txt': 'text/plain; charset=utf-8',
};

function send(res, status, body, type = 'text/plain; charset=utf-8') {
  res.writeHead(status, {
    'Content-Type': type,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function safePath(urlPath) {
  const clean = urlPath.replace(/\?.*$/, '');
  const target = clean === '/' ? '/demo_landing.html' : clean;
  const resolved = path.resolve(ROOT, `.${target}`);
  if (!resolved.startsWith(ROOT)) return null;
  return resolved;
}

function handleStatus(res, url) {
  const config = url.searchParams.get('config') || DEFAULT_CONFIG;
  const scriptPath = path.resolve(ROOT, 'scripts', 'pilot_status.mjs');
  execFile(
    process.execPath,
    [scriptPath, '--config', config],
    { cwd: ROOT, env: process.env },
    (err, stdout, stderr) => {
      if (err) {
        const message = stderr?.trim() || err.message || 'Failed to run pilot_status';
        send(res, 500, message);
        return;
      }
      send(res, 200, stdout, 'text/plain; charset=utf-8');
    }
  );
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname === '/api/status') {
    handleStatus(res, url);
    return;
  }

  const filePath = safePath(url.pathname);
  if (!filePath) {
    send(res, 403, 'Forbidden');
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      send(res, 404, 'Not found');
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    send(res, 200, data, MIME[ext] || 'application/octet-stream');
  });
});

server.listen(PORT, () => {
  console.log(`dev_server: http://localhost:${PORT}/demo_landing.html`);
  console.log(`dev_server: status at http://localhost:${PORT}/api/status`);
});
