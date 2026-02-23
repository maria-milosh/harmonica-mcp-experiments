import { createHash } from 'crypto';

export function snapshotIdFromRephraseIds(ids: string[]): string {
  const joined = [...ids].sort().join('|');
  return createHash('sha256').update(joined).digest('hex').slice(0, 16);
}
