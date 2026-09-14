# Free deployment and game-night operations

**The deployment is live.** Follow the acceptance checklist in PLAN.md before treating it as finished;
real-device and separate-network acceptance is still open. Local artifacts built with
`*.example.invalid` URLs verify packaging only and must be rebuilt with real public configuration.

## What is currently deployed

| Piece | Value |
| --- | --- |
| Web client | https://island-table-web.onrender.com |
| API | https://island-table-api.onrender.com |
| Render workspace / region | `Catan`, Frankfurt, both services on Free |
| Supabase project | `dybismsqbzubwzzfrnfo`, eu-central-1 |
| Database connection | Session pooler `aws-0-eu-central-1.pooler.supabase.com:5432`, user `island_runtime.<project_ref>` |
| Auth | Anonymous sign-ins enabled; JWKS serves one ES256 key |
| Auto-deploy | **Off** on both services, so a push never interrupts a game |

Operator values live in ignored `.local/operator.env` (mode 600). Nothing secret belongs in this runbook
or in Git. To redeploy after a push, trigger each service explicitly, or change an environment
variable — Render redeploys automatically when env vars change.

Two operational notes learned from the first deployment. A Blueprint sync deploys immediately on
creation, before `sync: false` variables can be filled, so the first API deploy will fail with
`API startup failed` until the variables exist — that message is deliberately vague and does not
indicate a build problem. And the session pooler chains to a private `Supabase Root 2021 CA`, so
verified TLS needs that certificate. `apps/server/supabase-roots.crt` bundles **both** published
Supabase roots — the 2021 root the pooler serves today and the 2025 key rollover — and the current source runtime
image trusts them through `NODE_EXTRA_CA_CERTS`, so a root migration will not take the API offline.
Both were checked byte-for-byte against the official `supabase/cli` repository. Operator scripts run
from a laptop need the same variable pointed at the same file.

On 2026-09-14 both services were explicitly deployed from `85326a0`, including the two-root
certificate bundle and reviewed invitation/resource UI fixes. Hosted preflight passed. With the
user's approval, deployment preserved the saved three-player game at turn 21: it remained paused,
public/private/server-state hashes matched, and one `RECOVER_GAME` log was appended.

Migration history was reconciled the same day through an atomic MCP metadata update:
`20260913200406 / 20260909000100_foundation` became `20260909000100 / foundation`.
The recorded SQL matches the checked-in migration byte-for-byte after trimming outer whitespace;
local/hosted tables, columns, indexes, constraints, functions and RLS policies also matched. The
original SQL was preserved, and no application schema or game data was changed by the repair.
A private before-record/schema copy is in ignored `.local/migration-audit/`.

MCP authentication is available; Supabase CLI authentication is still separate and currently
missing. Before a future CLI database deployment, authenticate the CLI and review
`supabase db push --dry-run --skip-vault`; no hosted CLI dry run is claimed here. Do not reapply
the foundation. See [Supabase migration troubleshooting](https://supabase.com/docs/guides/deployment/database-migrations#diagnosing-and-fixing-sync-errors).

## Accounts and costs

Use one Render **Free** Docker web service, one free static site, and one Supabase **Free** project. Prefer Frankfurt for both if it is available in the chosen accounts. Do not create Render Postgres, Redis/Key Value, a paid disk, cron job, extra instance or custom domain. `render.yaml` disables automatic deployment, so pushes do not interrupt games.

Rechecked on 2026-09-13: Render documents 750 free instance hours per workspace/month, idle suspension after 15 minutes, and metered bandwidth/build allowances. Its Hobby build pipeline includes 500 minutes. A payment method can permit supplementary charges; use a workspace without one for a strict zero-spend start, and inspect its actual included usage before deployment. Exhausted allowances can suspend service/builds. See [Render Free](https://render.com/docs/free) and [build pipeline](https://render.com/docs/build-pipeline). Supabase Free includes a 500 MB database; inactive projects can pause, and manual exports are needed for backups. See [Supabase pricing](https://supabase.com/pricing) and [backup guidance](https://supabase.com/docs/guides/platform/backups).

## Provision storage first

1. Select/create the intended Supabase Free project; enable anonymous sign-ins and an asymmetric JWT signing key. Record the project URL, public anon/publishable key, issuer (`https://PROJECT.supabase.co/auth/v1`) and its JWKS URL. Verify Auth rate limits during acceptance and keep invitations within the small private group.
2. Download the database CA if required and configure verified TLS. For the long-lived API, use the IPv4 session pooler on port 5432 when direct IPv6 is unavailable. Use `island_runtime.PROJECT_REF` as the pooler username for the restricted custom role. Confirm this against the project's Connect panel; do not use the privileged postgres account in Render. [Supabase connection guidance](https://supabase.com/docs/guides/database/connecting-to-postgres)
3. Before modifying an existing project, export its data and inspect its migration history. The checked-in migration is intended for a fresh project; do not run it over another application's `app` schema. Use the Supabase CLI from the operator's machine, link to the selected project, review `supabase db push --dry-run`, then apply only the reviewed migration.
4. Configure a generated password and LOGIN for `island_runtime` using the operator connection. Keep credentials in provider secrets or an ignored `.local/operator.env`, never in SQL committed to Git. The migration intentionally contains no login password. Verify the runtime has only the documented privileges, cannot DELETE state/logs, and that `anon`/`authenticated` cannot access `app`. Do not expose `app` through the Data API.

Applied on 2026-09-13 for project `dybismsqbzubwzzfrnfo`: the migration and the full permission matrix are verified, `app` is confirmed unexposed through the Data API, and JWKS serves an ES256 key. Anonymous sign-ins and the `island_runtime` LOGIN are now done, and the runtime credential was verified against `aws-0-eu-central-1.pooler.supabase.com:5432`. The pooler's private roots are bundled at `apps/server/supabase-roots.crt` and trusted through `NODE_EXTRA_CA_CERTS` in the runtime image; the built image reaches the hosted database over verified TLS and reports ready. Both bundled certificates were independently matched against the official Supabase CLI repository. Set `NODE_EXTRA_CA_CERTS` to the absolute path of `apps/server/supabase-roots.crt` when running operator retention from a laptop. See [Phase 7 evidence](phase-7-verification.md).

## Render services

Connect this GitHub repository and use the repository root as Docker/build context. The Blueprint contains only the two intended services. Review the workspace plan before applying it.

| API configuration | Value |
| --- | --- |
| Dockerfile | `apps/server/Dockerfile` |
| Instance | Free, exactly one; Frankfurt when available |
| Health check | `/health/ready` |
| `NODE_ENV` / `DATABASE_TLS` | `production` / `true` |
| `DATABASE_URL` | Restricted runtime role, verified-TLS session-pooler URL |
| `SUPABASE_JWT_ISSUER` | The selected project's Auth issuer |
| `SUPABASE_JWKS_URL` | The issuer plus `/.well-known/jwks.json` |
| `WEB_ORIGINS` | Exact HTTPS static-site origin; no wildcard |
| `TRUSTED_PROXY_HOPS` | Start at 0; measure actual ingress before changing |

Do not set `LOCAL_JWT_SECRET` in production. If the provider requires an extra CA, mount its certificate and set `NODE_EXTRA_CA_CERTS`; never disable certificate verification. Port binding uses Render's `PORT`. Start the API only after migration/role verification. Confirm both readiness and authenticated Socket.IO, then test process replacement during a synthetic game. The new process must recover the same game paused and fence the old writer.

Proxy acceptance is still mandatory: from two controlled clients send differing/forged forwarding headers, inspect only sanitized address information, and establish which trusted proxies append which addresses. Set the measured hop count and repeat forged-header/rate-limit checks. Do not assume one hop from a diagram. Default 0 resists spoofing but may combine clients behind the ingress address for rate limits.

The static site's build command is `bash scripts/build-web.sh`; publish `apps/mobile/build/web`. Supply `API_URL`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `WEB_URL` (the static site origin). On Render the build helper also accepts the built-in `RENDER_EXTERNAL_URL` as the Web URL. Only public anon/publishable keys are accepted by the build validator. The helper downloads Flutter **3.38.8** from the official archive, verifies its pinned SHA-256 and Git revision, enforces the Dart lockfile, and disables generated offline service-worker behavior. Entry/app assets revalidate through `Cache-Control: no-cache`.

Invitations use a root query parameter (`?invite=...`), so no path rewrite is required. Web hosts share their current Web origin; native hosts/rematches share the configured `WEB_URL`. With no Web URL, native local development retains the custom app-link fallback.

## Reproduce packaging locally

```sh
npm test
npm run test:local
# Stop local games before the container smoke; it claims runtime ownership.
docker build --platform linux/amd64 -f apps/server/Dockerfile -t island-table-api:phase7 .
npm run test:container
docker build --platform linux/amd64 -f scripts/Dockerfile.web --output type=local,dest=.local/linux-web .
```

The last command deliberately uses placeholder public configuration. Supply all four public values as `--build-arg` options to make a usable hosted artifact. The SDK archive is large; keep the Docker build cache. No hosted resource is created by these commands.

## Native distribution

`node scripts/create-android-key.mjs` creates a dedicated signing key once. It refuses to replace existing material. Securely back up **`.local/signing/` and `apps/mobile/android/key.properties`** before distributing an APK; Android updates require the same signing identity. They are ignored by Git. The key password and private key must not be sent in chat or committed.

Copy `apps/mobile/config/release.example.json` to ignored `config/release.json` and replace every placeholder with the real public URLs/key. Then, from `apps/mobile`:

```sh
flutter build apk --release --dart-define-from-file=config/release.json
```

Output: `build/app/outputs/flutter-apk/app-release.apk`. Verify with Android SDK `apksigner verify --print-certs`, install on a physical Android phone, and check invitations, Wi-Fi/mobile transitions and background recovery. Release builds refuse missing signing configuration; there is no debug-key fallback.

For iPhone development, open `apps/mobile/ios/Runner.xcworkspace` in Xcode, select the owner's existing Personal Team/development team and connected iPhone, and configure the real public values. Personal provisioning is time-limited. Do not purchase membership for this phase; friends can use the Web URL in Safari. Unsigned builds and simulator builds do not satisfy the physical-device gate. [Apple account options](https://developer.apple.com/help/account/basics/about-your-developer-account)

## Hosted checks and measurements

Store public environment values in ignored `.local/hosted-public.env`, then run:

```sh
node --env-file=.local/hosted-public.env scripts/hosted-preflight.mjs
```

This finite probe checks readiness, version compatibility, static caching and explicit rejection of a forged token. It creates no room or guest and reports HTTP timing only. It does **not** prove JWKS success, authorized private delivery, ingress trust or gameplay latency.

Complete PLAN §4 with four authenticated clients: mixed native/Web, three/four seats, full untimed and timed games, lost acknowledgements, simultaneous discard/trade races, pre-roll Knight, Road Building expiry, host loss, backend restart and hidden victory points. Record real device/OS/browser/build IDs. Measure p50/p95 command acknowledgement and displayed convergence, warm reconnect, timer lag, snapshot bytes, DB growth, and two-hour CPU/memory/network usage. Targets remain p95 <1 second while warm and correct reconnect within 10 seconds; actual results are pending.

## Backup, restore, rollback and maintenance

Before migration/deployment, pause the table and create a verified-TLS export from the operator's machine. Use a protected PostgreSQL service/pgpass configuration (`chmod 600`) instead of passwords in shell command arguments. For example, `PGSERVICE=island_operator pg_dump --format=custom --no-owner --no-acl --schema=app --file=.local/backups/app.dump` exports the application schema/data. Create the backup directory with private permissions first and use a restrictive umask.

That application dump does **not** back up Auth identities or global database roles. Preserve them separately using Supabase's documented backup procedure. Restoring seat rows without the original `auth.users` mappings will fail or leave guests unable to resume. Rehearse restoration into a separate Supabase-compatible test database, install the expected roles, and verify hands, board, log/version alignment and receipts before touching a live game. This rehearsal and an actual hosted backup remain open acceptance items.

Roll back only to an artifact compatible with the persisted schema/rules/protocol. Keep the last known-good commit/image and export. Pause first; roll back artifacts before considering data restoration. Never reset the DB or restore an older dump over newer moves automatically.

Hosted retention runs from the operator's computer; Free Render shell/cron is not required:

```sh
# OPERATOR_DATABASE_URL belongs only in the ignored operator env file.
node --env-file=.local/operator.env scripts/hosted-maintenance.mjs
# After reviewing the dry-run counts, set OPERATOR_CONFIRM_HOST to that exact host:
node --env-file=.local/operator.env scripts/hosted-maintenance.mjs --apply
```

The operator must have `island_owner` membership. TLS verification is mandatory. Dry run is the default. Apply purges only terminal rooms older than 30 days, retains command-ID tombstones, takes the exclusive runtime lock and records counts before/after. It never targets an active game. The local retention path remains `npm run local:retention`. Hosted execution is not yet verified.

Before game night: check account quotas/status, resume Supabase if paused, visit the API normally to wake it, check readiness, close synthetic rooms, then create the real invitation. Reconnect with the same guest credentials. Lost credentials cannot reclaim a seat by nickname; the host can abandon and start again. If a provider/quota is unavailable, keep the saved game and wait for recovery; do not upgrade automatically or run a keep-awake service.
