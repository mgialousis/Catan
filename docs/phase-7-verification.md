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

## Blocked or unverified gates

| Gate | Missing evidence/input |
| --- | --- |
| P7.1 Free accounts/regions | Supabase project and Render workspace selection/access. Current limits were researched, but account billing/allowances were not inspected. |
| P7.2 Hosted migration/permissions | Operator access, reviewed export of existing hosted data, applied migration and hosted role/TLS tests. No hosted data was changed. |
| P7.3 API deploy | Render service access, restricted runtime connection, HTTPS JWKS verification and measured ingress hop count. |
| P7.4 Static deploy | Real API/Auth/Web public configuration and published Render URL. Linux packaging is verified. |
| P7.5 Native installation | Real configuration, physical Android installation, Apple development team/provisioning and physical iPhone installation. |
| P7.6–P7.7 Device games | Hosted mixed-client privacy/recovery scenario, full timed and untimed games with three/four seats across networks. |
| P7.8 Performance | Warm command/convergence latency, reconnect and timer lag; two-hour four-client resource/DB growth measurements. |
| P7.9 Operations | Hosted retention invocation and backup/restore rehearsal into an isolated test database. The runbook/tooling is prepared. |
| P7.10 Final evidence | Service links, actual physical-device versions, acceptance logs and account quota settings. |

Access checks: Supabase CLI reports **“Access token not provided”**; no Render API credential/connector is configured. The in-app browser connection fails before accessing a dashboard (`sandboxPolicy` metadata error). No authenticated browser profile was read through an alternative path. The account-selection question remains unanswered.

Next step: identify the intended Free Supabase project and Render workspace, authenticate through their supported login/connector flows, and carry out the runbook. Do not send database passwords, signing keys or access tokens in chat. Phase 7 stays open until the actual hosted/device gates pass.
