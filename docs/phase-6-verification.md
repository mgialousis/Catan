# Phase 6 verification — timers and session recovery

Verified on 2026-09-13. Scope: Phase 6 only, using one agent and the existing local, free services. No hosted deployment, paid resources or store publication. Claude's Round 4 review and Phase 4 progress document are preserved; the earlier review dispositions remain in the Phase 5 evidence.

## Implemented behavior

The lobby now accepts Off/60/120/180-second turns. Initial settlement/road placement stays untimed. A turn gets one budget on entering `AWAIT_ROLL`; rolling, development effects and normal actions retain its deadline. A seven suspends that budget and gives each required discarder an independent 30-second window. Timer Off also disables discard expiry.

The backend clock policy is isolated in `apps/server/src/game-clock.ts`. Database time sampled under the room/game locks decides expiry. A due move loses to the deadline. Jobs use a stable hash-derived ID containing room, phase, clock generation, deadline and optional discard actor; early jobs leave no receipt, and stale/duplicate jobs do nothing. The earliest persisted deadline is indexed and checked against canonical clock state on reads.

Timeouts enter the same state/log/outbox/receipt transaction as gameplay. They roll when required, randomly discard the exact required count, move the robber to a different hex, choose an eligible victim, waive unused free roads and end the turn. They never purchase or construct a paid piece. A pre-roll Knight still leads to a dice roll. An automatic seven grants fresh discard windows; the expired turn continues through mandatory robber decisions once the last discard resolves. One already committed Road Building placement remains intact. System logs keep actor attribution, selection entropy, engine entropy and resulting clock state for replay; none of this exposes another player's hand.

Losing the final authenticated socket for a required seat freezes the remaining budgets. A second tab keeps that seat online. Reconnection clears only `DISCONNECTED`; manual and recovery pauses require host resume with required seats online. An already-expired deadline resolves before an absence pause. Host controls transfer after ten seconds to the lowest connected seat without changing turn ownership. Confirmed host abandonment preserves the saved position, declares no winner and releases the one-game slot.

Startup atomically takes the global runtime epoch and all ongoing room epochs, fencing the previous writer. Active saved games enter `RECOVERY`. Heartbeats checkpoint active games at most once every fifteen seconds without changing the game version. Recovery freezes time at the last trusted move/heartbeat checkpoint, bounded by the original remaining budget; a crash can refund roughly one checkpoint interval. Graceful shutdown freezes the exact remaining time. There is no unattended catch-up across multiple turns.

Checked-out PostgreSQL connection errors and pool errors both hold mutations. After storage becomes available, the backend confirms persisted state and adds `DATABASE_UNAVAILABLE`; host resume is required. A malformed state or mismatched deadline index fails readiness and leaves the saved game untouched for inspection. Recovery never regenerates a board. Flutter keeps controls locked after a storage interruption until a fresh authorized snapshot arrives, including when the reported version has not changed.

Flutter displays a countdown from server timestamps plus monotonic elapsed time. The device wall clock has no role in server authority or local countdown arithmetic. Expiry text waits for the server; the client sends no timeout command. Host pause/resume/abandon controls use normal versioned commands, and abandonment requires an explicit confirmation against the originally displayed snapshot.

## Verification

Toolchain: Node 22.20.0, Flutter 3.38.8/Dart 3.10.7, local Supabase/PostgreSQL/Auth, Chrome, Android build tools and Xcode. No dependency upgrade was required.

| Check | Result |
| --- | --- |
| `npm test` | 216 passing, including strict TypeScript builds and timer policy/fallback tests |
| `npm run test:local` | 56 passing; migrations/permissions, auth, lobby, durable gameplay and timer/recovery tests |
| Local fixture cleanup | All six application-table counts unchanged before/after the full suite |
| `flutter test --no-pub --reporter expanded` | 260 passing |
| `flutter analyze --no-pub` | No issues |
| Protocol interoperability | 48 generated owner-view delta fixtures, including timed turn/discard pause and resume, checked by TypeScript and Dart |
| Production builds | Web release, Android debug APK and iOS simulator app succeeded with local configuration |
| Four production Flutter Web clients | Passed: timed setup, same-ID reload after a dropped acknowledgement, countdown, preserved pause/resume budget, roll and confirmed abandonment |

Local fault tests use four separate anonymous identities and actual Socket.IO connections. They cover:

- Timed start, real two-round setup, untimed setup disconnects, one initial turn budget, early/no-receipt jobs and old generation rejection.
- Late action rejection, concurrent duplicate timeout calls, independent simultaneous discards, expired deadline versus disconnect, and exact persisted replay of pre-roll Knight timeout effects.
- Last-socket loss/rejoin during setup settlement, setup road, await-roll, action, discard, robber move, robber victim and Road Building; second-tab continuity; manual pause surviving reconnect; unauthorized session commands.
- Terminating only a test-owned active PostgreSQL connection, holding actions, and recovering the same private hands/board.
- Live runtime replacement, old-writer fencing, checkpoint-bounded clock recovery, exact graceful shutdown budget preservation, corrupt deadline-index rejection, ten-second host transfer and confirmed abandonment.

Rare rule positions and deadlines are seeded by the privileged local test harness using conserved engine fixtures. Normal setup uses real commands. No production route permits seeding, changing time or invoking a timer job. The full local suite checks cleanup of rooms, players, states, logs, outbox and receipts; synthetic Auth identities and runtime-epoch metadata are intentionally excluded.

Screenshots inspected: [host controls/countdown](screenshots/phase-6-host-controls.png), [portrait](screenshots/phase-6-live-portrait.png), [landscape](screenshots/phase-6-live-landscape.png).

## Running locally

After the existing `npm run local:start` / `npm run local:configure` setup, use separate terminals:

```sh
# Repository root
npm run dev:server

# apps/mobile
flutter run -d chrome --web-hostname=127.0.0.1 --web-port=8080 --dart-define-from-file=config/local.json
```

Create one private table, choose the time limit, invite 2–3 friends and ready all seats. The clock starts after both setup rounds. The host can pause, resume or abandon from the board. Reopening with the same guest credentials restores that seat; an API restart requires host resume. Native Android emulator configuration is `config/android.json`; iOS simulator configuration is `config/local.json`.

Serve the production Web release on `127.0.0.1:8080`, run the local API on port 3000, then use `npm run test:web:timers` for the timed browser flow or `npm run test:web:game` for untimed gameplay. The browser check removes only its own synthetic room. Do not run `test:local` concurrently with a preview game: it claims the single runtime epoch. Restart the preview API afterward.

## Limits and next review

No hosted service was deployed. Physical-phone play, Safari/WebKit, signed device builds, a complete human timed match across networks, mobile background suspension and sustained load remain Phase 7/device acceptance work. Native production builds are verified here; this phase does not claim a new native authenticated multiplayer interaction run. Earlier native practice evidence remains in Phase 5.

The existing migration already contains clocks, deadline indexes, runtime epochs, heartbeats and system receipts; no migration or protocol version change was needed. The historical timed-unavailable error remains valid for backward compatibility, but the current server does not emit it for supported time limits.

The Web build retains the previously documented optional Cupertino icon-font warning; Material icons and the build succeed. Countdown display can lag network delivery and is advisory. Offline detection depends on Socket.IO heartbeat detection, so abrupt network loss is not instant. This remains a single-process/one-game design; horizontal scaling is outside Phase 6.

Stop after Phase 6 and review before Phase 7.
