# Android APK builds

The [Android APK workflow](https://github.com/mgialousis/Catan/actions/workflows/android-apk.yml)
produces a signed release APK for the hosted game. It runs on changes to app/protocol/build files
on `main`, or manually with **Run workflow**. It does not deploy Render services.

Latest successful workflow: [build 28](https://github.com/mgialousis/Catan/actions/runs/35528690226),
commit `8838b52`, confirmed during the 2026-09-21 review. It includes the opening
camera changes, corner seats, resource dock and sequential roll/payout presentation.
The workflow verifies signing; physical Android smoothness remains a separate check.

The 2026-09-21 review fixes prepared for release are **not included in build 28**.
They require a new APK plus API and web deployment. Render's current revisions
were not reverified because connector authorization expired; Android workflow
success does not imply either Render service was deployed.

## Download and install

1. Download [the latest APK](https://github.com/mgialousis/Catan/releases/download/android-latest/island-table.apk).
   This public release download requires no GitHub account. The adjacent
   [SHA256SUMS](https://github.com/mgialousis/Catan/releases/download/android-latest/SHA256SUMS)
   verifies the download.
2. Open the APK on Android and allow installation from the browser/file manager when Android asks.
3. Install it as an update. Keep the existing app data to preserve your guest identity and game seat.
   To install through a connected computer, use `adb install -r island-table.apk`.

Each successful main-branch build replaces the rolling release download. Individual
workflow artifacts are also available for 30 days but require GitHub sign-in. The same
release signing key is used for every build; version codes increase with the workflow
run number (`1000 + run number`). Build 28 computes version code `1028`; the app label is `Catan`.
Physical-device acceptance is still a separate Phase 7 check.

## Configuration

The workflow uses pinned Flutter 3.38.8, Node 22.20.0, Java 17 and the committed dependency locks.
GitHub actions are pinned to commit hashes. Analysis, Flutter tests, signing-configuration tests
and APK signature verification must pass before an artifact is uploaded.
The APK command keeps Flutter's pub/tooling refresh enabled so release plugin registration
excludes `integration_test` after running tests. A final check rejects any dependency lockfile change.

Historical package inspection: [run 34841315094](https://github.com/mgialousis/Catan/actions/runs/34841315094)
from `d1e3505`, with [APK artifact](https://github.com/mgialousis/Catan/actions/runs/34841315094/artifacts/10346371561).
It produced version `0.1.0` / code `1002`, package `dev.islandtable.island_table`, size
54,229,885 bytes. The downloaded APK's checksum matched, its signature matched the existing
private release key's public certificate, and it was not debuggable. SHA-256:
`108310bffef05fb6ee623447cbc78c2cb36b923af7dea1247a8339ae73ee771c`.

Repository **variables**, containing public app configuration:

- `API_URL`
- `WEB_URL`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY` (anon/publishable key only)

Repository **secrets**, configured from the existing private release key:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_STORE_PASSWORD`
- `ANDROID_KEY_PASSWORD`
- `ANDROID_KEY_ALIAS`

The signing step creates temporary files with mode 600 after the tests pass. The final cleanup
step removes the keystore and generated configuration even if a later step fails. Only the APK
and its checksum are uploaded. Keep the original `.local/signing` backup private and preserve
the key for app updates. Never add signing material or database/operator credentials to Git.

Signing runs only for this repository's `main` branch, not pull requests or forks. The workflow
token has repository contents write access to publish the rolling APK release. Public repository visibility does not reveal
GitHub secret values.
