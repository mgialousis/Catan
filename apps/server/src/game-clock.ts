import { createHash } from 'node:crypto';
import { applyCommand, assertInvariants, RecordedRandom, emptyResources, type CanonicalState, type WorkingState, type RandomSource, type Transition } from '@island/game-engine';
import type { Command, PublicState, Json } from '@island/protocol/contracts';

export type PauseReason = PublicState['pauseReasons'][number];
export interface TimerJob { roomId: string; phaseId: string; generation: string; deadline: string; playerId: string | null; commandId: string }
export function systemId(value: string): string {
  const h = createHash('sha256').update(value).digest('hex');
  return `${h.slice(0,8)}-${h.slice(8,12)}-5${h.slice(13,16)}-a${h.slice(17,20)}-${h.slice(20,32)}`;
}
const ms = (value: string) => Date.parse(value);
const iso = (value: number) => new Date(value).toISOString();
const remaining = (deadline: string, budget: number, now: string) => Math.max(0, Math.min(budget, ms(deadline) - ms(now)));
export function nextDeadline(state: CanonicalState): string | null {
  if (state.publicState.pauseReasons.length || state.publicState.phase === 'COMPLETE') return null;
  const times = [state.clockState.deadline, ...Object.values(state.clockState.discards).map(d => d.deadline)].filter((t): t is string => t !== null);
  return times.sort()[0] ?? null;
}
function publish(state: WorkingState): void {
  state.publicState.turnDeadline = state.clockState.deadline;
  state.publicState.discardDeadlines = Object.fromEntries(Object.entries(state.clockState.discards).flatMap(([id,d]) => d.deadline ? [[id,d.deadline]] : []));
}
/** Invoked after a real engine move, with database time sampled under its locks. */
export function advanceClock(previous: CanonicalState, next: CanonicalState, now: string, random: RandomSource): CanonicalState {
  const state = structuredClone(next) as WorkingState, c = state.clockState, p = state.publicState;
  if (c.turnLimitSeconds === null || p.turnNumber === 0 || p.phase === 'COMPLETE') {
    c.deadline = null; c.discards = {}; publish(state); return state;
  }
  if (p.turnNumber !== previous.publicState.turnNumber) {
    c.remainingTurnMs = c.turnLimitSeconds * 1000; c.deadline = iso(ms(now) + c.remainingTurnMs); c.discards = {}; c.generation = random.id();
  } else if (p.phase === 'DISCARD_REQUIRED') {
    if (previous.publicState.phase !== 'DISCARD_REQUIRED') {
      c.remainingTurnMs = c.deadline ? remaining(c.deadline, c.remainingTurnMs!, now) : c.remainingTurnMs;
      c.deadline = null; c.generation = random.id();
      c.discards = Object.fromEntries(p.requiredPlayerIds.map(id => [id, { deadline: iso(ms(now) + 30000), remainingMs: 30000, generation: random.id() }]));
    } else for (const id of Object.keys(c.discards)) if (!p.requiredPlayerIds.includes(id)) delete c.discards[id];
  } else if (previous.publicState.phase === 'DISCARD_REQUIRED') {
    c.discards = {}; c.deadline = iso(ms(now) + c.remainingTurnMs!); c.generation = random.id();
  }
  publish(state); return state;
}
/** Pause/resume changes neither turn/phase identity nor the inventory. */
export function pauseState(previous: CanonicalState, reasons: PauseReason[], now: string, random: RandomSource): CanonicalState {
  const state = structuredClone(previous) as WorkingState, c = state.clockState;
  const wasPaused = previous.publicState.pauseReasons.length > 0;
  if (!wasPaused && reasons.length) {
    if (c.deadline) c.remainingTurnMs = remaining(c.deadline, c.remainingTurnMs!, now);
    c.deadline = null;
    for (const d of Object.values(c.discards)) { if (d.deadline) d.remainingMs = remaining(d.deadline, d.remainingMs, now); d.deadline = null; d.generation = random.id(); }
  } else if (wasPaused && !reasons.length && c.turnLimitSeconds !== null && state.publicState.turnNumber > 0 && state.publicState.phase !== 'COMPLETE') {
    if (state.publicState.phase === 'DISCARD_REQUIRED') {
      for (const d of Object.values(c.discards)) { d.deadline = iso(ms(now) + d.remainingMs); d.generation = random.id(); }
    } else c.deadline = iso(ms(now) + c.remainingTurnMs!);
  }
  c.generation = random.id(); state.publicState.pauseReasons = [...new Set(reasons)].sort(); state.version++;
  publish(state); assertInvariants(state); return state;
}
export function timerJobs(state: CanonicalState): TimerJob[] {
  if (state.publicState.pauseReasons.length || state.publicState.phase === 'COMPLETE' || state.clockState.turnLimitSeconds === null) return [];
  const contexts = state.clockState.deadline ? [{ playerId: null, deadline: state.clockState.deadline, generation: state.clockState.generation }] : Object.entries(state.clockState.discards).flatMap(([playerId,d]) => d.deadline ? [{playerId,deadline:d.deadline,generation:d.generation}] : []);
  return contexts.map(c => ({ ...c, roomId: state.roomId, phaseId: state.publicState.phaseId, commandId: systemId(`timer:${state.roomId}:${state.publicState.phaseId}:${c.playerId}:${c.generation}:${c.deadline}`) }));
}
export function dueFor(state: CanonicalState, playerId: string, now: string): boolean {
  return timerJobs(state).some(job => (job.playerId === null || job.playerId === playerId) && ms(job.deadline) <= ms(now));
}
export function matchesJob(state: CanonicalState, job: TimerJob): boolean { return timerJobs(state).some(current => (Object.keys(current) as (keyof TimerJob)[]).every(key => current[key] === job[key])); }

export interface Fallback { actor: string; command: Command; result: Transition; selectionDraws: RecordedRandom['draws'] }
/** One mandatory fallback. The transaction coordinator bounds and commits its continuation. */
export function fallback(previous: CanonicalState, jobId: string, step: number, now: string, random: RandomSource, discarder?: string): Fallback {
  const state = structuredClone(previous) as WorkingState, p = state.publicState, selection = new RecordedRandom(random);
  let type: string, payload: Record<string, Json> = {}, actor = discarder ?? p.activePlayerId;
  if (discarder) {
    type = 'DISCARD_RESOURCES'; const hand = { ...state.privateState[actor]!.resources }, chosen = emptyResources();
    for (let n = 0; n < state.privateState[actor]!.discardRequired; n++) {
      let index = selection.int(Object.values(hand).reduce((a,b) => a+b, 0), 'timeout-discard');
      for (const resource of Object.keys(hand) as (keyof typeof hand)[]) {
        if (index < hand[resource]) { hand[resource]--; chosen[resource]++; break; } index -= hand[resource];
      }
    }
    payload = { resources: chosen };
  } else {
    state.clockState.turnExpired = true; state.clockState.remainingTurnMs = 0;
    switch (p.phase) {
      case 'AWAIT_ROLL': type = 'ROLL_DICE'; break;
      case 'ACTION': type = 'END_TURN'; break;
      case 'ROAD_BUILDING': type = 'FINISH_FREE_ROADS'; break;
      case 'ROBBER_MOVE': {
        const hexes = Object.keys(p.board.hexes).filter(id => id !== p.robberHexId).sort();
        type = 'MOVE_ROBBER'; payload = { hexId: hexes[selection.int(hexes.length, 'timeout-robber')]! }; break;
      }
      case 'ROBBER_VICTIM': {
        const ids = [...state.serverState.effect!.eligiblePlayerIds].sort();
        type = 'CHOOSE_ROBBER_VICTIM'; payload = { victimPlayerId: ids[selection.int(ids.length, 'timeout-victim')]! }; break;
      }
      default: throw new Error('No mandatory fallback in this phase');
    }
  }
  const command: Command = { protocolVersion: 1, commandId: systemId(`${jobId}:${step}:${type}`), roomId: state.roomId, expectedVersion: state.version, expectedPhaseId: p.phaseId, type, payload };
  const result = applyCommand(state, actor, command, { now, random });
  return { actor, command, result: { ...result, state: advanceClock(state, result.state, now, random) }, selectionDraws: selection.draws };
}

/** Persisted clock validation is separate from the timer-free pure engine. */
export function assertClock(state: CanonicalState): void {
  const c = state.clockState, p = state.publicState;
  const check = (ok: unknown) => { if (!ok) throw new Error('Invalid persisted clock'); };
  const budget = (n: unknown, maximum: number) => typeof n === 'number' && Number.isInteger(n) && n >= 0 && n <= maximum;
  const date = (d: unknown) => d === null || (typeof d === 'string' && Number.isFinite(Date.parse(d)));
  check([null,60,120,180].includes(c.turnLimitSeconds)); check(typeof c.turnExpired === 'boolean');
  check(typeof c.generation === 'string' && /^[0-9a-f-]{36}$/i.test(c.generation));
  check(c.turnLimitSeconds === null ? c.remainingTurnMs === null : budget(c.remainingTurnMs,c.turnLimitSeconds*1000));
  check(date(c.deadline)); check(p.turnDeadline === c.deadline);
  const runningDiscards = Object.entries(c.discards).filter(([,d]) => d.deadline !== null);
  check(runningDiscards.length === Object.keys(p.discardDeadlines).length && runningDiscards.every(([id,d]) => p.discardDeadlines[id] === d.deadline));
  for (const [id,d] of Object.entries(c.discards)) {
    check(p.phase === 'DISCARD_REQUIRED' && p.requiredPlayerIds.includes(id)); check(date(d.deadline)); check(budget(d.remainingMs,30000)); check(/^[0-9a-f-]{36}$/i.test(d.generation));
  }
  if (c.turnLimitSeconds !== null && p.phase === 'DISCARD_REQUIRED') check(Object.keys(c.discards).length === p.requiredPlayerIds.length);
  if (p.pauseReasons.length || c.turnLimitSeconds === null || p.turnNumber === 0 || p.phase === 'COMPLETE') check(c.deadline === null && runningDiscards.length === 0);
  else if (p.phase === 'DISCARD_REQUIRED') check(c.deadline === null && runningDiscards.length === p.requiredPlayerIds.length);
  else check(c.deadline !== null && Object.keys(c.discards).length === 0);
}
