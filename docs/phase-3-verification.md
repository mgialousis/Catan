# Phase 3 verification — complete base-game engine

Phase 3 was authorized after the Phase 2 review and completed with one agent. Evidence below was collected locally on 2026-09-09/10 using the existing pinned toolchain. No hosted infrastructure, account, paid service, dependency upgrade, commit or push was introduced.

## Delivered scope

P3.1–P3.13 are implemented in `packages/game-engine`. The package generates the board, keeps public/private/server/clock state separate, enforces setup and the complete base-game action flow, computes awards and victory, and produces recipient-filtered effects. It takes explicit time and entropy and has no database or transport dependency. `apps/server/src/engine-context.ts` provides the backend crypto adapter.

| Checklist | Implementation / evidence |
| --- | --- |
| P3.1–2 | Canonical 19/54/72 graph, nine ports, standard inventories, 200 seeded layouts; forced bounded fallback covers all 19 desert positions |
| P3.3 | Rotated persistent turn order; three/four-player snake placement; every road touches its pending settlement; second-placement resources granted once |
| P3.4 | All 36 dice pairs, settlement/city demand, robber suppression, sole-recipient and competing-recipient shortages |
| P3.5 | 7/8/9/10-card discard thresholds, barrier and ownership; empty/multiple/deduplicated victims; desert movement; weighted individual-card stealing and participant-only disclosure |
| P3.6 | Paid road/settlement/city commands, distance/connectivity/blockage, finite piece and bank supplies, settlement return on upgrade, 4:1/3:1/2:1 exchanges |
| P3.7 | Nonbinding offers, active-player involvement, replacement/cancellation/decline revisions, atomic acceptance, stock-loss expiry and end-turn invalidation |
| P3.8–9 | Correct 25-card inventory; private purchases, empty deck, purchase-turn and one-play restrictions; all effects before/after rolling; Road Building with 0/1/2 pieces and 0/1 legal locations, timeout waiver |
| P3.10 | Independent road-length oracle, loops/branches/interruption and full 15-road supply; army threshold/tie/transfer; newly bought winning VP, immediate third-Knight victory and own-turn start victory |
| P3.11 | Explicit server time, bounded crypto adapter, seeded fixtures, recorded entropy and checked exact replay |
| P3.12 | Recursive public/owner projections, private effect filtering, resource/card/piece and phase invariants before/after every move; real snapshot validation |
| P3.13 | Hand-authored conservation-preserving scenarios and four complete valid-command matches with stale-command mutations and exact replay after JSONB-style key reordering |

## Executed checks

| Command / check | Result |
| --- | --- |
| `npm test` | **188 passed**, including **44 engine tests**, protocol fixtures and server tests; strict TypeScript build passed |
| `npm run test:local` | **23 passed** against local Supabase: RLS/role separation, transactional constraints/receipts, JWT and gateway authorization, lobby races/recovery/retention; requester-only presence repair verified |
| `npm run protocol:sync` | Canonical schemas/events copied to Flutter assets |
| `cd apps/mobile && flutter test --reporter compact` | **132 passed**, including the real initial and completed engine snapshots and bundled-schema equality |
| `git diff --check` | Passed |

The first sandboxed Flutter attempt could not write the installed SDK cache, and the first local integration attempt could not connect to localhost (`EPERM`). Both were rerun through the approved escalation mechanism and passed. These were environment restrictions, not suppressed test failures.

No database schema changed in Phase 3, so no new SQL migration is needed. The local suite validates the existing migrated database. Web/Android/iOS builds and device lobby runs were completed in Phase 2; they were not repeated for this engine-only phase. Dart contract compatibility was rerun. Live game transport, background timers and hosted deployment are not claimed by these checks.

### Complete-match exit gate

Run from the repository root after `npm run build`:

```sh
node --test packages/game-engine/test/matches.test.mjs
```

| Players | Seed | Accepted commands | Turns | Winner score |
| --- | --- | --- | --- | --- |
| 3 | 11 | 322 | 97 | 10 |
| 3 | 83 | 361 | 91 | 10 |
| 4 | 42 | 355 | 89 | 10 |
| 4 | 129 | 547 | 161 | 10 |

All **1,585** commands pass the wire command schema, use owned resources and legal actions, and leave conserved state. The test actors cooperate through ordinary 1:1 trades and wait on other turns; this is a rule traversal, not competitive AI. No canonical state is injected after initialization in these matches. Hand-authored unit scenarios are separate and explicitly prepare finite-inventory states.

Each match recreates its initial state and applies every recorded command using recorded entropy only. The final state, effects and random request records compare exactly. Reordering all object keys before each replay move models JSONB key ordering without changing arrays. Snapshot checks cover every player periodically and at completion. Separate rule tests cover commands the cooperative matches do not choose, including paid road expansion, settlements and non-Knight development effects.

## Design decisions and boundaries

- The initializer retains `serverState.turnOrder` after setup and records owners on played cards. JSON state contracts remain v1 because no live game state has been deployed or persisted yet.
- Public state now requires `winnerVictoryPointCardIds`, empty during play and populated only for the winner on completion. Shared TypeScript and Dart fixtures cover both states.
- `createGame` returns version 0. `applyCommand` returns an immutable successor plus effects/draws; the caller must persist accepted commands and use the authenticated actor. Rule rejection never mutates its input. Database idempotency and concurrent acceptance remain Phase 5 responsibilities.
- No engine result is emitted directly to sockets. `projectGame` and `projectEffects` allowlist the appropriate view. Internal entropy, deck order and opponent hands never belong in a public log/delta.
- Rule revision, Year of Plenty atomic-choice policy, normalized disjoint trade bundles and Road Building early-finish/timeout policy are documented in [RULES.md](../packages/game-engine/RULES.md).
- The SDK-independent engine can run/test without Docker. To use the current lobby app, follow [README](../README.md). `Start game` continues to guard eligibility and return the documented `GAME_NOT_AVAILABLE` result until Phase 5 wires the initializer and transaction. `/api/v1/version` reports implementation phase 3; that is a build milestone, not an assertion that live gameplay is available.

## Claude review follow-up

The supplied [independent review](review-2026-09-09-claude.md) was read, including its second round. Its text is preserved.

| Finding | Disposition |
| --- | --- |
| R1: unchanged subscriptions cannot repair presence | Fixed: refresh only the requester, retaining snapshot suppression. Integration test opens another socket and asserts one requester event, zero observer events and zero redundant snapshots |
| R2: local-only retention has no hosted operator path | Added explicit Phase 7 prerequisite to PLAN §4.7: reviewed hosted wrapper around `retain`, privileged maintenance credential outside repo, TLS, local operator machine, dry-run then apply and count checks. Hosted execution remains unimplemented/unverified |
| R3: Web smoke test retains durable rows | README now explicitly states that abandoned room/player/outbox history remains for the retention policy; no cleanup claim |
| R4: two transactions per unchanged subscription | Deferred optimization. Retain database authorization/fencing for the four-player local target; a cache would require invalidation/recovery design |
| R5: absent-host cache and reconnect hot path | Track in Phase 6 recovery work: prune absent-host entries whose rooms disappear and measure reconnect fencing transactions. The current single-slot/manual-retention scope does not require a speculative coordinator cache |
| Earlier cross-phase findings | P2.8 join-versus-actual-start race and ordered recipient game deltas remain Phase 5; durable heartbeat/clock recovery remains Phase 6 |

## Review gate

No Phase 3 blocker remains. The current app is still a lobby; Phase 4 adds the board/hand/action interface, Phase 5 connects it to authoritative persisted commands, and Phase 6 completes timer/disconnect recovery. P2.8 remains unchecked until its actual integration race is tested. Stop here for review before Phase 4.
