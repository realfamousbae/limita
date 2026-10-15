#!/bin/bash
# Copies the artwork shared by the macOS and Windows apps from assets/shared/ into the
# places each build reads it from (the asset catalog, the Vite public folder, the Tauri
# crate). Edit assets/shared/, run this, commit both. `--check` only compares and exits
# non-zero when a copy has drifted; CI runs it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARED="$ROOT/assets/shared"
CATALOG="$ROOT/macos/Limita/Resources/Assets.xcassets"
WEB="$ROOT/windows/app/public"

# source (under assets/shared) -> destinations
PAIRS=(
    "prime-time.webp|$ROOT/macos/Limita/Resources/prime-time.webp"
    "prime-time.webp|$WEB/prime-time.webp"
    "status.png|$CATALOG/StatusIcon.imageset/status@3x.png"
    "status.png|$WEB/status.png"
    "status.png|$ROOT/windows/app/src-tauri/assets/status.png"
    "logos/claude.png|$CATALOG/ClaudeLogo.imageset/claude-logo@3x.png"
    "logos/claude.png|$WEB/logos/claude.png"
    "logos/codex.png|$CATALOG/CodexLogo.imageset/codex-logo@3x.png"
    "logos/codex.png|$WEB/logos/codex.png"
)

check=false
[[ "${1:-}" == "--check" ]] && check=true
drift=0
for pair in "${PAIRS[@]}"; do
    src="$SHARED/${pair%%|*}" dst="${pair##*|}"
    if cmp -s "$src" "$dst"; then continue; fi
    if $check; then
        echo "out of sync: ${dst#"$ROOT"/} (from assets/shared/${pair%%|*})"
        drift=1
    else
        cp "$src" "$dst"
        echo "updated ${dst#"$ROOT"/}"
    fi
done
exit $drift
