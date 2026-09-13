import { randomInt, randomUUID } from 'node:crypto';
import type { EngineContext } from '@island/game-engine';

/** Backend-only entropy adapter. Never expose random draws or deck state on the wire. */
export function engineContext(): EngineContext {
  return { now: new Date().toISOString(), random: { int: upperExclusive => randomInt(upperExclusive), id: () => randomUUID() } };
}
