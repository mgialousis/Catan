# Current project status

Updated 2026-09-19 (Europe/Zurich). Use this file for handoff; dated verification
documents retain historical evidence and are not a statement of the current release.

## Release and data

- Public repository: https://github.com/mgialousis/Catan. Phases 1–6 are implemented;
  Phase 7 acceptance remains partial.
- Web: `7833c74`, [live deployment](https://dashboard.render.com/static/srv-dajgfdnqj5pc73dhl33g/deploys/dep-dak5ikrl550s73a07b1g).
- Android: signed [build 10](https://github.com/mgialousis/Catan/actions/runs/34893289994),
  `7833c74`, successful and artifact unexpired when checked. Includes Catan branding,
  resource/dice/trade feedback, attributed activity and the rasterized terrain optimization.
- API: `23bd0db` pause-write fix is **live** on
  [Render](https://dashboard.render.com/web/srv-dajgfdnqj5pc73dhl330/deploys/dep-dams95lg1s2s73b9t5lg);
  post-deployment preflight passed. Prior live API was `4216655`.
- API-only changes do not require an APK or web rebuild. `7833c74` changed only the
  mobile activity model/test, so the preceding API release already contained all
  backend changes until the pause fix.
- Both existing Render services use Frankfurt; API plan is Free, one instance,
  automatic deployments disabled. No new hosted resource or plan upgrade was requested.
- Migration history was reconciled on September 14 to `20260909000100 / foundation`.
  No schema migration is part of the pause fix.
- Current saved game before this deployment: three seats, turn 19, `AWAIT_ROLL`,
  `PAUSED`, version 701, reason `RECOVERY`. Earlier turn-21 evidence is historical.
  Do not abandon, resume, replace or edit the saved game to run acceptance tests.

## Pause-write bug

The hosted history contained 634 `PRESENCE_PAUSE` records. Recent records toggled
`RECOVERY` ↔ `DISCONNECTED, RECOVERY` while the game remained saved and paused.
Each presence change unnecessarily wrote game state, activity, a command receipt
and an outbox event. This was observed data growth, not evidence of a billed charge.

`23bd0db` skips automatic presence reconciliation when `MANUAL`, `RECOVERY` or
`DATABASE_UNAVAILABLE` already requires a host resume. Existing combined reasons
are left intact until explicit resume; there is no historical-data cleanup.
Presence notifications still work, and resume still checks required players under
the room lock. A disconnect-only pause still automatically resumes on reconnection.

Validation: 230 Node tests and 60 local database/auth/gameplay checks passed;
all six application-table counts returned to their starting values. New regressions
exercise repeated socket flaps and idle ticks for each host-resume reason and a
legacy combined reason. Version, updated timestamp, clock state, logs, receipts and
outbox counts stay unchanged. Offline resume is rejected; online resume preserves
discard budgets. No claim is made that legitimate subscriptions do zero SQL reads
or never update their advisory `last_seen_at` timestamp.

## Remaining acceptance

| Gate | Current evidence / remaining work |
| --- | --- |
| P7.1 Accounts | Services/regions verified; billing, payment-method and remaining quota settings still need account evidence. |
| P7.2 Database | Hosted migration/permissions/TLS and history reconciliation complete. |
| P7.3 API | Live API and saved-paused-game replacement evidence exist. Active synthetic restart/fencing and measured ingress remain open; `TRUSTED_PROXY_HOPS=0` must not be guessed. |
| P7.4 Web | Live, real configuration, entry-point cache policy checked. |
| P7.5 Native | Signed Android APK produced; user reports Android use. Exact device/build acceptance, iOS provisioning and physical iPhone install remain open. |
| P7.6–P7.7 Matches | Earlier hosted browser scenario is partial evidence. Mixed native/web privacy/reconnect cases and complete timed/untimed human matches on separate networks remain open. |
| P7.8 Performance | Regression tests and fewer rendering operations verified; restored hosted recipient snapshots measure 13,715–13,804 bytes uncompressed. Physical Android frame timings, command/convergence/reconnect timings and a two-hour four-client soak remain open. |
| P7.9 Operations | Hosted application backup and isolated local restore verified September 19. Full Auth recovery and privileged hosted retention still open; local-copy retention dry run found zero eligible records. |
| P7.10 Handoff | Release links and limitations recorded here; device versions and final acceptance results still needed. |

Finite hosted preflight passed after deployment: readiness, compatible protocol/rules,
web `no-cache`, explicit invalid-token rejection. Ten warm version probes measured
132 ms median / 141 ms maximum (reported as p95); these are not gameplay latency.

Before/after deployment and subsequent observation: version 701, 702 game logs,
710 room-linked receipts and all public/private/server/clock hashes unchanged.
One legitimate host transfer created room revision 158 (was 157) and one ROOM outbox
event, with status unchanged; no game transition occurred. At 23:16:53 UTC, totals
remained stable at 861 room-linked outbox events and 634 presence-pause events.
This is a finite passive observation plus local reconnect regression evidence,
not a two-hour hosted soak or a controlled production reconnect test.

Render MCP login works after reauthentication. Supabase MCP refresh currently fails;
verified-TLS access with the existing restricted runtime credential works. Do not
assume it is a privileged maintenance credential. Do not reapply the foundation.

## September 19 operations evidence

A read-only, verified-TLS `pg_dump` of `app` used PostgreSQL 17.6 and an exported
repeatable-read snapshot. The runtime role's existing SELECT policy was used with
`--enable-row-security`; no hosted permissions or schema changed. The 305,432-byte
custom archive is stored privately at `.local/backups/20260919/app.dump` (mode 600,
directory mode 700, ignored by Git), alongside verification JSON. SHA-256:
`57656097b16027ee11200f0843f23531133fbf905fab4c8db44be9d5bf8db96f`.

Restoration into a separate local database matched the source snapshot across all
eight app tables: 3 rooms, 9 players, 3 game states, 804 logs, 837 receipts,
1,007 outbox events, and one row each for schema/runtime metadata. Foreign keys and
other constraints restored successfully; game/clock invariants and log-tail versions
matched. This deliberately excluded global roles, original ACLs and Auth records:
local `auth.users` subject-ID placeholders satisfied foreign keys. It therefore
verifies application-data recovery, **not** guest sign-in/session recovery or a full
Supabase disaster restore. The protected archive is not a substitute for an Auth backup.
The temporary restored database was removed after verification; the private archive
and evidence were retained.

On that isolated copy, retention dry run selected zero terminal rooms/receipt bodies
and made no changes. Hosted privileged maintenance was not invoked with the runtime
credential. Snapshot-size measurements covered all nine recipient projections in
the three restored games. Render's first two post-deploy memory samples were about
55–59 MiB; that short idle sample is not evidence of four-client load or a soak pass.

## Next acceptance session

User device availability: one Android phone, APK downloaded from GitHub; exact model
and installed build not yet recorded. No iPhone is currently available, and no
Android device is attached to this workstation. iPhone acceptance remains unverified.

Next: complete the available non-disruptive acceptance checks. Hosted synthetic
games/soaks need the one active room slot to be free; physical-device checks need
the players/devices. The API fix takes effect with the existing APK; no reinstall
is necessary for pause-write behavior.
