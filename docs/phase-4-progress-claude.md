# Phase 4 work record — 2026-09-10

*Author: Claude (Claude Code, Opus 5). Written for Codex to review. This is a work record, not a
completion claim: Phase 4 is **not** finished. See "Open items".*

Related: [independent review of Phases 1–3](review-2026-09-09-claude.md).

---

## 1. State I found

`apps/mobile/lib/game/` contained three uncommitted files — `model.dart`, `controller.dart`,
`board.dart` — and **the working tree did not compile**:

| Severity | Location | Problem |
| --- | --- | --- |
| error ×3 | `board.dart:148,149,150` | `SemanticsProperties` used but never imported |
| info ×2 | `board.dart:77`, `board.dart:94` | `curly_braces_in_flow_control_structures` |
| info ×2 | `controller.dart:116` | same, on an `if/else` one-liner |

`flutter analyze` reported `7 issues found`. The `game/` directory was also **orphaned** — nothing in
`main.dart` or the lobby referenced it. `PLAN.md` still said "Awaiting review before Phase 4" with all
ten P4 boxes unticked.

The three existing files were good work and I changed their design as little as possible:
`model.dart` mirrors the engine's legality rules as advisory client-side previews (with the correct
"server remains the final authority" framing), and `controller.dart` already had the `GamePort`
abstraction, single-pending-intent discipline, version-monotonic snapshot handling and ack/version
reconciliation.

## 2. Changes

### 2.1 Restored the build

- `board.dart`: added `import 'package:flutter/semantics.dart';`.
- `board.dart:77`: braced the nested wave-pattern loops.
- `board.dart:94`: braced the probability-pip loop.
- `controller.dart:116`: braced the `if/else`.

### 2.2 New — `apps/mobile/lib/game/game_screen.dart` (728 lines)

The missing piece between the existing parts and a usable interface. Covers:

| Checklist | Implementation |
| --- | --- |
| P4.3 | `_players` public summaries (points, resource count, dev-card count, knights) and `_hand` owner-only resources, development cards and total score including hidden points |
| P4.4 | `_prompts` map plus `_actions`, giving every phase — setup, roll, discard, robber, victim, free roads, action — its own guidance and controls |
| P4.5 | `_confirmation`: highlighted legal targets on the board, cost line from `costs`, explicit Confirm/Cancel |
| P4.6 | `_TradeSheet`: give/receive composition, target selection (or Everyone), accept/decline/cancel of open offers, and bank exchange at the rate from `bankRate` |
| P4.7 | `_openCards` / `_playCard`, including the Monopoly resource dialog and the Year of Plenty two-card picker; private draw feedback via a snackbar |
| P4.8 | `_activity` history, `_pending` with retry, `Tooltip` reasons on every disabled action, and `Semantics` labels giving colour-independent player identification |
| P4.9 (partial) | Paused, reconnecting and result panels. The rematch flow is **not** built — see Open items |

### 2.3 New — `apps/mobile/test/game_test.dart` (339 lines, 23 tests)

Driven by the two **real engine-generated** `gameSnapshot` fixtures in
`packages/protocol/fixtures/contracts.json`, through a fake `GamePort`.

- Renders board, roster and owner-only hand from a real snapshot.
- **Privacy**: every public player summary exposes counts only and never names a resource type.
- **Duplicate taps stay a single pending intent** until the table replies (exit-gate requirement).
- Finished game reveals winner, final points and revealed-card count; no gameplay action offered.
- Stale snapshot never rolls the view backwards.
- **Device matrix (15 cases)**: 320 / 360 / 375 / 430 portrait plus 812×375 landscape, each at
  1.0× / 1.3× / 2.0× text, scrolled end to end asserting no overflow at any scroll step.
- Board target selection **driven through the semantics tree** — the full select → target → confirm →
  command path, which is also the screen-reader path.
- `IslandBoard` inside a height-constrained parent.

Two of these were **mutation-tested**, because an assertion that cannot fail is worthless:

- Leaking `"including brick"` into a player summary label makes the privacy test fail.
- Injecting a 900px spacer into the player row makes the overflow test fail
  (`A RenderFlex overflowed by 883 pixels`).

### 2.4 New — `apps/mobile/lib/preview.dart` (dev-only harness)

Generated. `main.dart` never references it; it is reachable only via
`flutter run -t lib/preview.dart`. It embeds two recorded snapshots and serves them through a
`PreviewPort implements GamePort` that acknowledges commands without advancing state, so the
interface can be exercised on a real device before Phase 5 provides a transport. A floating button
switches between the setup snapshot and an ACTION-phase variant.

`apps/mobile/test/preview_test.dart` (3 tests) guards it: the embedded setup snapshot must still
equal the canonical fixture, the derived ACTION variant must still validate against `gameSnapshot`,
and `main.dart` must not reference the harness.

**Codex: this file is a judgement call.** It duplicates fixture data (guarded, but still duplication)
and is an artifact the plan does not mention. If you would rather it did not exist, deleting it plus
`test/preview_test.dart` costs nothing else — everything else stands on its own.

## 3. Defects found and fixed

All four are real. None were introduced by me except where noted.

### 3.1 Player summary row overflowed by 11px

`_players` laid an avatar, name and four stat pills in one `Row`. At 320px with 2.0× text they do not
fit. **Fix**: `LayoutBuilder` + `Wrap` so the stats reflow below the name only when needed.
Found by the device matrix.

### 3.2 Final-scores row overflowed by 6.3px

`_result`'s per-player `Row(Expanded(name), Text('N points'))`, same conditions. **Fix**: `Wrap` with
`spaceBetween`, so the score drops below the name at extreme scales instead of overflowing.
Found by the device matrix, then localised by capturing `FlutterErrorDetails` while scrolling with
single `pump()` calls — `pumpAndSettle` deactivates the widget and loses the attribution.

### 3.3 `IslandBoard` overflowed 39px vertically in a height-constrained parent

Latent, and not reachable from the current screen (the board lives in a `ListView`, which leaves
height unbounded). It would bite the moment Phase 5 or a landscape redesign puts the board in an
`Expanded` or a fixed-height box.

**Fix**: `Flexible` **only when `LayoutBuilder` reports a finite height**. My first attempt applied
`Flexible` unconditionally and **broke 21 tests** — `Flexible` is illegal in a `Column` with unbounded
main-axis constraints. Worth knowing if you touch this again.

Found by rendering the board to a PNG via `RenderRepaintBoundary.toImage` and looking at it: the
yellow/black overflow stripe was visible in the image.

### 3.4 Stat pills stacked vertically — only visible on a real device

`_pill` returns a `Row`, which defaults to `MainAxisSize.max`. Inside the old parent `Row` it was laid
out with unbounded main-axis constraints, so it took its intrinsic width. Inside the `Wrap` from fix
3.1 it received the full line width and **expanded**, so each pill occupied its own line — four
wasted lines per player. **Fix**: `mainAxisSize: MainAxisSize.min`.

**This is the finding worth your attention.** All 155 widget tests passed while the layout was
visibly wrong, because nothing overflowed — it just looked bad. Only running the app on the iOS
simulator caught it. Automated layout assertions detect *overflow*, not *wrongness*.

### 3.5 Trade-sheet offer actions (pre-emptive)

`_offer` put Accept and Decline in a bare `Row`. The device matrix never opens the trade sheet, so
this surface is unverified; at 2.0× text on a narrow phone it would very likely overflow. Changed to
a `Wrap` rather than leaving a known-probable defect in place. **Still untested** — see Open items.

## 4. Verification

Everything below was run at the end of the session, in this order:

| Check | Result |
| --- | --- |
| `npm run build` | OK |
| `npm test` | **188 passed** |
| `npm run test:local` (real Supabase + Socket.IO) | **23 passed** |
| `analyze_files` (Dart MCP) | No errors |
| `run_tests` (Dart MCP) | **158 passed** (132 at session start) |
| iOS simulator run of `lib/preview.dart` | No runtime errors; setup and ACTION surfaces inspected by screenshot |

Reproduce with:

```sh
npm run build && npm test
npm run test:local
cd apps/mobile && flutter analyze && flutter test
flutter run -t lib/preview.dart -d <simulator-id>     # optional dev harness
```

### Verified visually on the iOS simulator

Board geometry and presentation were confirmed against a real render, not only by absence of
exceptions: 19 hexes in the correct layout, terrain icons, number tokens with probability pips and 6/8
in red, nine coastal ports with ratio and resource labels, roads and buildings in seat colours with
seat numbers, robber on the desert. The ACTION surface showed correct **disabled** states —
"Build city" greyed because that player's settlements were all upgraded, "Build settlement" because
no legal vertex remained. That is engine-faithful behaviour reaching the UI.

## 5. Decisions and rationale

- **The game screen is deliberately not wired into the app.** `START_GAME` still returns
  `GAME_NOT_AVAILABLE`, and `game.sync` / `game.version.request` still return `FORBIDDEN`, so a live
  `GamePort` and the lobby→game route cannot be exercised. That is Phase 5 by the plan's own
  sequencing, and is exactly why `GamePort` is an interface. Recorded in `PLAN.md` rather than left
  as a silent orphan.
- **`flutter_driver` was not added.** The MCP driver tools need
  `enableFlutterDriverExtension()`, and adding the package would modify `pubspec.lock`, which
  `CLAUDE.md` forbids as incidental work. I used `xcrun simctl io … screenshot` plus MCP
  `hot_reload` / `hot_restart` instead. **If you want driver-based interaction, that dependency
  decision is yours to make** — the project-idiomatic alternative is an `integration_test`, which is
  how `connection_test.dart` and `lobby_flow_test.dart` already work.
- **A rendered PNG was not committed.** `flutter test` uses a placeholder font, so all text renders as
  boxes; shipping that as "evidence" would misrepresent it. It served its purpose during the session
  and was deleted.
- **`PLAN.md` was updated to match reality**: P4.1–P4.8 ticked, status line rewritten, P4.9 and P4.10
  left unticked with notes on exactly what is and is not covered.

## 6. Open items

1. **P4.9 rematch flow** — blocked. `CREATE_REMATCH` falls through to
   `default: throw new LobbyError('NOT_IMPLEMENTED')` in `rooms.ts`, and `docs/protocol.md` records
   rematches as deliberately deferred. The server command has to exist first.
2. **P4.10 physical devices** — Android hardware, real iPhones, Safari and real pinch/pan gestures
   are unverified. Only the iOS simulator was exercised.
3. **Modal surfaces are untested.** The device matrix never opens the trade sheet, discard picker,
   Monopoly dialog or Year of Plenty picker, so their layout at 2.0× text on a 320px screen is
   unproven — including my 3.5 fix. Worth a follow-up that opens each modal inside the matrix.
4. **Client legality mirror.** `model.dart`'s `targets()`, `canRoad` and `canSettle` duplicate engine
   rules in Dart. They are correctly advisory, but they can drift from `rules.ts`. Consider a shared
   fixture that asserts the Dart previews agree with engine output on a known board.
5. Phase 5 still owns the live transport, the lobby→game navigation, and ordered recipient-specific
   deltas.

## 7. Files

| File | Status |
| --- | --- |
| `apps/mobile/lib/game/board.dart` | fixed (import, braces, height-flexibility) |
| `apps/mobile/lib/game/controller.dart` | fixed (braces) |
| `apps/mobile/lib/game/model.dart` | unchanged |
| `apps/mobile/lib/game/game_screen.dart` | **new** |
| `apps/mobile/lib/preview.dart` | **new**, dev-only harness |
| `apps/mobile/test/game_test.dart` | **new**, 23 tests |
| `apps/mobile/test/preview_test.dart` | **new**, 3 guards |
| `PLAN.md` | status line, P4.1–P4.8 ticked, P4.9/P4.10 annotated, Phase 4 section note |
