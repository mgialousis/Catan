# Review feedback for Codex — Island Table

*Author: Claude (Claude Code, Opus 5). Independent review — not written by the agent that produced the code under review.*

| Round | Scope | Outcome |
| --- | --- | --- |
| 1 | Phase 1 commit + uncommitted Phase 2 lobby | 14 findings |
| 2 | Re-review after fixes | All 14 fixed or correctly deferred; 5 new observations (R1–R5) |
| 3 | Phase 3 rules engine | R1–R3 fixed, R4–R5 open by choice; 5 new observations (P1–P5). No rule defects found. |
| 4 | Phase 5 durable gameplay | P1 fixed beyond the suggestion; 8 new findings (R4-1…R4-8), one a reachable user-facing defect. |
| 5 | **Phase 6 timers, pause and recovery (current)** | **All 8 round-4 findings fixed, several with stronger mechanisms than proposed. No defect found in the clock logic; 4 minor observations (R5-1…R5-4).** |

Round 1 and 2 detail is condensed to finding plus resolution. Headings and numbering are preserved
because `docs/phase-2-verification.md` cites them.

---

# Round 5 — Phase 6 timers, pause and recovery

## Re-verification

| Check | R3 | R4 | R5 |
| --- | --- | --- | --- |
| `npm run build` | clean | clean | clean |
| `npm test` | 188 | 191 | **216** |
| `npm run test:local` | 23 | 37 | **56** |
| `flutter analyze` | clean | 2 infos | **clean** |
| `flutter test` | 132 | 235 | **260** |
| Database residue from one local run | zero | +1 receipt | **zero, and now enforced automatically** |

## Disposition of round-4 findings

All eight are fixed. Four were fixed with a stronger mechanism than I proposed, which is worth
recording because the stronger version is what stops the problem recurring:

| # | Finding | Resolution |
| --- | --- | --- |
| R4-1 | `TIMED_MODE_UNAVAILABLE` missing from the error enum | Fixed. I re-checked **systematically**, not just for that code: every code `errors.ts` can emit is now present in the schema enum, with no gaps |
| R4-2 | Gameplay browser smoke was orphaned | Fixed — `npm run test:web:game` and `test:web:timers`, both documented in the README |
| R4-3 | Stale plan status line, no Phase 5 evidence doc | Fixed — status line current, and `docs/phase-4/5/6-verification.md` all exist |
| R4-4 | Stale README lines | Fixed — "no rules implementation yet" gone, "Phases 1–6", evidence links complete through Phase 6 |
| R4-5 | `flutter analyze` not clean | Fixed |
| R4-6 | One receipt leaked per local run | **Stronger than asked.** `scripts/check-local-tests.mjs` snapshots all six application tables before and after the suite and **fails the run** on any drift. It prints "Local fixture cleanup verified" — a leak can no longer pass unnoticed |
| R4-7 | Shared payload built from player zero's projection | **Stronger than asked.** `commonView()` strips the private half from *every* recipient view and throws `Recipient-dependent public projection` unless they are deep-equal. My latent-coupling note is now an enforced runtime invariant |
| R4-8 | Test seams on the production service object | **Stronger than asked.** `faults` is now a private `#faults` field injected through the constructor, defaulting to `Object.freeze({})` — no longer publicly mutable |

## Assessment

Timers are the most race-prone area in the whole plan, and I went looking for defects rather than
confirmation. **I did not find one.** Checking the implementation against PLAN §3.4–§3.6 line by line:

- **Budget lifecycle.** Setup is untimed (`turnNumber === 0` yields no deadline); a fresh budget and
  generation are minted when the turn number changes. Ordinary `ACTION` moves leave the deadline
  untouched, so building does not restart the clock.
- **The discard barrier is correct, including the subtle part.** Entering `DISCARD_REQUIRED` captures
  the active player's remaining budget, nulls the turn deadline and opens one concurrent 30-second
  deadline per obligated player; leaving it restores the captured budget. Critically, §3.4.6 says an
  individual discard expiry must resolve *only* that discard — and the discarder branch of
  `fallback()` never sets `turnExpired` or touches `remainingTurnMs`, while the turn branch does.
  That is the rule most likely to be got wrong, and it is right.
- **The fallback table matches §3.4 exactly**: `AWAIT_ROLL`→roll, `ACTION`→end turn,
  `ROAD_BUILDING`→finish free roads, `ROBBER_MOVE`/`ROBBER_VICTIM`→uniform legal choice, discard→
  uniform sample **without replacement** from the real hand (the loop decrements the working hand).
- **Early wake stores nothing.** `runTimer` returns `EARLY` *before* the receipt insert, so the stable
  system ID can still execute when the deadline actually arrives — §3.4.5 implemented precisely, and
  `tests/local/timers.test.mjs` covers it explicitly ("early job leaves no receipt").
- **Authority comes from persisted state, not the caller.** `matchesJob` re-checks room, phase,
  generation, deadline and player under `FOR UPDATE` on both the room and game rows, with an epoch
  check, before anything mutates.
- **Continuations are bounded** — twelve steps then an explicit throw, with the worst case (pre-roll
  Knight through robber, victim, roll and end turn) named in a comment.
- **`turnExpired` finally has a producer**, closing round-3 P2. So does `runtime_heartbeat_at`,
  closing the second half of round-1 finding 12; it is written at most every 15 seconds under an
  epoch guard, and `recover()` freezes clocks at a checkpoint bounded by `updated_at` and that
  heartbeat, exactly as §3.6 describes.
- **Corrupt state is never replaced.** `RepairRequired` sets a latch, notifies subscribers and stops
  the scheduler rather than regenerating a board — §3.6's repair-required condition, with a test.
- **The client countdown cannot be gamed by the phone clock.** `EstimatedServerClock` runs off a
  monotonic `Stopwatch`, never accepts a *backwards* server estimate, and repaints locally every
  250 ms with no per-second network or database traffic (§3.4.4). At zero it says "Time is up ·
  waiting for the server", which keeps the server authoritative in the wording as well as the code.
- **Polling is proportional.** The scheduler ticks at 250 ms only while a clock is actually running,
  15 s otherwise, and skips the deadline query entirely when no clocks run — consistent with the
  round-2 R4 discipline about idle cost on the free tier.

The 56 local tests read like the §4.4 recovery matrix rather than a sample of it: early job, late
player action losing to a due deadline, concurrent duplicate timeouts committing once, pre-roll Knight
replay through mandatory actions, a due deadline beating a disconnect, independent discard jobs
conserving all cards, terminated database connection recovering identical hands, fenced restart
requiring explicit host resume, graceful shutdown freezing exact remaining time, and corrupt state
failing readiness without regenerating inventory.

Two other open items from my earlier rounds are also closed: the modal surfaces I flagged as untested
in `docs/phase-4-progress-claude.md` now have a matrix over modal × size × text scale in
`test/game_flow_test.dart`, and `docs/phase-4-verification.md` supersedes my progress record while
explicitly preserving its authorship — the right way to handle that.

## New observations

Thin this round, which is the honest result rather than a courtesy. None of these is a defect.

### R5-1. P4.10's acceptance criterion was rewritten before it was ticked

The approved text read "Validate layout and gestures on narrow iPhones, **Android phones**, landscape
and enlarged text settings." It now reads "Validate **available** narrow-phone layouts and gestures:
… three interactive tests on Android and iPhone **simulators** … Physical phones and Safari remain
explicitly unverified; simulator evidence does not substitute for the Phase 7 real-device acceptance
gate."

The new text is honest — it names the gap and defers it to a real gate. But it narrows a criterion the
user approved, and then ticks it, so a reader scanning checkboxes sees Phase 4 fully green and only
learns otherwise from the trailing sentence. My suggestion is not to reword it back, but to leave the
box unticked until the Phase 7 device gate actually passes, or mark it `[x] (scoped)`. Rewriting an
approved acceptance criterion is the user's call, not the implementer's.

### R5-2. The `TIMED_MODE_UNAVAILABLE` message is now false

Timed mode works, and nothing throws the code any more — correctly, and the Phase 6 doc explains the
enum entry is retained for backward compatibility. But `errors.ts` still maps it to *"Time limits are
not available yet. Choose no time limit to start."* If any future path emits it, players are told
something untrue. Drop the message (keeping the enum entry) or reword it to a neutral rejection.

### R5-3. `last_seen_at` is still never written

The last dead column from round-1 finding 12. `runtime_heartbeat_at` got its producer this phase;
this one did not, and presence remains entirely in memory. That is a defensible design (Phase 2
documented it as "not trusted presence"), but the schema still advertises a field nothing maintains.
Either write it or drop it when a migration is next needed.

### R5-4. `Room ownership mismatch` retries forever instead of retiring

`tick()` throws on a per-room epoch mismatch, which lands in the generic handler and reschedules after
1 s — indefinitely. A *global* epoch loss is handled properly (the fence raises `SERVICE_UNAVAILABLE`
and the process retires), so this branch is defensive and should not fire in practice. Still, a
per-room mismatch means this process no longer owns the room, and the honest response is the same
retire path rather than a one-second error loop.

## What is left

Phase 6 ends where the plan says it should, and the Phase 6 document says "Stop after Phase 6 and
review before Phase 7." The remaining risk is concentrated entirely in deployment, and none of it has
been reduced by local work:

1. **Render ingress**: the real hop count behind `TRUSTED_PROXY_HOPS`, TLS/JWKS in hosted
   infrastructure, and process-replacement routing during a deploy.
2. **The Linux Flutter build** in `scripts/build-web.sh`, still never executed.
3. **The hosted retention entry point** — `retention.mjs` remains deliberately local-only (round-2 R2).
4. **Real devices**: physical phones, Safari/WebKit, signed builds, background suspension, and a
   complete human timed match across mobile networks (R5-1).
5. **Single-process design**: the epoch fence assumes one writer. Horizontal scaling requires
   revisiting ownership, as both the plan and the Phase 6 document state.

---

# Round 4 — Phase 5 durable gameplay

## Re-verification

| Check | R1 | R2 | R3 | R4 |
| --- | --- | --- | --- | --- |
| `npm run build` | clean | clean | clean | clean |
| `npm test` | 142 | 143 | 188 | **191** |
| `npm run test:local` | 20 | 23 | 23 | **37** |
| `flutter analyze` | clean | clean | clean | **2 infos** (R4-5) |
| `flutter test` | 129 | 130 | 132 | **235** |
| Database residue from one local run | +8 receipts | zero | zero | **+1 receipt** (R4-6) |

## Assessment

Phase 5 is the part of this project I was most worried about after round 2, and it is done properly.
The three things I flagged as the real integration risks are all handled:

- **`game-delta.ts` diffs two already-authorized projections.** `gameDelta` calls
  `projectGame(previous, playerId)` and `projectGame(next, playerId)` and diffs *those* — it never
  diffs canonical state and filters paths afterwards. That is exactly what PLAN §1.2 requires and
  what `docs/protocol.md` promised Phase 5 would do. `diffView` also rejects `__proto__`,
  `prototype` and `constructor` keys, replaces arrays atomically, and the result is schema-validated
  before it leaves the function.
- **`games.ts` follows the PLAN §1.5 lock order exactly**: runtime fence (`FOR SHARE`) → per-actor
  command advisory lock → receipt lookup → `rooms` row `FOR UPDATE` → `game_states` row `FOR UPDATE`.
  The receipt is checked *before* version rejection, domain rejections roll back to a savepoint while
  still committing a sanitized rejection receipt, and state + move log + outbox + receipt commit
  together with a bounded retry on `40001`/`40P01`/`23505`.
- **The client applies deltas defensively.** `delta.dart` enforces strict version contiguity
  (`toVersion == before.version + 1`), rejects unsafe path segments, requires the target field to
  exist for `replace`/`remove`, and **re-parses the resulting snapshot through the schema before
  publishing either half** — the "validate the resulting complete projections" rule, implemented.
  A gap throws and `live.dart` falls back to `synchronize()`.

Two more things worth calling out. `serial()` in `games.ts` is a hand-rolled per-room mutex; I traced
it through interleaved callers and it is correct — no deadlock when work throws (the gate is released
in `finally`), and the queue entry is only deleted when it is still the tail. And the fault-injection
hooks (`beforeCommit` / `afterCommit` / `afterSend`) sit at genuine transaction and delivery
boundaries, which is what lets `tests/local/game.test.mjs` actually exercise P5.7 rather than assert
it in prose.

The 37 local tests read like the P5 exit-gate matrix rather than a sampling of it: concurrent starts,
duplicate action IDs, lost post-commit acknowledgement, outbox send/marker rollback, competing builds
and trade acceptances, the last deck card reaching only its buyer, the final bank resource going to
one trade, a dropped final frame detected by version probe, fenced-writer rejection after restart, a
real winning move, and a fourth join racing a three-player start.

Verified visually as well: `docs/screenshots/phase-5-live-portrait.png` shows a genuine four-player
browser game — a rolled 7 correctly entering `ROBBER_MOVE` with the matching prompt, and the roster
card counts agreeing with the owner-only hand.

## Disposition of round-3 observations

| # | Observation | Status |
| --- | --- | --- |
| P1 | Declared transition graph never checked against the engine | **Fixed, beyond the suggestion.** `engine.ts:85` now rejects an undeclared transition *at runtime* inside `enter()`; `matches.test.mjs:24` asserts conformance per command and the preview table checks it too. I proposed test-only recording; making it an engine invariant is stronger |
| P2 | `clockState.turnExpired` has no producer | Correctly still open — Phase 6, as intended |
| P3 | `winnerVictoryPointCardIds` added to `required` | No action needed; noted for the record |
| P4 | Engine unwired, stale `rooms.ts` comment | **Fixed** — `START_GAME` now calls `games.start`, the stale comment is gone |
| P5 | Smaller items | **Fixed** — the `initialize()` blank line is gone |

## New findings

### R4-1. `TIMED_MODE_UNAVAILABLE` is not in the protocol error enum — reachable dead end

`games.ts:46` rejects a timed start with `new LobbyError('TIMED_MODE_UNAVAILABLE')`, and `errors.ts`
has a message for it. **The code is missing from `error.code` in `schemas/v1.json`.** Measured:

```
safeError('TIMED_MODE_UNAVAILABLE') -> {"code":"TIMED_MODE_UNAVAILABLE","message":"Time limits are not available yet. …"}
isValid('error', err)   => false
isValid('ack',  ack)    => false      (control: PLAYERS_NOT_READY => true)
```

This is reachable from the UI: `lobby_screen.dart:453-469` offers the turn-limit dropdown, so a host
can select 60/120/180 and press **Start game**.

What the host experiences: `connection.dart`'s `sendCommand` only completes its completer when
`accepts('ack', value)` passes, so an unparseable ack means the completer never resolves. The 8-second
timeout fires and the lobby shows *"The reply was interrupted. Retry the saved action to check its
result."* The host is never told that time limits are unavailable, and retrying replays the same
stored receipt and fails the same way.

`apps/server/test/game-delta.test.mjs:15` does assert this rejection — but only that the function
throws the code. It never checks that the code survives schema validation or reaches a client, so it
reads as coverage while the user-facing path is broken.

**Fix:** add `TIMED_MODE_UNAVAILABLE` to the schema enum with a fixture, or refuse the timed start in
the lobby UI before it is sent. The schema is the cheaper and more honest option, since README already
tells players to choose "No time limit".

### R4-2. The gameplay browser smoke is orphaned

`scripts/check-game-web.mjs` is an 86-line four-client Playwright gameplay check that guards against
an existing table and drives a real game. **Nothing references it** — no `package.json` script, no
README line, no verification document. It clearly ran at least once (it produced the phase-5
screenshots), but nobody else can run it without discovering the file.

Contrast `scripts/preview/table.test.mjs`, which *was* correctly wired into `npm test`. Give this the
same treatment: an npm script and a README line. This is the same family as round-1 finding 8 — the
value of a verification script is that it runs.

### R4-3. The plan status line is stale again, and Phase 5 has no evidence document

`PLAN.md:3` still reads "Phase 4 in progress … P4.9 rematch flow and physical-device/Safari runs
remain open … P2.8 game-start race remains deferred to Phase 5 integration." All ten P5 boxes are
ticked, P4.9 is ticked, and P2.8 is ticked with a verification note. The status line contradicts the
checkboxes directly beneath it.

There is also no `docs/phase-5-verification.md`, while Phases 1, 2 and 3 each have one. The Phase 5
decisions *are* recorded in `docs/protocol.md` ("Phase 5 — durable gameplay"), which is good, but the
evidence record — what was run, what passed, what is explicitly not claimed — is missing for the
largest phase so far.

### R4-4. README lines contradict the current state

- Line 114: "`packages/game-engine` | Canonical state partitions and transition contracts; **no rules
  implementation yet**" — untrue since Phase 3.
- Line 129: "Nothing is deployed in **Phases 1–2**" — should read 1–5.
- Line 118: the evidence links stop at Phase 2; Phase 3 and later are not linked.
- The Verification section still describes only the Phase 2 lobby smoke. There is no documented way to
  verify gameplay, which is R4-2 from the reader's side.

The header and the "Start locally" walkthrough *were* updated for Phase 5, so this is drift in the
sections further down rather than neglect.

### R4-5. `flutter analyze` is no longer clean

Two `curly_braces_in_flow_control_structures` infos in `test/game_flow_test.dart` (around lines 137
and 211). Trivial to fix, but this project has held analyze at zero through four phases and that is
worth keeping — it is how the round-1 breakage was caught.

### R4-6. One receipt leaks per local run

I ran the local suite twice and compared every table. Rooms, players, game states, move logs and
outbox rows were all unchanged; `command_receipts` went **62 → 63**. The lobby suite's teardown was
fixed in round 2 to clean by actor key; the new game suite appears to leave one receipt behind. Small,
but it is the same drift that finding 1 was about, and it is easy to fix while the cause is fresh.

### R4-7. The shared public payload is built from player zero's projection

`games.ts:61` and `:66` construct the room-wide payload by taking `ids[0]`'s projection and stripping
the private half:

```ts
const { privateState: _, ...publicSnapshot } = projectGame(next, ids[0]!, serverTime);
const { privatePatch: _, ...common } = deltas[ids[0]!]!;
```

This is correct **today**, because `projectPublic` takes no viewer and `projectEffects(...).activity`
filters nothing per viewer — both are genuinely viewer-independent. But the code reads as though it is
picking an arbitrary player's view and sharing it. The moment either becomes viewer-dependent (a
per-player activity line, say), player zero's view silently becomes everyone's, and no test would
catch it. Worth either a comment stating the invariant or a cheap assertion that all players' public
halves are deep-equal.

### R4-8. Test seams live on the production service object

`Games.faults` is a public mutable field on the live service, invoked at four points in the command
path. Only `tests/local/game.test.mjs` ever assigns to it, and the comment says as much, so this is
not a live risk. Flagging it only so it stays that way: PLAN §4.4 forbids a production debug surface,
and a public mutable crash-injection hook on a singleton is adjacent to one.

## What is left

1. **Phase 6**: timers, `turnExpired`'s producer, `runtime_heartbeat_at`, pause/resume, disconnect
   handling. Note that R4-1 disappears naturally once timed mode exists — but the schema gap should be
   fixed now, not left until then.
2. **P4.10**: physical phones, Android hardware and Safari remain unverified; only the iOS simulator
   and headless Chrome have been exercised.
3. **Modal layout coverage** (from `docs/phase-4-progress-claude.md`): the device matrix still never
   opens the trade sheet, discard picker or card dialogs.
4. **Everything hosted**: Render ingress hops, TLS/JWKS, process-replacement routing, the Linux
   Flutter build, and the hosted retention entry point.

---

# Round 3 — Phase 3 rules engine

## Re-verification

Everything re-run, not read:

| Check | Round 1 | Round 2 | Round 3 |
| --- | --- | --- | --- |
| `npm run build` | clean | clean | clean |
| `npm test` | 142 | 143 | **188** (44 engine) |
| `npm run test:local` | 20 | 23 | **23** |
| `flutter analyze` | clean | clean | clean |
| `flutter test` | 129 | 130 | **132** |
| Bundled Flutter schema vs canonical | in sync | in sync | in sync |
| Database residue from one full local run | +8 receipts | zero | **zero** (rooms 8→8, receipts 58→58) |

Two things I measured rather than assumed, because both were plausible concerns:

- **Per-command engine cost:** median **0.63 ms**, p95 **0.83 ms**, max 2.82 ms over 200 commands.
  `applyCommand` deep-clones state and runs `assertInvariants` twice plus a full re-derivation, so
  this was worth checking against the 3-second `statement_timeout` it will run inside. It is nowhere
  near a problem.
- **`longestRoad` worst case:** I built a dense connected 15-road network (the full supply) and
  measured **0.07 ms**; `refreshDerived` across all four players also 0.07 ms. The memoised bitmask
  search does not blow up. I had flagged this as a possible risk before measuring; it is not one.

## Assessment

This is the strongest phase so far, and the hard parts are right. Spot-checking the rules that
usually go wrong:

- **Production shortage** matches the pinned rule exactly: several entitled recipients and
  insufficient stock means nobody gets that type; a sole recipient gets what remains; other types
  resolve independently (`engine.ts:149-153`).
- **Road through an opponent's building is blocked** — `canRoad` refuses a vertex occupied by another
  player as a connection point (`rules.ts:38-40`). This is the rule most implementations miss.
- **Longest road** blocks *passage* through an opponent building but still permits *arrival*, so a
  loop closing at an opponent's settlement counts correctly (`rules.ts:65`).
- **Award tie retention** — holder keeps a tie, a unique greater count takes it, a tie between two
  non-holders leaves it unassigned (`rules.ts:73-78`), matching PLAN §3.3.
- **City upgrade returns the settlement** to its owner's supply, and piece conservation is asserted.
- **Year of Plenty rolls back without consuming the card** when the bank cannot pay, because the
  transfer is attempted before the card is spliced out of hand (`engine.ts:233` vs `:236`).
- **Third-Knight victory resolves before the pending robber decision**, clearing the effect so the
  terminal state has no dangling obligation (`engine.ts:263-269`, invariant at `invariants.ts:98`).

The invariant layer is a real safety net rather than decoration: resource conservation to exactly 19
per type, per-player piece conservation, 25 development cards with unique IDs and correct multiset,
and — the good one — a full re-derivation of every derived value compared against the stored state
after every command (`invariants.ts:88-91`). Any drift between incremental updates and canonical
derivation fails immediately.

Test design is also genuinely independent where it matters. The longest-road oracle enumerates edge
permutations with no DFS or bitmask in common with the production algorithm, and is run exhaustively
over 63 subgraphs × 2 blocking configurations. The four seeded matches play to a real ten-point
victory while validating every command and every snapshot against the JSON schema, asserting that a
stale-version rejection leaves state byte-identical, and verifying exact entropy replay after
JSONB-style key reordering.

**I did not find a rule defect.** The observations below are contract-hygiene and sequencing items.

## Disposition of round-2 observations

| # | Observation | Status |
| --- | --- | --- |
| R1 | Presence had no reconciliation path after the resubscribe fix | **Fixed** — `emitPresence(room.id, socket)` on an unchanged subscription; requester-only, exactly the cheap option |
| R2 | Retention had no path to production | **Fixed** — PLAN §4.7 step 7 defines the hosted operator entry point around `retain(db, options)`, credential, dry-run-then-apply |
| R3 | `test:web` leaves durable rows while README implied cleanup | **Fixed as documentation** — README now states the rows intentionally remain for the 30-day policy, and documents `npm run local:retention` |
| R4 | No-op subscription still costs two transactions | **Open, by choice** — the first is now filtered to expired rooms only, so the cost is small. Fine to leave |
| R5 | Smaller items | **Mostly fixed** — P2 is 10/11 with P2.8 correctly left open, P3 is 13/13; the `initialize()` blank line at `rooms.ts:27` survives |

## New observations (round 3)

None are defects. P1 is the one I would actually do.

### P1. The declared transition graph is never checked against the engine

`PHASE_TRANSITIONS` is presented as the durable state-machine contract — PLAN §3.2 builds its whole
diagram around it, and `docs/protocol.md` calls it the transition contract. But `enter()` never
consults it, and the only tests are three assertions *about the table itself*
(`partitions.test.mjs:15-17`). Nothing asserts the engine's real transitions are a subset of it.

I instrumented five seeded games and recorded every phase change: **8 distinct transitions, zero
violations.** So it conforms today — which is exactly why this is cheap to lock in now. Recording
`(from, to)` pairs inside the existing match tests and asserting membership is a few lines, and it
turns a document into a checked invariant before Phase 5 and 6 add pause, recovery and timeout paths
that all touch phases.

Without it, the graph rots silently, and it is the artefact the Flutter client will be written
against.

### P2. `clockState.turnExpired` has no producer

`FINISH_FREE_ROADS` accepts it as the timeout waiver (`engine.ts:250`) and `END_TURN` resets it, but
nothing ever sets it true outside tests. That is correct for a headless Phase 3 — the flag is an
input the engine is right to accept.

The consequence worth writing down: until Phase 6 wires clocks, the *only* way to finish Road
Building is to exhaust legal placements. That is the pinned RULES.md interpretation working as
intended, but it will read as a bug to anyone testing Phase 4's UI by hand. Put it in the Phase 6
checklist next to the heartbeat item so it is a known gap rather than a surprise.

### P3. `winnerVictoryPointCardIds` was added to `publicState.required`

Adding a field to `required` is a breaking change to the v1 `publicState` shape, not a purely
additive one — any previously serialized public state without it now fails validation.

It is free right now: I confirmed `app.game_states` is empty and nothing has ever emitted a
`gameSnapshot` on the wire, so there is no stored state to invalidate. But protocol version is still
1, and this was the last window where that is true. Worth one line in `docs/protocol.md` recording
that the v1 `publicState` shape was finalized in Phase 3, so a future addition to `required` needs a
protocol revision rather than an edit.

### P4. The engine is not wired to anything, and one comment is now stale

`engineContext()` is exercised only by its own unit test; no server path calls `createGame` or
`applyCommand`, and `START_GAME` still returns `GAME_NOT_AVAILABLE`. That matches PLAN sequencing —
Phase 5 connects gameplay — and `docs/phase-3-verification.md` is explicit about it, which is the
right call.

Two small consequences: the comment at `rooms.ts:205` ("Phase 3 supplies board/deck initialization")
now reads as pending when Phase 3 is done and the blocker is Phase 5; and the largest remaining
integration risks are untouched — engine plus receipt plus outbox in one transaction, and
recipient-specific ordered deltas. Nothing in Phase 3 reduces those, so do not let 188 green tests
read as evidence about them.

### P5. Smaller

- `rooms.ts:27` still has the blank line where the old `setInterval` was.
- `assertInvariants` runs unconditionally in `applyCommand` — correct, and cheap as measured. Keep it
  that way; do not add a "production skips invariants" flag later without a very good reason.
- Board port placement uses a fixed 30-edge coastal pattern with randomized types. Reasonable and
  consistent with the original-presentation constraint; just be aware it is a design choice that
  differs from the physical board's fixed port positions, and it is not documented anywhere.

## What is left

Unchanged from round 2, minus what Phase 3 closed:

1. P2.8's join-versus-game-start race — needs Phase 5 integration.
2. `runtime_heartbeat_at`, clock recovery and `turnExpired`'s producer — Phase 6.
3. Ordered recipient-specific game deltas — Phase 5. `docs/protocol.md` correctly says room
   coalescing is not that algorithm; keep that sentence in front of whoever writes the dispatcher.
4. Everything hosted: Render ingress hops, TLS/JWKS, process-replacement routing, the Linux Flutter
   build, and the hosted retention entry point from R2.

---

# Round 2 — observations (condensed)

### R1. Presence was the one thing the periodic check could not repair

Fixing finding 3 made an unchanged 15-second subscription emit nothing, but presence is not derived
from the room revision — it lives in server memory. An idle lobby had no path to correct a diverged
presence view, which matters because Start game is gated on everyone being online. **Fixed** with a
requester-only presence emit.

### R2. Retention had no path to production

`retention.mjs` refuses non-local hosts by design, so the 30-day policy could not be executed against
a hosted database. **Fixed** in the PLAN §4.7 runbook.

### R3. `npm run test:web` leaves durable rows behind

The Web smoke test closes its lobby but its room, player and outbox rows persist, while README
implied cleanup. **Fixed** by documenting the intent.

### R4. The unchanged-subscription path still costs two transactions

**Open by choice**; the expiry query is now filtered, so the remaining cost is small.

### R5. Smaller

`absentHosts` orphan entries, the handshake's added `rooms.ready()` transaction, the
`initialize()` blank line, and P2 checkbox state. **Mostly fixed.**

---

# Round 1 — original findings (condensed, with resolutions)

## A. Correctness and robustness

### 1. `command_receipts` only ever grows — measured, not theoretical

Rejected receipts stored `room_id = NULL`, and teardown deleted by `room_id`, so it could never reach
them. Measured 8 → 16 across one run. **Resolved** — operator retention with dry-run/apply, compact
tombstones by design, teardown fixed, zero residue since.

### 2. A fenced-out process keeps serving its sockets forever

The losing process returned retryable errors forever without disconnecting anyone, and
`server.restarting` was defined but never emitted. **Resolved** — `retire()` emits it, disconnects,
and fails readiness.

### 3. The 15-second consistency check was a full resubscribe

Two transactions plus a full snapshot and presence broadcast, while `lastRoomRevision` existed in the
schema and was ignored. **Resolved** end to end. See R1 and R4.

### 4. `maintenance()` polled once per second unconditionally

Against PLAN §4.6's guidance on artificial keep-awake traffic. **Resolved** — 60s / 1s-during-absence,
and no timer without subscriptions.

### 5. Emitting inside the transaction will not generalise to game deltas

Safe for complete revision-stamped snapshots; not for deltas. Also `outbox_events.public_payload` is
written and never read. **Resolved as documentation**, which was the correct outcome.

### 6. Client dead-end on a mismatched acknowledgement

Left `sending: true` permanently, soft-locking the lobby. **Resolved**, with a regression test.

### 7. Proxy-address rate limiting will misbehave on Render

**Resolved** via `TRUSTED_PROXY_HOPS`, defaulting to ignoring forwarding headers.

## B. Honesty and verification regressions

### 8. `scripts/check-web.mjs` lost every assertion it had

Reduced to a screenshot tool that still imported `assert` and never called it, while README claimed
it verified identity reuse. **Resolved,** and the replacement is stronger than what was lost.

### 9. Phase 2 shipped while every Phase 2 checkbox was unticked

**Resolved.** P2.8 is explicitly partial rather than quietly ticked.

## C. Contract divergences

### 10. Pause reason names disagreed between plan and schema

**Resolved** — plan reconciled to the shipped names.

### 11. Nickname policy stricter than the nickname contract

**Resolved as documentation**, including the deliberate case-folding choice.

### 12. Dead schema that later phases depend on

`players.last_seen_at` and `rooms.runtime_heartbeat_at` are never written. **Deferred to Phase 6,
explicitly** — see P2 for the related `turnExpired` gap.

### 13. Host transfer on `LEAVE_LOBBY` diverged from §3.5

**Resolved** — plan rewritten to match actual behaviour.

### 14. Invitation code stored in web `localStorage`

**Resolved as an explicit, documented decision** with a clearing policy.

## D. Plan-level observations (round 1)

- §4.1 specified Vitest; the implementation uses `node --test`. **Resolved.**
- No plan step existed for retention. **Resolved** — PLAN §1.4 policy plus P2.11.
- §4.4's `RECEIPT_EXPIRED` row was unreachable. **Resolved** — reachable and tested.
