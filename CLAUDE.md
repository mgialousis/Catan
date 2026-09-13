# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Island Table** — a private multiplayer base-game board game (working name; original presentation, no licensed assets). Flutter client (Web/iOS/Android) plus an authoritative NestJS/Socket.IO backend on Supabase PostgreSQL.

`PLAN.md` is the approved execution blueprint and the source of truth for scope; it defines seven phases with exit gates. **Phases 1–6 are implemented and locally verified; Phase 7 (deployment) is in progress.** Do not start work on a phase the user has not authorized. When work changes the plan's state, update the `PLAN.md` checkboxes, the matching `docs/phase-N-verification.md` (evidence) and `docs/protocol.md` (decisions) alongside the code. Tick a checkbox only for what is actually verified — narrowing a criterion to make it tickable is the user's call, not the implementer's.

**The stack is deployed and live** on free tiers (see `docs/deployment.md` and `docs/phase-7-verification.md`):

| | |
| --- | --- |
| Web client | https://island-table-web.onrender.com |
| API | https://island-table-api.onrender.com |
| Database / Auth | Supabase project `dybismsqbzubwzzfrnfo` (eu-central-1) |

Render auto-deploy is deliberately **off** (`autoDeployTrigger: "off"` in `render.yaml`), so a push never
interrupts a game in progress; deploys are explicit. Free instances sleep after 15 minutes idle, so the
first request takes about a minute. Hosted operator values live in ignored `.local/operator.env`.

## Commands

Setup and daily loop are in `README.md`. In short, from the repo root:

```sh
npm ci
npm run protocol:sync     # copy canonical schema + events into Flutter assets (gitignored)
npm run local:start       # local Supabase in Docker; log at .local/supabase-start.log
npm run local:configure   # rotates the island_runtime password; writes .env, .local/test-env.json, apps/mobile/config/*.json
npm run dev:server        # builds, then runs apps/server/dist/main.js with --env-file=.env
```

`npm run local:migrate` applies new migrations to an existing database. Avoid `supabase db reset`. Restart the backend after re-running `local:configure` (the database password changed).

### Tests

```sh
npm test                  # build + engine/protocol/server tests; no services needed
npm run test:local        # local Supabase suite, wrapped by scripts/check-local-tests.mjs
npm run test:container    # after: docker build -f apps/server/Dockerfile -t island-table-api:phase7 .
npm run test:web          # Playwright/Chrome lobby smoke against a local static build on 127.0.0.1:8080
npm run test:web:game     # four-client browser game; test:web:timers adds the timed variant
npm run hosted:preflight  # readiness/version/cache/auth probe of a deployment (needs the four public URLs)
npm run hosted:retention  # operator-only 30-day cleanup against a hosted database
```

`test:local` fails the run if any of the six application tables changed row count, so a leaked test
fixture cannot pass unnoticed. Both browser suites need the single active room slot free.

Node tests import **compiled `dist/` output**, so a bare `node --test <file>` needs `npm run build` first:

```sh
npm run build && node --test apps/server/test/auth.test.mjs
npm run build && node --test --test-name-pattern 'reject expired' apps/server/test/auth.test.mjs
```

Flutter (from `apps/mobile`; the Dart protocol test reads `../../packages/protocol/...` by relative path, so the working directory matters):

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test --reporter=expanded
flutter test test/protocol_test.dart --plain-name 'accept CREATE_ROOM'
flutter test integration_test/connection_test.dart -d DEVICE_ID --dart-define-from-file=config/local.json
```

There is no ESLint/Prettier setup: `npm run typecheck` is an alias for the strict `tsc` build, and `flutter analyze` covers Dart.

Toolchain versions are pinned (`.nvmrc` 22.20.0, `.flutter-version` 3.38.8) and every npm/pub dependency is an exact version with a committed lockfile. Do not upgrade dependencies or SDKs as incidental work.

## Architecture

```
apps/mobile        Flutter client; Riverpod providers in lib/core (config, connection, protocol, secure storage)
apps/server        NestJS: config -> auth (JWT) -> gateway (Socket.IO /game) -> database (pg Pool)
packages/protocol  Canonical draft-07 JSON Schema + events map + shared fixtures + pure TS contracts
packages/game-engine  Pure rules engine: board generation, complete base-game commands, invariants, projections
supabase/migrations   app schema, island_owner/island_runtime roles, RLS, constraints
tests/local        Real local Postgres and real Auth/Socket.IO verification
```

**The database is authoritative; in-memory state is a disposable cache.** Clients use Supabase only for anonymous authentication; all room/game data flows through NestJS. The `app` schema is not exposed through the Supabase Data API.

### Protocol is the cross-language contract

`packages/protocol/schemas/v1.json` (draft-07) is the wire source of truth; `events.json` maps each Socket.IO event name to a schema definition. TypeScript validates with Ajv, Dart validates with `json_schema` against a **byte-identical bundled copy** in `apps/mobile/assets/protocol/` — generated by `npm run protocol:sync` and gitignored; a Dart test asserts the byte equality. `fixtures/contracts.json` holds shared positive/negative cases run by both languages. There is no generated cross-language type sharing.

Changing the wire format means touching all of: the schema definition, `events.json` (for a new event), `fixtures/contracts.json`, the gateway `@SubscribeMessage` handler, then re-running `protocol:sync` and both test suites.

`@island/protocol` has two entry points on purpose: `./contracts` is pure (no fs/socket/database/env access) and is what the engine imports; the root `.` entry reads the schema files from disk. Keep the engine free of I/O.

Version identifiers appear in four places that must stay consistent: `PROTOCOL_VERSION`/`STATE_SCHEMA_VERSION`/`RULES_VERSION` in `contracts.ts`, the `app.schema_migrations` row, `Database.ready()` (which rejects startup on a mismatch, and also rejects connecting as any role other than `island_runtime`), and the `/api/v1/version` response.

### Privacy model

`CanonicalState` (game-engine) separates `publicState`, a player-keyed `privateState` map, server-only `serverState` (bank, deck, random outcomes) and `clockState`. Serialization is allowlisted: build outputs with explicit projection functions like `projectPlayer`, and produce deltas by diffing **already authorized projections** — never by diffing full secret state and filtering paths afterwards. The same boundary applies to logs, errors and reconnect responses. Schema validation of a patch is not proof of privacy or legality.

### Server invariants worth preserving

- The gateway fails closed: every read and command path checks current membership under the room lock, and a rejection commits only a sanitized receipt — never a fabricated success. `apps/server/src/games.ts` follows the PLAN §1.5 lock order exactly (runtime fence → per-actor command advisory lock → receipt lookup → room row → game row), and the receipt is checked *before* version rejection.
- Every packet is rate-limited, schema-validated against `events.client`, and re-authenticated (`auth.refresh` verifies the incoming token in its handler instead). Token expiry disconnects the socket.
- Errors reaching clients go through `safeError()` — a fixed code/message allowlist. Never log payloads, tokens, SQL credentials or private state.
- `loadConfig` strips `sslmode`/`sslcert`/`sslkey`/`sslrootcert` from `DATABASE_URL` so a connection string cannot silently disable TLS, and refuses `LOCAL_JWT_SECRET`, non-HTTPS issuers/JWKS, non-HTTPS origins or `DATABASE_TLS=false` when `NODE_ENV=production`. HS256 is a local-only fallback used when local Supabase has no JWKS keys.
- Socket.IO is WebSocket-only on namespace `/game`, path `/socket.io`, with a 16 KiB inbound cap, an explicit browser origin allowlist and per-IP connection limits. It is not a raw WebSocket endpoint. Tokens travel in the handshake `auth` object, never in query strings.
- Database work goes through `Database.transaction()` (one checked-out client, bounded timeouts, rollback, release) — not independent Supabase REST calls. `PLAN.md` §1.5 specifies the lock order and duplicate-command receipt algorithm that future command handlers must follow.

### Client

`AppConfig` reads `API_URL`/`SUPABASE_URL`/`SUPABASE_ANON_KEY` from `--dart-define`s only (public values); `config/local.json` and `config/android.json` are generated and gitignored, `config/local.example.json` is the committed template. Android uses `10.0.2.2` to reach the host. Native sessions persist through `SecureSessionStorage` (Keychain / Android encrypted storage); Web uses the Supabase SDK's own storage. A failed refresh must never silently create a replacement guest identity — identity loss has no recovery path in v1.

## Rules reference

`packages/game-engine/RULES.md` pins the English 2020 base rulebook revision `2020_200707` as `base-2020-v1`, with a checksum. The copyrighted PDF is not bundled. Rules questions are answered against that pinned revision, and interpretation decisions (e.g. Road Building interruption) are recorded there rather than being re-decided in code.

## Repository hygiene

Phase 1 deliberately performed no commits, pushes, hosted deployments or paid resource creation — the branch still has no commits. Keep secrets in the gitignored `.env`/`.local/`; `.env.example` carries names and placeholders only.

## Tooling available in this workspace

MCP servers are configured in the ignored `.mcp.json` and via plugins; they reach real infrastructure,
so treat their write operations the way you would a production console.

| Server | Reaches |
| --- | --- |
| `supabase` | The live project `dybismsqbzubwzzfrnfo` — SQL, migrations, advisors, logs |
| `render` | The live `Catan` workspace — services, env vars, deploys, logs |
| `dart-flutter` | Local analyze/test, plus launching and hot-reloading the app on a device |

Prefer the Dart/Flutter MCP tools over shelling out to `flutter`. Note that automated layout tests
catch *overflow*, not *wrongness*: running the app on a real device has caught defects a green suite
missed, so verify visual work on a device or a rendered screenshot.

Locally installed agent tooling (`.agents/`, `skills-lock.json`, `.mcp.json`, `.claude/skills/`) is
gitignored and is not part of the pinned toolchain.
