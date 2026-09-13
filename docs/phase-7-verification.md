# Phase 7 progress — deployment preparation

Status: **partially implemented; hosted deployment and the Phase 7 exit gate are not complete.** No hosted resources or paid plans were created. Work used one agent. See the [deployment runbook](deployment.md) for the concrete configuration and remaining acceptance steps.

## Claude Round 5 disposition

The authored review is preserved in `review-2026-09-09-claude.md`.

| Finding | Change |
| --- | --- |
| R5-1 narrowed P4.10 acceptance | Reopened the checkbox. Simulator/local evidence remains documented; it does not satisfy physical-phone acceptance. |
| R5-2 obsolete timed error wording | Kept the compatible enum entry and replaced the false message with a neutral unsupported-setting rejection. |
| R5-3 unused `last_seen_at` | Authorized subscriptions now update this advisory timestamp at most once per minute per player. Live sockets still determine presence. The four-player integration suite checks that all seats receive a timestamp. |
| R5-4 room ownership retry loop | Commands, timers and scheduler checks retire through the shared ownership-loss path, stop scheduling and disconnect sockets. A regression test verifies retirement is idempotent. |

## Implemented preparation

- Verified the API Docker build for Linux/amd64 with its non-root runtime, database readiness and actual authenticated Socket.IO handshake against local Supabase.
- Replaced the untested Git-clone Web installer with the official Flutter 3.38.8 Linux archive, pinned SHA-256 `68f702b9ea9b63259924bf6cb2330e0f6e076898958709dd28571f27bcf12fba` and revision `bd7a4a6b5576630823ca344e3e684c53aa1a0f46`. The Linux Web build enforces the Dart lockfile and disables generated offline service-worker behavior. `scripts/Dockerfile.web` reproduces it locally and exports to `.local/linux-web`.
- Added public configuration validation: HTTPS origins only and Supabase public anon/publishable keys only. Privileged keys and URLs carrying credentials are rejected before compilation.
- Added `WEB_URL` for native invitations and rematches. Both can now lead to the free Web client, including for friends without the native app installed. Local development keeps the custom-link fallback.
- Configured dedicated Android release signing with ignored local material; unsigned/debug-key release fallback is refused. The helper will not overwrite an existing key.
- Added hosted operator retention with verified TLS, default dry run, explicit host confirmation for apply, operator-role checks and count reporting. The underlying retention transaction already has local coverage; hosted invocation is not yet verified.
- Added a finite hosted preflight for readiness, protocol/rules compatibility, static caching, explicit forged-token rejection and basic HTTP timing. A connection/network error cannot be mistaken for successful auth rejection. No guest/game is created by this script. Its hosted execution remains pending.
- Kept Render services free and manual-deploy-only. Documented migrations, restricted runtime credentials, ingress verification, certificate trust, native install limits, backup/restore, rollback, quotas and game-night recovery.

## Verified evidence

| Check | Result |
| --- | --- |
| `npm test` | **219 passing**, including strict TypeScript build, ownership retirement and deployment configuration tests |
| `npm run test:local` | **56 passing**, including maintained activity timestamps; all six application-table counts unchanged |
| `flutter test --no-pub --reporter expanded` | **261 passing**, including public Web invitation generation/round-trip parsing |
| `flutter analyze --no-pub` | **No issues** |
| API Linux/amd64 Docker build | Passed; dependencies audited with zero reported npm vulnerabilities during the image build |
| Container smoke | Non-root UID 1000, database readiness and authenticated Socket.IO passed |
| Flutter Linux/amd64 Web build | Passed using the actual checked-in installer/build helper and checksum verification; artifact approximately 32 MB uncompressed |
| Android release APK | Built with dedicated signing; `apksigner verify --print-certs` passed |
| iOS device-target build | `flutter build ios --debug --no-codesign` passed; **unsigned, not installed** |
| Repository hygiene | Signing files, secrets, local configuration and generated artifacts remain ignored; syntax/diff checks pass |

Release certificate SHA-256 (public fingerprint): `4505ccee3645bf3ee5f61fa65f15217684311ca4f5d76b8c1dba3b3f2e6f8ee8`.

The release APK and iOS/Web packaging artifacts use clearly marked `example.invalid` URLs/public test keys. They demonstrate packaging, not a playable hosted release. Rebuild with the selected service URLs before distribution. Securely back up `.local/signing/` and `apps/mobile/android/key.properties` before distributing Android updates.

Local sizing only: the API container used **85.98 MiB** with one authenticated idle client (Docker's host allocation was 7.748 GiB; no Free-plan memory limit was simulated). Across 48 owner-snapshot fixtures, JSON sizes were **13,112–14,894 bytes**, with a maximum gzip size of **2,940 bytes**. These measurements are not a four-client soak, a bandwidth estimate for complete games or hosted performance acceptance.

The Linux Web build reports the existing optional Cupertino font warning and a Docker linter warning for the public `SUPABASE_ANON_KEY` argument. The public-config validator refuses privileged keys; no private key is compiled. No new dependency upgrade was performed.

## Hosted Supabase provisioning — 2026-09-13 (Claude)

Project `dybismsqbzubwzzfrnfo` (`https://dybismsqbzubwzzfrnfo.supabase.co`) was reachable through the
Supabase MCP server, so P7.2's database half was carried out. **Divergence from the runbook:** the
migration was applied through MCP `apply_migration` rather than `supabase db push`, because no CLI
access token is configured. It was recorded under the same name as the checked-in file
(`20260909000100_foundation`), so local and remote history stay aligned.

Pre-state confirmed fresh before writing anything — no `app` schema, no `island_*` roles, empty
migration history, `auth.users` empty. No export was required and no existing data was touched.

| Check | Result |
| --- | --- |
| Tables / RLS / owner | 8 tables, 8 with RLS enabled, all owned by `island_owner`, 8 `runtime_access` policies |
| Compatibility row | `version/protocol/rules` = `1 / 1 / base-2020-v1`, matching `Database.ready()` |
| Runtime role flags | `island_runtime`: not superuser, no CREATEDB, no CREATEROLE, no BYPASSRLS |
| Runtime DELETE | **None on any table** — move logs and receipts stay append-only |
| Runtime column UPDATE | `outbox_events(attempts, published_at)` and `runtime_control(active_epoch, claimed_at)` only |
| Client roles | `anon`, `authenticated`, `service_role`: no `app` schema USAGE and no table privileges |
| Data API exposure | Live REST probe returns `PGRST106 — Only the following schemas are exposed: public, graphql_public`; `app` is not reachable |
| Auth signing | JWKS serves one **ES256** key, so production asymmetric verification is available |
| Security advisors | None reported |

Credential handling: the `island_runtime` password was generated locally into ignored
`.local/operator.env` (mode 600). A SCRAM-SHA-256 verifier was computed locally so the plaintext
never transits the MCP channel or reaches Supabase query logs.

### Resolved after the first pass

1. **Anonymous sign-ins enabled.** A live signup now returns a token whose header and claims satisfy
   every check in `apps/server/src/auth.ts`: `alg=ES256`, issuer
   `https://dybismsqbzubwzzfrnfo.supabase.co/auth/v1`, `aud=authenticated`, `role=authenticated`,
   UUID `sub`, `is_anonymous=true`, and all required claims present. The setting took roughly a
   minute to propagate.
2. **`island_runtime` now has LOGIN**, applied as a SCRAM verifier. It holds no elevated flags and,
   importantly, **no membership in `island_owner`**, which readiness requires.
3. **Region and pooler resolved by probe:** `aws-0-eu-central-1.pooler.supabase.com:5432`
   (Frankfurt, matching `render.yaml`'s region) with username `island_runtime.<project_ref>`.
   Connecting as the runtime role returned the expected readiness row, and `DELETE` on
   `app.move_logs` plus `UPDATE` on `app.command_receipts` were both denied with `42501` — the
   append-only guarantee holds against the real hosted database, not only locally.

### Resolved: the pooler's TLS chain is privately rooted

`apps/server/src/database.ts` uses `ssl: { rejectUnauthorized: true }` when `DATABASE_TLS=true`, with
no CA supplied. The session pooler presents:

```
*.pooler.supabase.com  <-  Supabase Intermediate 2021 CA  <-  Supabase Root 2021 CA (self-signed)
```

That root is not in any public trust store, so Node fails with `SELF_SIGNED_CERT_IN_CHAIN` **before
authentication**. Verified directly: every European pooler endpoint refused a verified-TLS
connection, and the same connection succeeded once verification was relaxed for a one-off diagnostic.

**The API therefore cannot reach the database on Render until the Supabase root CA is trusted.** The
public `https://supabase.com/downloads/prod-ca-2021.crt` path now returns 404; download it from
Database Settings → SSL Configuration. Two workable options, both preserving verification:

- Add it as a Render **Secret File** and set `NODE_EXTRA_CA_CERTS` to that path. No image change, but
  the file must be configured per service.
- Commit the root certificate (it is a public root, not a secret), `COPY` it in `apps/server/Dockerfile`
  and set `NODE_EXTRA_CA_CERTS`. Reproducible and testable in the container smoke.

**Resolved by baking the root into the image.** `apps/server/supabase-root-2021.crt` is committed (a
public root certificate, not a secret) and the runtime stage sets
`NODE_EXTRA_CA_CERTS=/app/apps/server/supabase-root-2021.crt`. That *appends* to Node's default store,
so JWKS over public CAs keeps working, and certificate verification is never disabled.

Verified with the real deployment artifact, not just the mechanism: the built image was run against
the hosted project with `NODE_ENV=production` and `DATABASE_TLS=true`, and returned
`/health/ready -> 200 {"status":"ready"}` plus a correct `/api/v1/version`. That exercises verified
TLS, the restricted runtime role and the boot-time schema/rules compatibility check together.

**Trust caveat:** the public `prod-ca-2021.crt` download now 404s, so the certificate was extracted
from the live pooler chain. Before trusting it for real play, download the CA from Database Settings →
SSL Configuration and confirm it matches:

```
subject : CN = Supabase Root 2021 CA, O = Supabase Inc
expires : 2031-04-26
SHA-256 : 80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA
```

`scripts/hosted-maintenance.mjs` also pins `rejectUnauthorized: true`, so operator retention run from a
laptop needs `NODE_EXTRA_CA_CERTS` pointed at the same file.

Render remains entirely unconfigured, so `npm run hosted:preflight` cannot run yet.

## Hosted deployment — 2026-09-13 (Claude)

Both free Render services in workspace `Catan` (Frankfurt) are live from commit `72d76f4`.

| Service | URL |
| --- | --- |
| `island-table-api` (Docker web service, free) | https://island-table-api.onrender.com |
| `island-table-web` (static site) | https://island-table-web.onrender.com |

The first Blueprint sync deployed `35eb05c` and failed. Cause: the sync deploy started two seconds
after the services were created, before any `sync: false` variable existed, so `loadConfig()` rejected
the environment and exited 1. The deliberately vague `API startup failed` message is `main.ts`
refusing to leak configuration detail; the build itself had succeeded. The pooler CA problem would
have been the next failure behind it. Both are fixed.

`npm run hosted:preflight` against the real URLs:

```json
{ "readiness": true, "unauthenticatedConnectionDenied": true,
  "versionRequestMs": { "median": 77, "p95": 107 } }
```

Additional live checks beyond the preflight:

| Probe | Result |
| --- | --- |
| `/health/ready` | `{"status":"ready"}` — verified TLS to the pooler with the trusted CA |
| `/api/v1/version` | `protocolVersion 1`, `rulesVersion base-2020-v1` |
| Socket.IO, valid anonymous token | `server.hello protocolVersion=1` — hosted JWKS fetch and ES256 verification work |
| Socket.IO, invalid token | rejected `UNAUTHENTICATED` |
| Socket.IO, `protocolVersion: 99` | rejected `PROTOCOL_UNSUPPORTED` |
| Static entry point | HTTP 200 with `cache-control: no-cache` |

Still unverified, and none of it is implied by the above: `TRUSTED_PROXY_HOPS` is still the
unmeasured default of 0; graceful shutdown and process replacement have not been exercised on Render;
no game has been played hosted; no native build is installed; and no backup/restore rehearsal has
run. Free-instance idle suspension means the first request on game night takes roughly a minute.

## Blocked or unverified gates

| Gate | Missing evidence/input |
| --- | --- |
| P7.1 Free accounts/regions | Supabase project and Render workspace selection/access. Current limits were researched, but account billing/allowances were not inspected. |
| P7.2 Hosted migration/permissions | **Done** — migration applied to a confirmed-empty project, permission matrix verified, runtime LOGIN granted, anonymous sign-ins enabled, verified-TLS connection proven from the deployed API. |
| P7.3 API deploy | **Partial** — image deployed and live, restricted runtime connection and HTTPS JWKS verification both confirmed. Open: measured ingress hop count (`TRUSTED_PROXY_HOPS` still 0) and graceful shutdown/process replacement on Render. |
| P7.4 Static deploy | **Done** — built with pinned Flutter from real public configuration and published at https://island-table-web.onrender.com with `no-cache` on the entry point. |
| P7.5 Native installation | Real configuration, physical Android installation, Apple development team/provisioning and physical iPhone installation. |
| P7.6–P7.7 Device games | Hosted mixed-client privacy/recovery scenario, full timed and untimed games with three/four seats across networks. |
| P7.8 Performance | Warm command/convergence latency, reconnect and timer lag; two-hour four-client resource/DB growth measurements. |
| P7.9 Operations | Hosted retention invocation and backup/restore rehearsal into an isolated test database. The runbook/tooling is prepared. |
| P7.10 Final evidence | Service links, actual physical-device versions, acceptance logs and account quota settings. |

Access checks: a Supabase MCP server is now configured and was used for provisioning (see above). The Supabase CLI still reports **“Access token not provided”**; no Render API credential/connector is configured. The in-app browser connection fails before accessing a dashboard (`sandboxPolicy` metadata error). No authenticated browser profile was read through an alternative path. The account-selection question remains unanswered.

Next step: identify the intended Free Supabase project and Render workspace, authenticate through their supported login/connector flows, and carry out the runbook. Do not send database passwords, signing keys or access tokens in chat. Phase 7 stays open until the actual hosted/device gates pass.
