# Island Table

A Flutter client and authoritative NestJS backend for a private, base-game multiplayer board game. **Play with 3–4 guests in a private room, with optional turn timers, saved disconnect pauses and restart recovery (Phases 1–6).**

The same Flutter project targets Web, Android and iOS. Development uses local Supabase Auth/PostgreSQL through Docker. No hosted services are required for this phase.

## Prerequisites

- Node **22.20.0**, npm **10.9.3**; `.nvmrc` pins Node.
- Flutter **3.38.8**, Dart **3.10.7**; `.flutter-version` pins Flutter.
- Docker Desktop running. Supabase CLI **2.117.0** is installed by `npm ci`.
- Android: installed SDK/JDK 17 and an emulator or device.
- iOS: macOS, Xcode and CocoaPods. Simulator tests require no Apple membership; physical-device signing is configured separately.

Exact package versions and both package-manager lockfiles are included. Do not update dependencies as part of routine setup.

## Start locally

From the repository root:

```sh
npm ci
npm run protocol:sync
npm run local:start
npm run local:configure
npm run dev:server
```

`local:start` creates only this project's local Docker services, applies migrations on a fresh database, and saves CLI output in ignored `.local/supabase-start.log`. On an existing database, apply new migrations with `npm run local:migrate`.

`local:configure` creates a random runtime password and writes ignored `.env`, local test configuration, and public Flutter configurations. It refuses non-local database URLs. Running it again rotates that password; restart the backend afterwards. No cloud account or credentials are needed.

In a second terminal:

```sh
cd apps/mobile
flutter pub get --enforce-lockfile
flutter run -d chrome --web-hostname=127.0.0.1 --web-port=8080 --dart-define-from-file=config/local.json
```

Enter a nickname and press **Connect as guest**, then **Create private table** or **Join table**. Share the host's invitation link/code with up to three friends. Everyone chooses a colour and readies up; **Start game** opens the board for all 3–4 connected players. Reopening the app restores the same guest, seat and private hand from the server. Choose **No time limit**, **60**, **120** or **180 seconds** before starting. Setup is untimed. Required-player disconnects save the remaining budget; the host can pause, resume or confirm abandonment. After an API restart, the host must resume the recovered game.

Local endpoints:

| Endpoint | Use |
| --- | --- |
| `http://127.0.0.1:3000/health/live` | Process health |
| `http://127.0.0.1:3000/health/ready` | Database role and schema compatibility |
| `http://127.0.0.1:3000/api/v1/version` | Public protocol/rules identifiers |
| `http://127.0.0.1:54321` | Local Supabase API/Auth |
| PostgreSQL port `54322` | Local database |

Socket.IO uses namespace `/game`, path `/socket.io`, and WebSocket transport. It is not a raw WebSocket endpoint.

## Native targets

Signed Android APKs are built automatically for changes to the app/build configuration on `main`.
Open [Android APK builds](https://github.com/mgialousis/Catan/actions/workflows/android-apk.yml),
select a successful run and download its `island-table-android-*` artifact. Extract the ZIP and
install `island-table.apk`. These builds connect to the hosted game. You can also select
**Run workflow** to request a fresh build. See [Android build setup](docs/android-builds.md).

List device IDs with `flutter devices`, then from `apps/mobile`:

```sh
# Android emulator uses 10.0.2.2 to reach the host.
flutter run -d emulator-5554 --dart-define-from-file=config/android.json

# Replace DEVICE_ID with an available iPhone simulator identifier.
flutter run -d DEVICE_ID --dart-define-from-file=config/local.json
```

For physical phones, use a copy of the public configuration with the computer's reachable LAN address for API_URL and SUPABASE_URL. Keep the backend's JWT issuer set to the issuer actually emitted by local Auth. Simulator success does not verify physical-device signing, LAN firewall rules, Safari, or mobile-network transitions.

Android internet permission is declared; HTTP cleartext is allowed only in the debug manifest. Release signing is intentionally unconfigured. iOS declares local-network usage and Keychain entitlement, with no developer team committed. Native session secrets use Keychain/encrypted Android storage; Web uses Supabase SDK session storage. App data backup is disabled on Android.

## Verification

```sh
# Root: strict TypeScript build, schemas, auth and state-partition tests.
npm test

# Stop your preview API and close any preview lobby first. Tests claim the single runtime epoch.
# Root: local Postgres constraints/permissions and actual Auth/Socket.IO.
npm run test:local

# Flutter unit and widget tests; shared JSON fixtures are read from the root packages.
cd apps/mobile
flutter analyze
flutter test --reporter=expanded

# Run once for each booted native target, with its corresponding config file.
flutter test integration_test/connection_test.dart -d DEVICE_ID --dart-define-from-file=config/local.json --reporter=expanded
```

For the Web release smoke test, keep the API running:

```sh
# In apps/mobile
flutter build web --release --dart-define-from-file=config/local.json

# In a terminal at the root
python3 -m http.server 8080 --bind 127.0.0.1 --directory apps/mobile/build/web

# In another terminal at the root; uses an existing Google Chrome installation.
npm run test:web
```

The Web test opens five independent guest sessions, verifies invitation onboarding, the four-seat limit, readiness, start guards and reload identity reuse, then marks its synthetic lobby abandoned. Its room/player/outbox rows intentionally remain for the 30-day retention policy; this smoke test does not delete its database history. It writes Phase 2 screenshots in `docs/screenshots`. Run it with no other active lobby. The local Auth tests create synthetic guest identities; database fixtures roll back; lobby, gameplay and gateway tests delete their own application records. The local test runner checks that all six application table counts remain unchanged. Restart `npm run dev:server` after `test:local`, because the tests exercise runtime replacement.

Stop the API/Flutter/static-server terminal processes with Ctrl+C. Run `npm run local:stop` to stop this project's Supabase services while retaining local data. Avoid `supabase db reset` once data matters; it is not a normal startup command.

## Repository boundaries

| Directory | Responsibility |
| --- | --- |
| `apps/mobile` | Flutter application, Riverpod connection/session state |
| `apps/server` | NestJS, JWT verification, transport guards, PostgreSQL connection |
| `packages/protocol` | Canonical draft-07 schemas, pure TypeScript contracts, shared fixtures |
| `packages/game-engine` | Pure base-game rules, board topology, invariants, projections and deterministic replay |
| `supabase/migrations` | Private application schema, roles, constraints and permissions |
| `tests/local` | Database and real Auth/gateway verification |

Read [protocol decisions](docs/protocol.md), [pinned rules](packages/game-engine/RULES.md), [Phase 1 evidence](docs/phase-1-verification.md), [Phase 2 evidence](docs/phase-2-verification.md), [Phase 3 evidence](docs/phase-3-verification.md), [Phase 4 evidence](docs/phase-4-verification.md), [Phase 5 evidence](docs/phase-5-verification.md), [Phase 6 evidence](docs/phase-6-verification.md), [Phase 7 progress](docs/phase-7-verification.md), and the full [execution plan](PLAN.md).

To verify API packaging locally (Docker Desktop and local Supabase running):

```sh
docker build -f apps/server/Dockerfile -t island-table-api:phase1 .
node scripts/check-docker.mjs
```

This starts a temporary container on port 3300, checks non-root execution, readiness and authentication, then stops it. It uses development-mode local Auth, not hosted TLS.

## Playing on the hosted deployment

The free deployment is live: open **https://island-table-web.onrender.com**, enter a nickname, create a
private table and share the invitation link with up to three friends.

| Service | URL |
| --- | --- |
| Web client | https://island-table-web.onrender.com |
| API | https://island-table-api.onrender.com |

The API sleeps after 15 minutes idle, so the first person in takes about a minute to connect. Automatic
deployment is off on purpose, so pushing to `main` never interrupts a game; deploy explicitly between
sessions. Verify a deployment with `npm run hosted:preflight` (needs `API_URL`, `WEB_URL`,
`SUPABASE_URL` and `SUPABASE_ANON_KEY`). See the [deployment runbook](docs/deployment.md) and
[Phase 7 evidence](docs/phase-7-verification.md); real-device and separate-network acceptance is still
open.

## Phase 2 operations

- Web invitation: `http://127.0.0.1:8080/?invite=CODE`. Installed native invitation: `islandtable://join?invite=CODE`.
- For separate physical phones, use reachable LAN addresses in each public configuration and add the chosen Web origin to the server's `WEB_ORIGINS`. A localhost browser link works only on the host computer. Native custom links require the app already installed; store-install deferred links and hosted universal links are later work.
- Only one ongoing lobby or game fits the initial capacity. Before starting, leave with every member to close the lobby, or let it expire after 24 hours. Active games retain the slot until completion or host-confirmed **Abandon game**. Do not reset the database just to free a table.
- If a command reply is interrupted, use **Retry saved action**. It checks the original durable request; it does not create another room or seat.
- Preview 30-day operator cleanup with `npm run local:retention`; apply it deliberately with `npm run local:retention -- --apply`. Export any terminal records you want to keep first. The command preserves ongoing rooms and compact receipt tombstones and supports only local databases in this phase.
- Run `flutter test integration_test/lobby_flow_test.dart -d DEVICE_ID --dart-define-from-file=config/local.json --reporter=expanded` for the native lobby flow, substituting `config/android.json` on the Android emulator.
- Keep `TRUSTED_PROXY_HOPS=0` locally. Verify proxy forwarding and TLS before hosted deployment; no hosting was deployed in this phase.

## Phase 3 rules engine

`npm test` builds all TypeScript packages and runs protocol, engine and server tests without Docker. To run just the complete, reproducible three/four-player matches after building:

```sh
node --test packages/game-engine/test/matches.test.mjs
```

The engine exports `createGame`, `applyCommand`, `projectGame`, `projectPublic`, `projectEffects`, and `replayRandom` from `@island/game-engine`. It takes explicit server time and entropy, returns a new canonical state plus typed effects and recorded draws, and performs no I/O. The backend uses a cryptographic entropy adapter and persists accepted moves and replay context transactionally. See [rules and application policies](packages/game-engine/RULES.md) and [verification, scope and review follow-ups](docs/phase-3-verification.md).

## Live gameplay and recovery (Phases 5–6)

The server owns all moves. Accepted moves save the board/hands, replay log, per-player updates and command receipt in one PostgreSQL transaction. The client saves an unconfirmed action before sending it, retries the same ID with bounded backoff, and synchronizes after reconnect or a version gap. Web intent storage is per tab and survives reload; native intent storage is secure device storage. Private snapshots are not saved by the app. An intentionally closed browser tab loses its pending intent; reopening still restores committed state for the same guest.

The host can create a fresh invitation after a win. Other players use **Back to tables** and join it. This creates a new room; completed results remain separate.

Additional checks from the root (the production Web build must be served on port 8080 and the local API on 3000):

```sh
npm run test:web:game
npm run test:web:timers
```

This uses four isolated Chrome sessions and a synthetic local room, including an acknowledgement deliberately dropped before reload. It removes only that room afterward. Do not run database integration tests concurrently with a preview game: they claim the single runtime epoch.

For UI practice without auth or database writes:

```sh
npm run preview:engine
# Separate terminal:
cd apps/mobile
flutter run -t lib/preview.dart -d chrome --web-port=8081
```

The practice entry point has nine scenarios and automated opponents using the real pure engine. It is excluded from `main.dart`; its rematch link is only a practice reset. Use `--dart-define=PRACTICE_URL=http://10.0.2.2:3001` on Android. Native practice interaction tests are in `integration_test/game_flow_test.dart`.

See [Phase 4 verification](docs/phase-4-verification.md) [Phase 5 verification](docs/phase-5-verification.md), and [Phase 6 verification](docs/phase-6-verification.md) for evidence and platform limits. Hosted infrastructure is now configured on free tiers only; no paid service or store publication exists.

## Phase 7 deployment preparation

Claude's Round 5 observations are addressed. Linux API/Web packaging, public configuration validation, operator retention and Android release signing are prepared. Native hosts can share the configured `WEB_URL` with friends using mobile browsers. See [deployment instructions](docs/deployment.md) and [Phase 7 progress](docs/phase-7-verification.md).

**Phase 7 is not complete:** the reviewed UI/TLS fixes are deployed and migration history is reconciled. Deployment preserved a paused hosted game. Measured ingress, broader hosted recovery acceptance, iOS provisioning and real-device/network acceptance remain open. Builds made with `config/release.example.json` or default Docker Web arguments have placeholder URLs and are packaging checks only. Keep `.local/signing` and `android/key.properties` backed up privately; they are excluded from Git.
