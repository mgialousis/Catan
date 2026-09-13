import { isValid, type SafeError } from '@island/protocol';
export function safeError(code: string, requestId?: unknown): SafeError {
  const messages: Record<string, string> = {
    UNAUTHENTICATED: 'Please reconnect to authenticate.', TOKEN_EXPIRED: 'Your session needs to refresh.',
    INVALID_PAYLOAD: 'The request format is invalid.', PROTOCOL_UNSUPPORTED: 'Please update the client.',
    FORBIDDEN: 'This room is unavailable.', RATE_LIMITED: 'Please wait before trying again.',
    NOT_IMPLEMENTED: 'This action arrives in a later phase.',
    INVALID_NICKNAME: 'Use 2–20 characters, without control or invisible characters.',
    ROOM_UNAVAILABLE: 'That invitation or table is unavailable. Check the code or ask the host.',
    ROOM_FULL: 'All four seats are taken.', NAME_TAKEN: 'Someone at this table already uses that nickname.',
    COLOUR_TAKEN: 'That colour is already taken.', STALE_VERSION: 'The table changed. Review it and try again.',
    GAME_ALREADY_STARTED: 'This lobby is no longer open.', PLAYERS_NOT_READY: 'Starting requires 3–4 connected, ready players.',
    TIMED_MODE_UNAVAILABLE: 'This time-limit setting is unavailable. Review the table settings and try again.',
    GAME_NOT_AVAILABLE: 'The game is not available at this table.',
    MEMBERSHIP_ENDED: 'You have left this table.', COMMAND_ID_REUSED: 'This request ID was already used for a different action.',
    RECEIPT_EXPIRED: 'This old request is no longer available. Refresh your table.', SERVICE_UNAVAILABLE: 'Please try again shortly.',
  };
  return { code, message: messages[code] ?? 'The request could not be completed.',
    retryable: ['TOKEN_EXPIRED', 'RATE_LIMITED', 'SERVICE_UNAVAILABLE'].includes(code),
    ...(isValid('uuid', requestId) ? { requestId: requestId as string } : {}) };
}
