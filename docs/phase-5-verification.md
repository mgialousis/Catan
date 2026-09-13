# Phase 5 — durable authenticated multiplayer

Implemented locally on 2026-09-10; Claude Round 4 review fixes verified on 2026-09-11. Phase 6 is not started. No hosted infrastructure, paid service, deployment, commit or push was performed.

## What works

A host creates a private room; three or four authenticated anonymous guests join and ready up. Starting creates the actual randomized engine state and opens the game screen for all members. Commands use the verified Auth subject's player ID, enforce current phase/version and persist the canonical state, replay log, per-viewer outbox and receipt in one transaction. The server checks invariants before and after every engine move.

Recipient updates are computed from already authorized public/owner projections. All public halves must compare equal before one common envelope is stored. Snapshots and ordered outbox delivery share a per-room queue; room/game locks serialize writers. Retries resolve the original durable receipt before checking current game version. Outbox delivery may repeat a version; clients discard duplicates and resynchronize on gaps or periodic version mismatch.

Flutter applies public and private patches atomically, validates the resulting complete snapshot, and verifies room/owner identity. It saves one unconfirmed intent before sending, retries the same ID after 1/2/4/8-second delays, then offers manual retry. Reload first obtains the authorized snapshot, then resolves the saved ID. Native pending storage is secure device storage; Web uses per-tab sessionStorage to prevent other tabs overwriting the pending intent. Private snapshots are never persisted by the client. Closing a Web tab discards that tab's unconfirmed envelope; the guest can still restore committed state.

Public history requires authenticated membership, is limited to 50 entries per server request (the app asks for 30), and uses exclusive sequence pagination. Raw move payloads, effects and entropy are not returned. The Flutter history window is bounded to 300 sequences. A completed game frees the active slot; its host can create a new private invitation without changing the old results. Other players return to tables to join it.

Time limits are visibly unavailable and timed starts receive a schema-valid terminal rejection. The authoritative scheduler, timeout fallback, disconnect pause/resume, heartbeat recovery and abandonment belong to Phase 6. Persisted-state recovery after a restart is implemented; clock freezing/recovery is not claimed.

## Verification

Toolchain: Node 22.20.0, npm 10.9.3, Flutter 3.38.8/Dart 3.10.7, local Supabase CLI 2.117.0, Docker/PostgreSQL/Auth; Chrome 153; Android API 35 emulator; iPhone 17 Pro/iOS 26.2 simulator.

| Check | Result |
| --- | --- |
| `npm test` | **207 passing**, including 12 practice-harness tests and strict TypeScript builds |
| `npm run test:local` | **38 passing**; migrations, restricted roles/Auth, lobby and durable gameplay |
| Application table residue | All six table counts unchanged before/after the full local suite; enforced by its runner |
| `flutter analyze --no-pub` | **No issues** |
| `flutter test --no-pub --reporter expanded` | **237 passing**, including 32 real TypeScript-generated delta pairs, five client-recovery tests and two timed-rejection fixtures |
| Four production Flutter Web clients | Invitation, readiness/start, 16 actual setup placements, dice roll, private seat restoration and same-ID reload after deliberately dropping the acknowledgement passed |
| Native interactive practice | Three tests passed on Android; three on iPhone simulator; see Phase 4 evidence for scope |
| Production entry-point builds | Web release, Android debug APK and iOS simulator app all built successfully with local configuration |

The local gameplay integration checks cover:

- Schema-valid timed rejection with a successful return to untimed setup; concurrent starts; three-player start versus fourth join; duplicate command IDs.
- Precommit rollback, committed move with lost acknowledgement, and delivery failure between outbox send and marking it published.
- Real four-client setup and exact replay of persisted commands with recorded time/entropy, including JSONB object ordering.
- Concurrent conflicting builds, trade acceptances, the final bank resource and final development card; conservation and one committed version.
- Wrong-room and non-member rejection; owner-only distinctive card IDs; sanitized history pagination; token refresh and refusal of subject switching; duplicate tabs preserving ownership.
- Dropped final frame repaired by version probe/snapshot; process replacement fences the old writer and restores the same board/hands; unpublished updates recover; actual victory and idempotent host-only rematch.

Only controlled synthetic scenarios use privileged database seeding for last-stock/deck and victory edge cases. No production route seeds state. Ordinary setup and the browser flow use real user commands. Test hooks are constructor-injected, privately held, and rejected by app construction for production or non-local databases; there is no network-accessible crash/debug surface.

The local runner checks rooms, players, game_states, move_logs, outbox_events and command_receipts for count drift. It deliberately excludes synthetic Supabase Auth users and runtime-epoch metadata. It never deletes unrelated records. The Web gameplay smoke cleans only its synthetic room; the older lobby Web smoke retains abandoned rows under the documented retention policy.

## Running and reviewing

Follow [README local setup](../README.md). In separate terminals:

```sh
# Repository root, after local:start/local:configure
npm run dev:server
# apps/mobile
flutter run -d chrome --web-hostname=127.0.0.1 --web-port=8080 --dart-define-from-file=config/local.json
```

Open separate browser profiles or configured simulators, choose nicknames, join one invitation, ready all players and start. Use no time limit. Web and native share the same production entry point. The Android emulator uses `config/android.json`; an iPhone simulator uses `config/local.json`. Physical phones require reachable LAN addresses and appropriate Web origins; localhost links only work on the computer.

For the automated browser check, build and serve the production Web release on port 8080 with the API on port 3000, then run `npm run test:web:game`. This deliberately drops a gameplay acknowledgement, reloads the client and verifies that the resent envelope has the same command ID and that the database version does not advance twice. Screenshots: [portrait](screenshots/phase-5-live-portrait.png), [landscape](screenshots/phase-5-live-landscape.png).

Run `npm run fixtures:game` only when deliberately updating the engine-to-Dart golden deltas; `npm test` checks regeneration equality. `npm run protocol:sync` refreshes Flutter's canonical validator assets.

Stop preview games before `npm run test:local`; tests claim the single runtime epoch. Restart the preview API afterward. Do not reset the database to free a real game. Before Phase 6, an active game retains the slot until completion.

## Claude Round 4 disposition

The original [independent review](review-2026-09-09-claude.md) is preserved.

| Finding | Resolution |
| --- | --- |
| R4-1 invalid timed-mode error/ack | Added the enum value, shared error and ack fixtures, asset synchronization, and a real authenticated timed-start/recovery integration test. Timed options are disabled in the current UI. |
| R4-2 orphaned gameplay smoke | Added `npm run test:web:game`, README instructions and this evidence record. |
| R4-3 stale status/missing evidence | Reconciled PLAN status, authorization, P2.8/P4/P5 gates and added Phase 4/5 verification documents. |
| R4-4 README drift | Updated rules-engine boundary, Phase 1–5 hosting status, evidence links and gameplay verification instructions. |
| R4-5 two analyzer infos | Added braces to the nested test loops and verified a clean analyzer. |
| R4-6 leaked receipt | Traced to the gateway suite's newly persisted denied game command, not a gameplay-room row. Teardown now removes its own actor's receipts; the full local runner detects future application-table count drift. |
| R4-7 arbitrary viewer's public half | Added runtime deep equality across all public envelopes, including activity, before sharing one. A regression test rejects divergent recipient views. |
| R4-8 production crash-hook surface | Removed the public mutable service field. Hooks now use private constructor injection, local-only app test construction and explicit production rejection. |

The review's remaining modal-coverage note refers to the earlier Claude progress record: the current `game_flow_test.dart` opens and scrolls 24 modal configurations. Both Android and iOS simulators have now run the three interaction tests. Physical devices and Safari still remain open.

## Limits

No full human four-phone match, Safari/WebKit run, signed physical-device build, hosted deployment, real mobile-network test or sustained load test is claimed. Native authenticated multi-player interaction still needs a device acceptance session; the native gesture scenarios use the development harness. Web multiplayer/auth/persistence is verified through the production entry point. Production TLS/JWKS, Render ingress/process routing, Linux Flutter packaging and hosted retention are Phase 7 work.

The Web release build reports an existing optional Cupertino icon-font warning; the app uses Material icons and the JavaScript build succeeds. No package upgrade was performed to silence it.

No new migration was needed in Phase 5: the existing schema already supplies state/log/outbox/receipt storage and runtime fencing; the local database suite continues to verify migrations/permissions. The v1 public shape was finalized before gameplay deployment; future required schema changes need an explicit version/migration strategy.
