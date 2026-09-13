import { createHash, randomBytes } from 'node:crypto';

const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const segments = new Intl.Segmenter('und', { granularity: 'grapheme' });
export class LobbyError extends Error {
  constructor(readonly code: string) { super(code); }
}
export function nickname(value: string): { name: string; key: string } {
  // NFKC also prevents compatibility-width characters bypassing duplicate checks.
  if (/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(value)) throw new LobbyError('INVALID_NICKNAME');
  const name = value.normalize('NFKC').trim().replace(/ +/g, ' ');
  const length = [...segments.segment(name)].length;
  if (length < 2 || length > 20 || /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(name) || name.length > 160) throw new LobbyError('INVALID_NICKNAME');
  return { name, key: name.toLowerCase() };
}
export function normalizeCode(value: string): string {
  const code = value.toUpperCase().replace(/[\s-]/g, '');
  if (!/^[0-9A-HJKMNP-TV-Z]{10}$/.test(code)) throw new LobbyError('ROOM_UNAVAILABLE');
  return code;
}
export function invitation(): string { return [...randomBytes(10)].map(byte => alphabet[byte & 31]).join(''); }
export function hash(value: string): string { return createHash('sha256').update(value).digest('hex'); }
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical((value as Record<string, unknown>)[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
export function startEligibility(players: readonly { id: string; ready: boolean; colour: string | null }[], online: ReadonlySet<string>): void {
  if (players.length < 3 || players.length > 4 || players.some(player => !player.ready || !player.colour || !online.has(player.id)) || new Set(players.map(player => player.colour)).size !== players.length) throw new LobbyError('PLAYERS_NOT_READY');
}
