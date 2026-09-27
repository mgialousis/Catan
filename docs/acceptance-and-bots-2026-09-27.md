# Acceptance follow-up and Hard bots — 2026-09-27

The hosted checks below exercised release `e8744ee` (Android release 29).
The bot changes described afterward are local, tested work, not a deployed release.
No schema migration, paid service, or change to an existing room's difficulty was made.

## Phase 7 evidence

Read-only snapshots from September 24 at 16:12 UTC and September 27 at 17:41 UTC
match for all four saved rooms: public, private, server and clock hashes, room
revisions, game versions, turns, move-log counts and outbox counts. All remain
paused. This covers 73.48 hours and a later API runtime claim; it is evidence
against continued writes while these games are paused, not an active-game restart test.

Hosted preflight passed on September 24: readiness, protocol/rules compatibility,
static cache policy and unauthenticated socket rejection. Warm version probes
measured 53 ms median / 91 ms p95 in the second run. These are HTTP probes, not
player-command timings.

On September 27, an isolated practice room exercised a real authenticated socket
and three server bots through setup and five turns. The client validated snapshots
and contiguous patches against the protocol and checked its owner identity after
a one-second transport loss and reconnect.

| Measurement | Result |
| --- | --- |
| Accepted player commands | 6 |
| Acknowledgement | 175 ms median / 466 ms p95 |
| Send to local receipt/application of updated state | 218 ms median / 519 ms p95 |
| Reconnect to restored owner snapshot | 598 ms |
| JSON snapshot size, uncompressed | 13,045–14,426 bytes |
| Observed protocol errors / version gaps | 0 |

With six commands, p95 is simply the largest observed sample. This is a small
socket-level check, not rendered UI latency, four-seat privacy acceptance,
mobile-network switching, a full match, or a two-hour soak. No opponent hand was
requested. Practice uses no multiplayer slot; the saved multiplayer game was preserved.

The first connection attempt timed out. A later probe reached gameplay but its
cleanup raced a bot move and received `STALE_VERSION`. That synthetic room was
marked abandoned through a guarded operator update restricted to its exact ID,
practice mode, test nickname and single human seat, then given an end timestamp
for retention. The successful probe resynchronizes and retries stale cleanup;
it ended its own room through `ABANDON_GAME`. Neither probe remains active.
Synthetic anonymous Auth users and terminal room records are retained for normal
maintenance; no existing user identity or game was removed. Private evidence and
probe credentials stay under ignored `.local/`.

Render metrics could not be refreshed: its OAuth refresh token was rejected.
Current resource usage, billing and remaining quotas are therefore unverified.

## Still open in Phase 7

- Android physical testing: the user confirmed **Android 13**, Wi-Fi and mobile data.
  Phone model and installed APK build remain unconfirmed. No phone is attached here.
- Real Wi-Fi/mobile handoff, background/resume, scrolling/zooming frame timings,
  and mixed Android/web recipient isolation.
- Complete timed and untimed human matches covering three and four seats on
  separate networks; a two-hour four-client load/soak test.
- An active-game hosted restart/fencing rehearsal, measured ingress/proxy behavior,
  and current Render memory/bandwidth/plan/quota evidence.
- iOS build/provisioning/device acceptance (no iPhone available), full Auth recovery,
  and privileged hosted retention verification.

A one-human practice probe can proceed while multiplayer is occupied. The full
four-human hosted scenario needs the multiplayer slot free; multiple connections
for the same practice owner do not substitute for four different seats.

Phone check to run with the installed build recorded: in a practice game, note
turn and resources, switch Wi-Fi off, wait for reconnection over mobile data,
then return to Wi-Fi. Confirm the same seat and current hand return, no action is
duplicated, and the next legal action succeeds. Repeat after backgrounding the
app for 30 seconds; record elapsed reconnect time and any visible error. A long
disconnection may legitimately pause the game and require resume.

## Bot behavior

`HARD` is selectable for new practice games and accepted by the shared protocol
and server runner. The three choices wrap on small screens and include a short
explanation. Existing rooms retain their saved setting; missing/unknown internal
settings still default to Medium. Unknown wire settings remain rejected.

Hard has distinct bounded planning:

- Scores settlements against existing production, rewarding missing resources and useful ports.
- Searches routes of up to three new roads, respecting other players' buildings
  and roads. Prioritizes settlement expansion and achievable Longest Road awards.
- Plans bank conversions up to two trades ahead, using owned port rates and
  availability. Saves resources toward settlements and cities.
- Examines all 15 possible Year of Plenty bundles, preserves a useful build when
  discarding, and moves a robber off its own production before rolling with a Knight.
- Prioritizes immediate point/army/road wins, evaluates trade usefulness, and avoids
  trading with an opponent already showing nine points.
- Estimates Monopoly choices from public production and public card counts.
  It never inspects opponents' actual cards or development-deck identities.

The policy is deterministic for the same view, hints and seed. Bank stock hints
are used for legal card availability, not to deduce opponents' hands. It is a
heuristic planner, not an exhaustive game-tree search or a guarantee of optimal play.
Bots still respond to offers; they do not originate player trade negotiations.
All standard development-card timing restrictions remain enforced by move generation.

Medium now uses actual 2:1/3:1/4:1 rates when evaluating bank trades and declines
offers that exchange more cards than it receives.

## Verification

- Full Flutter suite: **380 passed**; static analysis clean.
- Engine/server/protocol suite: **277 passed**.
- Local database suite: **76 passed**, with all six application table counts
  unchanged afterward. Covers both Medium and Hard through real autonomous bot
  jobs, persistence, receipts and presentation pacing. The first run exposed an
  older timer-fixture bug: a coastal settlement could supply no new robber hex.
  The fixture now searches both victim settlements and asserts a valid destination.
- Tactical regressions cover ports, unfavorable trades, two-step bank conversion,
  a two-road settlement route, Year of Plenty, discards, pre-roll Knights, input
  immutability and independence from opponent card composition.
- Full Hard-only games finish on seeds 7, 23 and 42; seeded replay is deterministic.

Run `npm run build` then `node scripts/benchmark-bots.mjs` to repeat the strength
sample: six fixed boards (7, 11, 23, 42, 99, 137), each with the Hard bot in all four
seat positions against three Medium bots. All **24 games completed**, Hard won
**14/24**. Across 2,215 Hard decisions, local median was **0.068 ms**, p95 **0.194 ms**,
and maximum **2.20 ms**. Machine/load-dependent CPU timings are not hosted latency;
this small deterministic sample is not a general win-rate guarantee.

Deployment order when releasing: API first so it accepts `HARD`, then web and a
new signed APK. Older clients' settings schema does not know `HARD`, so use an
updated client for a Hard room. No migration is required. Android build 29 does
not contain this new selector or policy release.
