# Android APK builds

The [Android APK workflow](https://github.com/mgialousis/Catan/actions/workflows/android-apk.yml)
produces a signed release APK for the hosted game. It runs on changes to app/protocol/build files
on `main`, or manually with **Run workflow**. It does not deploy Render services.

Latest verified client: [build 10](https://github.com/mgialousis/Catan/actions/runs/34893289994),
commit `7833c74`, signed release APK, successful. See [current status](status.md) for
API-only fixes that do not require reinstalling the app. The early build verification
below is a historical checksum record, not the latest download.

## Download and install

1. Open a successful workflow run and download `island-table-android-<run number>` from **Artifacts**.
   GitHub requires sign-in to download workflow artifacts.
2. Extract the ZIP. It contains `island-table.apk` and `SHA256SUMS`.
3. Open the APK on Android and allow installation from the browser/file manager when Android asks.
   To install through a connected computer, use `adb install -r island-table.apk`.

Artifacts are retained for 30 days; run the workflow again if a download expires. The same release
signing key is used for every build, and version codes increase with the workflow run number
(`1000 + run number`), allowing updates while retaining the guest identity. Avoid uninstalling or
clearing app data if you want to keep a seat in an existing game. Physical-device acceptance is
still a separate Phase 7 check.

## Configuration

The workflow uses pinned Flutter 3.38.8, Node 22.20.0, Java 17 and the committed dependency locks.
GitHub actions are pinned to commit hashes. Analysis, Flutter tests, signing-configuration tests
and APK signature verification must pass before an artifact is uploaded.
The APK command keeps Flutter's pub/tooling refresh enabled so release plugin registration
excludes `integration_test` after running tests. A final check rejects any dependency lockfile change.

Verified build: [run 34841315094](https://github.com/mgialousis/Catan/actions/runs/34841315094)
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
token has read-only repository contents access. Public repository visibility does not reveal
GitHub secret values.
