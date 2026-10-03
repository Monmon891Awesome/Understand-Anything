#!/bin/bash
# Copies the canonical toolkit (this folder) into the bundled skill:
#   skill/mac-wine-dx9-games/scripts/toolkit/   the script, templates, DLLs, probe, patches, build script
#   skill/mac-wine-dx9-games/references/         troubleshooting, Sikarugir setup, the Battle Realms playbook
#
# Usage: tools/sync-skill.sh            copy (run after changing anything listed below)
#        tools/sync-skill.sh --check    exit 1 if the skill copy differs (used by tests)

set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$HERE/skill/mac-wine-dx9-games"
MODE="${1:-sync}"
status=0

# "source|destination-inside-the-skill" pairs
pairs() {
  local f
  for f in brz-mac.sh templates/dxvk.conf templates/dgVoodoo.conf \
           dlls/d9vk-f229921/d3d9.dll dlls/d9vk-f229921-diag/d3d9.dll dlls/SHA256SUMS dlls/README.md \
           bin/brz-probe.exe probe/brz-probe.c probe/build.sh probe/README.md \
           patches/d9vk/0001-mingw11-resourcemanager-compat.patch patches/d9vk/0002-d3d9-diag-logging.patch \
           tools/build-d9vk.sh; do
    printf '%s|scripts/toolkit/%s\n' "$f" "$f"
  done
  for f in "$HERE"/reference-results/*.txt; do
    f="reference-results/$(basename "$f")"
    printf '%s|scripts/toolkit/%s\n' "$f" "$f"
  done
  printf '%s\n' "TROUBLESHOOTING.md|references/troubleshooting.md" \
                "WRAPPER-SETUP.md|references/sikarugir-setup.md" \
                "PLAYBOOK.md|references/playbook-battle-realms.md"
}

while IFS='|' read -r src dst; do
  [ -n "$src" ] || continue
  if [ "$MODE" = "--check" ]; then
    if ! cmp -s "$HERE/$src" "$SKILL/$dst"; then
      echo "out of sync: $src -> $dst"
      status=1
    fi
  else
    mkdir -p "$(dirname "$SKILL/$dst")"
    cp -p "$HERE/$src" "$SKILL/$dst"
  fi
done <<EOF
$(pairs)
EOF

if [ "$MODE" = "--check" ]; then
  [ "$status" = 0 ] && echo "skill copy is in sync"
  exit "$status"
fi
chmod +x "$SKILL/scripts/toolkit/brz-mac.sh" "$SKILL/scripts/toolkit/probe/build.sh" "$SKILL/scripts/toolkit/tools/build-d9vk.sh"
echo "synced into $SKILL"
