import { advanceClock, systemId } from './game-clock.js';
import {
  applyCommand, chooseCommand, projectPlayer, seedFrom,
  type BotDifficulty, type CanonicalState, type RandomSource, type Transition,
} from '@island/game-engine';
import type { Command } from '@island/protocol/contracts';

export interface BotJob {
  roomId: string; phaseId: string; version: number; playerId: string; commandId: string;
}

export const BOT_DIFFICULTIES: readonly BotDifficulty[] = ['EASY', 'MEDIUM'];
export function botDifficulty(settings: unknown): BotDifficulty {
  const value = (settings as { botDifficulty?: unknown } | null)?.botDifficulty;
  return BOT_DIFFICULTIES.includes(value as BotDifficulty) ? (value as BotDifficulty) : 'MEDIUM';
}

/** Exactly what a seat may see: public state plus its own hand, nothing else. */
function viewFor(state: CanonicalState, playerId: string) {
  return { publicState: state.publicState, hand: projectPlayer(state, playerId) };
}

/**
 * Facts the seat legitimately knows that PublicState does not carry. Supplied
 * here because the server holds them; the policy never reads them directly.
 */
function hintsFor(state: CanonicalState) {
  return {
    developmentCardsRemaining: state.serverState.developmentDeck.length,
    pendingSetupVertexId: state.serverState.setup?.pendingVertexId ?? null,
    eligibleVictimIds: state.serverState.effect?.eligiblePlayerIds,
    bankStock: state.serverState.bank,
  };
}

/**
 * Automated seats owing a move right now.
 *
 * Required seats cover a bot's own turn and its share of a seven. A bot is also
 * woken for a trade offered to it while someone else holds the turn, because an
 * offer nobody ever answers leaves the proposer waiting on a seat that is not
 * going to speak.
 */
export function botJobs(state: CanonicalState, difficulty: BotDifficulty = 'MEDIUM'): BotJob[] {
  const p = state.publicState;
  if (p.pauseReasons.length || p.phase === 'COMPLETE') return [];
  const owed = Object.values(p.players)
    .filter(player => player.kind === 'BOT')
    .map(player => player.id)
    .filter(id => p.requiredPlayerIds.includes(id) || answersAnOffer(state, id, difficulty));
  return owed.map(playerId => ({
    roomId: state.roomId, phaseId: p.phaseId, version: state.version, playerId,
    // Version and phase both appear, so a job is unique to one saved state and
    // a retry replays the move the receipt already recorded.
    commandId: systemId(`bot:${state.roomId}:${p.phaseId}:${state.version}:${playerId}`),
  }));
}

function answersAnOffer(state: CanonicalState, playerId: string, difficulty: BotDifficulty): boolean {
  const move = chooseCommand(viewFor(state, playerId), hintsFor(state), difficulty, 0);
  return move !== null && (move.type === 'ACCEPT_TRADE' || move.type === 'DECLINE_TRADE');
}

export function matchesBotJob(state: CanonicalState, job: BotJob): boolean {
  return botJobs(state).some(current => current.commandId === job.commandId);
}

export interface BotMove { actor: string; command: Command; result: Transition }

/**
 * The seat's next move, or null when the policy finds nothing to do.
 *
 * Seeded from the room, version and phase rather than from the clock, so the
 * same saved state always yields the same command however often it is retried.
 */
export function botMove(
  state: CanonicalState, job: BotJob, difficulty: BotDifficulty, now: string, random: RandomSource,
): BotMove | null {
  const move = chooseCommand(
    viewFor(state, job.playerId), hintsFor(state), difficulty,
    seedFrom(state.roomId, state.version, state.publicState.phaseId, job.playerId),
  );
  if (!move) return null;
  const command: Command = {
    protocolVersion: 1, commandId: job.commandId, roomId: state.roomId,
    expectedVersion: state.version, expectedPhaseId: state.publicState.phaseId,
    type: move.type, payload: move.payload as Command['payload'],
  };
  const result = applyCommand(state, job.playerId, command, { now, random });
  return { actor: job.playerId, command, result: { ...result, state: advanceClock(state, result.state, now, random) } };
}
