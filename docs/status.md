# Current project status

Updated 2026-09-20 (Europe/Zurich), after the roll-feedback release. Use this file for handoff; dated verification documents retain
historical evidence and are not a statement of the current release.

## Roll feedback release — 2026-09-20

Release `812d023` adds compact player summaries above the island, a persistent
illustrated resource bar, and a roll presentation: centered dice and total,
gentle camera focus on the producing tiles, then individual resource icons flying
to their recipients. Touch cancels the presentation; reduced motion shows a static
dice result; reconnects do not replay old rolls. A bounded queue handles fast bot
turns without delaying gameplay. The existing detailed roster remains below the
board for inspecting player statistics.

Payout animation uses new public `RESOURCES_COLLECTED` activity entries from the
engine, including the actual amounts after bank shortages and robber blocking.
No database migration was needed. Against an older API, dice and camera feedback
work but payout flights have no events to display.

Follow-up `2326130` centres the dice on the map viewport rather than at a fixed
offset, so they no longer drift with larger text; restores `=` in the total;
holds the dice a second longer; and delivers payouts strictly one at a time.
It is client-only, so the API still runs `812d023` and was not restarted — the
engine effect the animations consume already shipped there. Live now: web and
signed Android **build 18** on `2326130`, API on `812d023`. Verify with
`git diff --name-only <deployed>..HEAD -- apps/server packages/ supabase/`
before assuming the API needs a deploy; here it did not, and a practice game
was played straight through the web deployment without interruption.

Validation: 254 Node tests and 342 Flutter tests pass; Flutter analysis and
`git diff --check` pass. Rendered portrait frames were inspected. Regression tests
cover retained board artwork during the animation, touch cancellation, reduced
motion, queued bot rolls, reconnect gaps, and payouts. Hosted preflight passed after deployment. Both previously paused games retained
their exact state hashes, turns, versions and log counts. Physical Android animation
smoothness remains to be checked. See [release verification](release-2026-09-20.md).

## Release and data

- Repository: https://github.com/mgialousis/Catan, **public** since 2026-09-19.
  History was audited for credentials first; only `.env.example` placeholders and
  deliberately fake test fixtures matched. Phases 1–6 are implemented and a solo
  practice mode against bots ships on top of them; Phase 7 acceptance remains partial.
- Web: `812d023`,
  [live](https://dashboard.render.com/static/srv-dajgfdnqj5pc73dhl33g).
- API: `812d023`,
  [live](https://dashboard.render.com/web/srv-dajgfdnqj5pc73dhl330).
- Android: signed build published to a rolling release. Downloads **without a
  GitHub account**, unlike a build artifact, which requires one whatever the
  repository's visibility:
  https://github.com/mgialousis/Catan/releases/download/android-latest/island-table.apk
  Build 17 (`812d023`, version code `1017`) verified anonymously at 55,226,920 bytes
  against the adjacent `SHA256SUMS`, with the existing release signing certificate. Each build of
  `main` replaces both files; the URL does not change.
- Both Render services are Frankfurt, Free plan, one instance, automatic deploys
  disabled. No paid resource is enabled.
- Schema is at migration **3**. `2` added bot seats and practice rooms; `3` widened
  the seat palette. `Database.ready()` accepts `[2, 3]`, so a build must be deployed
  **before** its migration is applied; pinning a single version crash-loops the API
  in either order.

## Practice mode against bots

Solo practice ships end to end and is in real use on the hosted stack.

- The rules engine gained `legalCommands()`, written against a `PlayerView` of
  public state plus one seat's own hand. A bot is not trusted to behave; it is
  structurally unable to see another hand, the bank or the deck. Three facts a seat
  legitimately knows but `PublicState` omits arrive as explicit hints: remaining
  development cards, the pending setup vertex, and per-resource bank stock.
- Difficulty is `EASY` (uniform among legal moves) or `MEDIUM` (scored). `HARD` is
  deliberately absent until it plays differently from `MEDIUM`.
- The runner takes the same path a person's command takes — fence, per-command
  advisory lock, receipt, room row, game row. A job id carries room, phase and
  version, so a retry after a crash replays the recorded move rather than inventing
  a second one. Moves are paced about a second apart.
- A practice room holds no `active_slot`, so it never competes with the single live
  multiplayer game.
- Hosted evidence: 6 practice rooms, **3 played to completion**, 18 automated seats
  and **708 bot moves**. This is the first Phase 7 gameplay evidence produced without
  assembling human players.

## Leaving a live game

Any seated player can leave; it is no longer the host's alone, and no longer only
"end it for everyone". A vacated seat becomes `VACANT` and pauses the table under
`SEAT_VACANT` — distinct from `DISCONNECTED`, which resolves itself when somebody
reconnects while a vacancy never will. Resuming is refused while a seat is empty.
The seat keeps its cards and turn position, so `REPLACE_WITH_BOT` continues that
position; its row is reinstated with no identity so nobody can rejoin into the
bot's cards. Any remaining player may fill it, the host role transfers if the host
left, and the last person out closes the table. Used in production: 3 seat commands
recorded.

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

Outcome after deployment: **4** presence-pause records since the fix went live on
September 18, against 630 before it, the most recent at 15:43 UTC on September 19
and attributable to practice games starting and stopping rather than to a loop.
The write loop is stopped. No historical cleanup was performed.

Validation at the time: 230 Node tests and 60 local database/auth/gameplay checks passed;
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
| P7.5 Native | Signed Android APK published to a release that downloads without an account, verified anonymously against its checksum. Exact device/build acceptance, iOS provisioning and physical iPhone install remain open. |
| P7.6–P7.7 Matches | Three hosted practice games ran to completion with 708 automated moves, exercising the rules end to end without needing to assemble players. That is not the gate: mixed native/web privacy and reconnect cases, and complete timed and untimed **human** matches on separate networks, remain open. |
| P7.8 Performance | Regression tests and fewer rendering operations verified; restored hosted recipient snapshots measure 13,715–13,804 bytes uncompressed. Board rendering fell from roughly 300 blur operations per paint to 2 in the terrain layer, and the user confirms scrolling and zooming feel smoother; **no frame time has been measured**, because `flutter test` rasterises in software and its own cost swamps the paint, so only operation counts are evidence. Physical Android frame timings, command/convergence/reconnect timings and a two-hour four-client soak remain open — a bot-only game is now the obvious soak driver. |
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

A practice game now needs neither the live room slot nor other people, so the
soak and latency work under P7.8 no longer waits on anybody's availability.

Next: complete the available non-disruptive acceptance checks. Hosted synthetic
games/soaks need the one active room slot to be free; physical-device checks need
the players/devices. The API fix takes effect with the existing APK; no reinstall
is necessary for pause-write behavior.
