#!/usr/bin/env bash
set -euo pipefail
# Future Render build helper. No hosted service is created by this script.
island_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$island_root"
island_flutter_revision=bd7a4a6b5576630823ca344e3e684c53aa1a0f46
island_flutter_dir="$island_root/.local/flutter-3.38.8"
if [ ! -d "$island_flutter_dir/.git" ]; then
  mkdir -p "$island_root/.local"
  git clone --depth 1 --branch 3.38.8 https://github.com/flutter/flutter.git "$island_flutter_dir"
fi
test "$(git -C "$island_flutter_dir" rev-parse HEAD)" = "$island_flutter_revision"
: "${API_URL:?Set the public HTTPS API_URL}"
: "${SUPABASE_URL:?Set the public SUPABASE_URL}"
: "${SUPABASE_ANON_KEY:?Set the public Supabase key}"
node scripts/sync-protocol.mjs
cd apps/mobile
"$island_flutter_dir/bin/flutter" pub get --enforce-lockfile
"$island_flutter_dir/bin/flutter" build web --release \
  --dart-define="API_URL=$API_URL" \
  --dart-define="SUPABASE_URL=$SUPABASE_URL" \
  --dart-define="SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY"
