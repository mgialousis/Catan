#!/usr/bin/env bash
set -euo pipefail
island_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
island_sdk="$island_root/.local/flutter-3.38.8"
island_sha=68f702b9ea9b63259924bf6cb2330e0f6e076898958709dd28571f27bcf12fba
island_revision=bd7a4a6b5576630823ca344e3e684c53aa1a0f46
# Official Flutter release manifest: flutter_infra_release/releases/releases_linux.json.
test "$(uname -s)" = Linux
test "$(uname -m)" = x86_64
if [ ! -d "$island_sdk/.git" ]; then
  mkdir -p "$island_root/.local"
  island_archive="$island_root/.local/flutter-3.38.8-linux.tar.xz"
  curl --fail --location --retry 3 https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.38.8-stable.tar.xz -o "$island_archive"
  printf '%s  %s\n' "$island_sha" "$island_archive" | sha256sum --check --status
  mkdir -p "$island_sdk"
  tar -xJf "$island_archive" -C "$island_sdk" --strip-components=1
fi
test "$(git -C "$island_sdk" rev-parse HEAD)" = "$island_revision"
"$island_sdk/bin/flutter" config --no-analytics
