import { isDeepStrictEqual } from 'node:util';
import { isValid } from '@island/protocol';
import { projectGame, type CanonicalState, type EngineEffect, projectEffects } from '@island/game-engine';

type Patch = { op: 'add' | 'replace' | 'remove'; path: string; value?: unknown };
/** Diff already authorized views only; arrays are replaced atomically. */
export function diffView(before: Record<string, unknown>, after: Record<string, unknown>, prefix = ''): Patch[] {
  const patches: Patch[] = [];
  for (const key of [...new Set([...Object.keys(before), ...Object.keys(after)])].sort()) {
    if (!/^[a-zA-Z0-9_-]{1,80}$/.test(key) || ['__proto__', 'prototype', 'constructor'].includes(key)) throw new Error('Unsafe patch key');
    const path = `${prefix}/${key}`, a = before[key], b = after[key];
    if (!Object.hasOwn(after, key)) patches.push({ op: 'remove', path });
    else if (!Object.hasOwn(before, key)) patches.push({ op: 'add', path, value: b });
    else if (!isDeepStrictEqual(a, b)) {
      if (a && b && typeof a === 'object' && typeof b === 'object' && !Array.isArray(a) && !Array.isArray(b)) patches.push(...diffView(a as Record<string, unknown>, b as Record<string, unknown>, path));
      else patches.push({ op: 'replace', path, value: b });
    }
  }
  return patches;
}
export function gameDelta(previous: CanonicalState, next: CanonicalState, playerId: string, effects: readonly EngineEffect[], serverTime: string) {
  const before = projectGame(previous, playerId, serverTime), after = projectGame(next, playerId, serverTime);
  const delta = { roomId: next.roomId, fromVersion: previous.version, toVersion: next.version,
    publicPatch: diffView(before.publicState as unknown as Record<string, unknown>, after.publicState as unknown as Record<string, unknown>),
    privatePatch: diffView(before.privateState as unknown as Record<string, unknown>, after.privateState as unknown as Record<string, unknown>),
    activity: projectEffects(effects, playerId).activity, serverTime };
  if (!isValid('gameDelta', delta)) throw new Error('Invalid game delta');
  return delta;
}

/** Sharing a public envelope is safe only while all recipient projections agree. */
export function commonView(views: readonly Record<string, unknown>[], privateKey: 'privateState' | 'privatePatch'): Record<string, unknown> {
  if (!views.length) throw new Error('Missing recipients');
  const common = views.map(view => { const copy = { ...view }; delete copy[privateKey]; return copy; });
  if (common.some(view => !isDeepStrictEqual(view, common[0]))) throw new Error('Recipient-dependent public projection');
  return common[0]!;
}
