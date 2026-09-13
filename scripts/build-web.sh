#!/usr/bin/env bash
set -euo pipefail
island_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$island_root"
node scripts/public-config.mjs
bash scripts/install-flutter-linux.sh
island_flutter="$island_root/.local/flutter-3.38.8/bin/flutter"
node scripts/sync-protocol.mjs
cd apps/mobile
"$island_flutter" pub get --enforce-lockfile
"$island_flutter" build web --release --no-pub --pwa-strategy=none \
  --dart-define="WEB_URL=${WEB_URL:-${RENDER_EXTERNAL_URL}}" \
  --dart-define="API_URL=$API_URL" \
  --dart-define="SUPABASE_URL=$SUPABASE_URL" \
  --dart-define="SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY"
