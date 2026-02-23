import Database from 'better-sqlite3';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

let dbInstance: Database.Database | null = null;

function getDataDir(): string {
  const configured = process.env.CROSSPOLL_DATA_DIR;
  if (configured && configured.trim().length > 0) {
    return path.resolve(configured);
  }
  return path.resolve(process.cwd(), 'data', 'crosspoll');
}

function ensureDataDir(dir: string) {
  fs.mkdirSync(dir, { recursive: true });
}

function getDbPath(): string {
  return path.join(getDataDir(), 'crosspoll.sqlite');
}

function runMigrations(db: Database.Database) {
  db.exec(`CREATE TABLE IF NOT EXISTS migrations (
    id TEXT PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
  );`);

  const currentFile = fileURLToPath(import.meta.url);
  const migrationsDir = path.resolve(path.dirname(currentFile), 'migrations');
  const files = fs.readdirSync(migrationsDir)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  const applied = new Set<string>();
  for (const row of db.prepare('SELECT id FROM migrations').all() as { id: string }[]) {
    applied.add(row.id);
  }

  for (const file of files) {
    if (applied.has(file)) continue;
    const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
    db.exec(sql);
    db.prepare('INSERT INTO migrations (id) VALUES (?)').run(file);
  }
}

export function openDb(): Database.Database {
  if (dbInstance) return dbInstance;
  const dataDir = getDataDir();
  ensureDataDir(dataDir);

  const db = new Database(getDbPath());
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  runMigrations(db);

  dbInstance = db;
  return dbInstance;
}

export function getDataDirectory(): string {
  return getDataDir();
}
