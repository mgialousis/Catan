# Island Table

A Flutter client and authoritative NestJS backend for a private, base-game multiplayer board game. **Phase 1 is the connection and protocol foundation. Rooms and gameplay are not implemented yet.**

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

Press **Connect as guest**. The app should show **Connected. Your guest session is ready.** Reopening the app restores the guest session. Nicknames, invitation links and lobby screens belong to Phase 2.

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

The Web test checks guest connection and session reuse after reload and writes screenshots in `docs/screenshots`. The local Auth tests create synthetic guest identities. Database constraint tests roll back their test rows.

Stop the API/Flutter/static-server terminal processes with Ctrl+C. Run `npm run local:stop` to stop this project's Supabase services while retaining local data. Avoid `supabase db reset` once data matters; it is not a normal startup command.

## Repository boundaries

| Directory | Responsibility |
| --- | --- |
| `apps/mobile` | Flutter application, Riverpod connection/session state |
| `apps/server` | NestJS, JWT verification, transport guards, PostgreSQL connection |
| `packages/protocol` | Canonical draft-07 schemas, pure TypeScript contracts, shared fixtures |
| `packages/game-engine` | Canonical state partitions and transition contracts; no rules implementation yet |
| `supabase/migrations` | Private application schema, roles, constraints and permissions |
| `tests/local` | Database and real Auth/gateway verification |

Read [protocol decisions](docs/protocol.md), [pinned rules](packages/game-engine/RULES.md), [verification evidence](docs/phase-1-verification.md), and the full [execution plan](PLAN.md).

To verify API packaging locally (Docker Desktop and local Supabase running):

```sh
docker build -f apps/server/Dockerfile -t island-table-api:phase1 .
node scripts/check-docker.mjs
```

This starts a temporary container on port 3300, checks non-root execution, readiness and authentication, then stops it. It uses development-mode local Auth, not hosted TLS.

`render.yaml`, the API Dockerfile and `scripts/build-web.sh` prepare future deployment. Nothing is deployed in Phase 1. Render/Supabase hosted setup and real multiplayer acceptance remain later milestones.
