#!/bin/bash
# brz-mac.sh — Battle Realms: Zen Edition helper for Sikarugir (Wine) wrappers on Apple Silicon.
#
# Switches the game's Direct3D 9 path between renderer "profiles", edits the game ini
# and dxvk.conf, launches Steam with diagnostic env vars, collects logs and records
# benchmark runs. Everything it changes is backed up under $BRZ_HOME first.
#
# Written for the bash 3.2 that ships with macOS (no assoc arrays, no GNU-only flags).
# Run `./brz-mac.sh help` for usage.

set -u

BRZ_VERSION="1.0.0"
APPID=1025600
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="$SCRIPT_DIR/templates"
BRZ_HOME="${BRZ_HOME:-$HOME/.brz-mac}"
BACKUPS="$BRZ_HOME/backups"
LOGDIR="$BRZ_HOME/logs"
BENCH_CSV="$BRZ_HOME/bench.csv"
MANIFEST_NAME=".brz-managed"
PROFILE_NAME=".brz-profile"
PROFILES="wrapper wined3d dxvk dgvoodoo"

WRAPPER="${BRZ_WRAPPER:-}"
GAME_DIR="${BRZ_GAME_DIR:-}"
PREFIX=""
WINE=""
GAME_EXE=""
INI=""

# ---------------------------------------------------------------------------
# output helpers

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s✗%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
hdr()  { printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; }

confirm() {
  [ "${BRZ_YES:-0}" = "1" ] && return 0
  printf '%s [y/N] ' "$1"
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

is_mac() { [ "$(uname -s)" = "Darwin" ]; }

# ---------------------------------------------------------------------------
# discovery

is_wrapper() { [ -d "$1/Contents/SharedSupport/prefix/drive_c" ]; }

find_wrapper() {
  if [ -n "$WRAPPER" ]; then
    WRAPPER="${WRAPPER%/}"
    is_wrapper "$WRAPPER" || die "BRZ_WRAPPER=$WRAPPER is not a Sikarugir/Wineskin wrapper (no Contents/SharedSupport/prefix/drive_c)."
    return
  fi
  local found="" count=0 dir app
  for dir in "/Applications" "/Applications/Sikarugir" "$HOME/Applications" "$HOME/Applications/Sikarugir" "$HOME/Applications/Porting Kit"; do
    [ -d "$dir" ] || continue
    for app in "$dir"/*.app; do
      [ -d "$app" ] || continue
      if is_wrapper "$app"; then
        found="$found$app"$'\n'
        count=$((count + 1))
      fi
    done
  done
  if [ "$count" -eq 0 ]; then
    die "No Wine wrapper found. Set BRZ_WRAPPER=/path/to/YourWrapper.app"
  elif [ "$count" -gt 1 ]; then
    # Prefer the one that actually contains the game.
    local match=""
    while IFS= read -r app; do
      [ -n "$app" ] || continue
      if find "$app/Contents/SharedSupport/prefix/drive_c" -maxdepth 8 -name 'Battle_Realms.ini' 2>/dev/null | grep -q .; then
        [ -z "$match" ] && match="$app"
      fi
    done <<EOF
$found
EOF
    if [ -n "$match" ]; then
      WRAPPER="$match"
    else
      warn "Several wrappers found and none contains Battle_Realms.ini:"
      printf '%s' "$found" >&2
      die "Pick one with BRZ_WRAPPER=/path/to/Wrapper.app"
    fi
  else
    WRAPPER="${found%$'\n'}"
  fi
}

find_wine() {
  local cand
  for cand in "$WRAPPER/Contents/SharedSupport/wine/bin/wine" "$WRAPPER/Contents/SharedSupport/wine/bin/wine64"; do
    if [ -x "$cand" ]; then WINE="$cand"; return; fi
  done
  cand="$(find "$WRAPPER/Contents" -maxdepth 6 -path '*/bin/wine*' -type f -perm -u+x 2>/dev/null | grep -E '/wine(64)?$' | head -n 1)"
  [ -n "$cand" ] && WINE="$cand"
}

find_game() {
  if [ -n "$GAME_DIR" ]; then
    GAME_DIR="${GAME_DIR%/}"
  else
    local ini
    ini="$(find "$PREFIX/drive_c" -maxdepth 8 -name 'Battle_Realms.ini' -not -path '*/users/*' 2>/dev/null | head -n 1)"
    [ -n "$ini" ] && GAME_DIR="$(dirname "$ini")"
  fi
  [ -n "$GAME_DIR" ] || return 0
  [ -d "$GAME_DIR" ] || die "Game dir $GAME_DIR does not exist."
  [ -f "$GAME_DIR/Battle_Realms.ini" ] && INI="$GAME_DIR/Battle_Realms.ini"
  if [ -f "$GAME_DIR/Battle_Realms_F.exe" ]; then
    GAME_EXE="Battle_Realms_F.exe"
  else
    local exe
    for exe in "$GAME_DIR"/Battle_Realms*.exe; do
      [ -f "$exe" ] && { GAME_EXE="$(basename "$exe")"; break; }
    done
  fi
  GAME_EXE="${BRZ_GAME_EXE:-$GAME_EXE}"
}

setup() {
  find_wrapper
  PREFIX="$WRAPPER/Contents/SharedSupport/prefix"
  find_wine
  find_game
  mkdir -p "$BACKUPS" "$LOGDIR"
}

need_game() {
  [ -n "$GAME_DIR" ] || die "Battle Realms install not found in $PREFIX/drive_c. Install it via Steam in the wrapper, or set BRZ_GAME_DIR."
  [ -n "$GAME_EXE" ] || die "No Battle_Realms*.exe in $GAME_DIR. Set BRZ_GAME_EXE."
}

need_wine() {
  [ -n "$WINE" ] || die "Could not find the wrapper's wine binary under $WRAPPER/Contents. Is the engine installed?"
}

wine_running() {
  is_mac || return 1
  pgrep -f "$PREFIX" >/dev/null 2>&1 || pgrep -fi 'steam\.exe|Battle_Realms' >/dev/null 2>&1
}

need_stopped() {
  if wine_running; then
    warn "The wrapper/Steam/game seems to be running. Quit it first (or run: $0 kill)."
    confirm "Continue anyway?" || exit 1
  fi
}

# ---------------------------------------------------------------------------
# wine / registry

wine_run() { WINEPREFIX="$PREFIX" WINEDEBUG="${WINEDEBUG:--all}" "$WINE" "$@"; }

override_key() { printf 'HKCU\\Software\\Wine\\AppDefaults\\%s\\DllOverrides' "$GAME_EXE"; }

set_override() { # dll value
  need_wine
  wine_run reg add "$(override_key)" /v "$1" /t REG_SZ /d "$2" /f >/dev/null 2>&1 \
    || die "wine reg add failed for $1=$2"
}

del_override() { # dll
  need_wine
  wine_run reg delete "$(override_key)" /v "$1" /f >/dev/null 2>&1 || true
}

# Print the per-app DllOverrides block straight from user.reg (no wine needed).
show_overrides() {
  local reg="$PREFIX/user.reg"
  [ -f "$reg" ] || { info "  (no user.reg yet)"; return; }
  awk -v exe="$GAME_EXE" '
    BEGIN { want = tolower("[Software\\\\Wine\\\\AppDefaults\\\\" exe "\\\\DllOverrides]") }
    /^\[/ { inblk = (index(tolower($0), want) == 1); next }
    inblk && /^"/ { sub(/\r$/, ""); print "  " $0; n++ }
    END { if (!n) print "  (none — wrapper defaults apply)" }
  ' "$reg"
  awk '
    /^\[Software\\\\Wine\\\\DllOverrides\]/ { inblk = 1; next }
    /^\[/ { inblk = 0 }
    inblk && /^"\*?(d3d8|d3d9|d3d11|dxgi|ddraw)"/ { sub(/\r$/, ""); print "  global: " $0 }
  ' "$reg"
}

# ---------------------------------------------------------------------------
# key=value files (Battle_Realms.ini, dxvk.conf, dgVoodoo.conf)

kv_get() { # file key
  awk -v k="$2" '
    { line = $0; sub(/\r$/, "", line) }
    { l = line; sub(/^[ \t]+/, "", l) }
    tolower(substr(l, 1, length(k))) == tolower(k) {
      rest = substr(l, length(k) + 1)
      if (rest ~ /^[ \t]*=/) { sub(/^[ \t]*=[ \t]*/, "", rest); print rest; exit }
    }
  ' "$1"
}

kv_set() { # file key value — replaces first active `key = ...` line (keeps CRLF), else appends
  local file="$1" key="$2" val="$3" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/brz.XXXXXX")" || die "mktemp failed"
  awk -v k="$key" -v v="$val" '
    BEGIN { done = 0; crlf = 0 }
    {
      line = $0; cr = ""
      if (line ~ /\r$/) { cr = "\r"; crlf = 1; sub(/\r$/, "", line) }
      l = line; sub(/^[ \t]+/, "", l)
      if (!done && tolower(substr(l, 1, length(k))) == tolower(k)) {
        rest = substr(l, length(k) + 1)
        if (rest ~ /^[ \t]*=/) {
          # keep the file'"'"'s own spacing around "=" (e.g. "HardwareTL =1" stays that shape)
          match(rest, /^[ \t]*=[ \t]*/)
          print substr(l, 1, length(k)) substr(rest, 1, RLENGTH) v cr
          done = 1
          next
        }
      }
      print $0
    }
    END { if (!done) printf "%s=%s%s\n", k, v, (crlf ? "\r" : "") }
  ' "$file" > "$tmp" || { rm -f "$tmp"; die "failed to edit $file"; }
  cat "$tmp" > "$file" && rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# backups / managed files

backup_once() {
  local stamp="$BACKUPS/original"
  [ -d "$stamp" ] && return
  mkdir -p "$stamp"
  [ -n "$INI" ] && cp -p "$INI" "$stamp/Battle_Realms.ini"
  [ -f "$PREFIX/user.reg" ] && cp -p "$PREFIX/user.reg" "$stamp/user.reg"
  local f
  for f in d3d8.dll d3d9.dll dxgi.dll ddraw.dll D3DImm.dll dxvk.conf dgVoodoo.conf; do
    [ -f "$GAME_DIR/$f" ] && cp -p "$GAME_DIR/$f" "$stamp/$f"
  done
  printf '%s\n' "$GAME_DIR" > "$stamp/GAME_DIR"
  ok "Original state backed up to $stamp"
}

backup_now() { # label — timestamped copy of ini + user.reg
  local d
  d="$BACKUPS/$(date +%Y%m%d-%H%M%S)-$1"
  mkdir -p "$d"
  [ -n "$INI" ] && cp -p "$INI" "$d/"
  [ -f "$PREFIX/user.reg" ] && cp -p "$PREFIX/user.reg" "$d/"
  [ -f "$GAME_DIR/dxvk.conf" ] && cp -p "$GAME_DIR/dxvk.conf" "$d/"
}

remove_managed() {
  local m="$GAME_DIR/$MANIFEST_NAME" f
  [ -f "$m" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in */*|..*) continue ;; esac   # only plain file names inside the game dir
    rm -f "$GAME_DIR/$f"
  done < "$m"
  rm -f "$m"
}

install_managed() { # src dest-name
  cp "$1" "$GAME_DIR/$2" || die "copy failed: $1"
  printf '%s\n' "$2" >> "$GAME_DIR/$MANIFEST_NAME"
}

# True if the PE file is 32-bit x86 (machine 0x014c). Reads the header with od, no `file` needed.
is_pe_i386() {
  local off machine
  off="$(od -An -t u4 -j 60 -N 4 "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$off" ] || return 1
  machine="$(od -An -t x2 -j $((off + 4)) -N 2 "$1" 2>/dev/null | tr -d ' ')"
  [ "$machine" = "014c" ]
}

find_dll() { # dir name — prefer 32-bit copies
  local f
  while IFS= read -r f; do
    if is_pe_i386 "$f"; then printf '%s\n' "$f"; return 0; fi
  done <<EOF
$(find "$1" -iname "$2" -type f 2>/dev/null)
EOF
  return 1
}

# ---------------------------------------------------------------------------
# commands

cmd_doctor() {
  setup
  hdr "Machine"
  if is_mac; then
    info "  macOS        $(sw_vers -productVersion 2>/dev/null) ($(uname -m))"
    local ram_gb
    ram_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
    info "  RAM          ${ram_gb} GB"
    info "  CPU          $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then ok "Rosetta 2 installed"; else warn "Rosetta 2 missing: softwareupdate --install-rosetta --agree-to-license"; fi
    if pmset -g 2>/dev/null | grep -Eq 'lowpowermode[[:space:]]+1'; then warn "Low Power Mode is ON — turn it off for big battles"; else ok "Low Power Mode off"; fi
    if pmset -g batt 2>/dev/null | grep -q 'Battery Power'; then warn "On battery — plug in for consistent clocks"; fi
  else
    warn "Not macOS ($(uname -s)) — machine checks skipped"
  fi
  local free_k free_gb
  free_k="$(df -k "$HOME" | awk 'NR==2 {print $4}')"
  free_gb=$((free_k / 1048576))
  if [ "$free_gb" -lt 8 ]; then warn "Free disk: ${free_gb} GB (<8 GB: expect swap stutter on 8 GB RAM Macs)"; else ok "Free disk: ${free_gb} GB"; fi

  hdr "Wrapper"
  info "  wrapper      $WRAPPER"
  if [ -n "$WINE" ]; then ok "wine         $WINE"; else warn "wine binary not found"; fi
  is_mac && info "  size         $(du -sh "$WRAPPER" 2>/dev/null | awk '{print $1}')"
  [ -f "$WRAPPER/Contents/SharedSupport/Logs/LastRunWine.log" ] && info "  last log     $WRAPPER/Contents/SharedSupport/Logs/LastRunWine.log"

  hdr "Game"
  if [ -z "$GAME_DIR" ]; then warn "Battle Realms not found in the prefix"; return; fi
  info "  dir          $GAME_DIR"
  info "  exe          ${GAME_EXE:-?}"
  info "  profile      $(cat "$GAME_DIR/$PROFILE_NAME" 2>/dev/null || echo 'none (wrapper defaults)')"
  if [ -n "$INI" ]; then
    local k
    for k in HardwareTL Fullscreen Width Height; do
      info "  ini $k$(printf '%*s' $((10 - ${#k})) '')$(kv_get "$INI" "$k")"
    done
  fi
  local f
  for f in d3d8.dll d3d9.dll dxgi.dll ddraw.dll dxvk.conf dgVoodoo.conf; do
    if [ -f "$GAME_DIR/$f" ]; then
      local arch="x64/other"; is_pe_i386 "$GAME_DIR/$f" && arch="i386"
      case "$f" in *.dll) info "  game dir has $f ($arch)" ;; *) info "  game dir has $f" ;; esac
    fi
  done
  hdr "d3d9 DLL overrides"
  show_overrides
}

cmd_profile() {
  local name="${1:-}" src
  [ -n "$name" ] || die "usage: $0 profile <$PROFILES>"
  setup; need_game; need_stopped; backup_once
  backup_now "before-$name"
  remove_managed

  case "$name" in
    wrapper)
      del_override d3d9
      ok "Removed per-game overrides — the wrapper's Configure renderer toggles decide again."
      ;;
    wined3d)
      set_override d3d9 builtin
      ok "d3d9 → Wine builtin (WineD3D/OpenGL). Baseline: correct image, slow battles."
      ;;
    dxvk)
      local dir="${2:-${BRZ_DXVK_DIR:-}}"
      [ -n "$dir" ] && [ -d "$dir" ] || die "usage: $0 profile dxvk /path/to/extracted/DXVK-MacOS-release  (or set BRZ_DXVK_DIR)"
      src="$(find_dll "$dir" d3d9.dll)" || die "No 32-bit (i386) d3d9.dll under $dir. Battle Realms is 32-bit; the x64 DLL will not load."
      install_managed "$src" d3d9.dll
      if [ ! -f "$GAME_DIR/dxvk.conf" ]; then
        install_managed "$TEMPLATES/dxvk.conf" dxvk.conf
      else
        warn "Keeping your existing dxvk.conf"
      fi
      set_override d3d9 native
      ok "d3d9 → DXVK ($src)"
      info "  Tip: run '$0 launch --hud' to confirm DXVK is active (HUD appears top-left)."
      ;;
    dgvoodoo)
      local dir="${2:-${BRZ_DGV_DIR:-}}"
      [ -n "$dir" ] && [ -d "$dir" ] || die "usage: $0 profile dgvoodoo /path/to/extracted/dgVoodoo2  (or set BRZ_DGV_DIR)"
      src="$dir/MS/x86/D3D9.dll"
      [ -f "$src" ] || src="$(find_dll "$dir" D3D9.dll)" || die "No 32-bit D3D9.dll under $dir (expected MS/x86/D3D9.dll)."
      install_managed "$src" d3d9.dll
      if [ ! -f "$GAME_DIR/dgVoodoo.conf" ]; then
        install_managed "$TEMPLATES/dgVoodoo.conf" dgVoodoo.conf
      fi
      set_override d3d9 native
      ok "d3d9 → dgVoodoo2 → D3D11 ($src)"
      warn "In the wrapper's Configure app: turn DXMT ON and DXVK/D9VK OFF, or D3D11 falls back to OpenGL."
      ;;
    *) die "unknown profile '$name' (choose: $PROFILES)" ;;
  esac
  printf '%s\n' "$name" > "$GAME_DIR/$PROFILE_NAME"
}

cmd_ini() {
  setup; need_game
  [ -n "$INI" ] || die "Battle_Realms.ini not found in $GAME_DIR (launch the game once to create it)."
  case "${1:-show}" in
    show) tr -d '\r' < "$INI" | grep -v '^[[:space:]]*$' ;;
    get)  [ $# -ge 2 ] || die "usage: $0 ini get KEY"; kv_get "$INI" "$2" ;;
    set)
      [ $# -ge 3 ] || die "usage: $0 ini set KEY VALUE"
      backup_once; backup_now "ini-$2"
      kv_set "$INI" "$2" "$3"
      ok "$2 = $(kv_get "$INI" "$2")"
      ;;
    *) die "usage: $0 ini [show|get KEY|set KEY VALUE]" ;;
  esac
}

cmd_conf() { # edit dxvk.conf or dgVoodoo.conf in the game dir
  setup; need_game
  local which="${1:-}" file
  case "$which" in
    dxvk) file="$GAME_DIR/dxvk.conf" ;;
    dgvoodoo) file="$GAME_DIR/dgVoodoo.conf" ;;
    *) die "usage: $0 conf <dxvk|dgvoodoo> [show|set KEY VALUE]" ;;
  esac
  [ -f "$file" ] || die "$file not found — apply the matching profile first."
  case "${2:-show}" in
    show) grep -Ev '^[[:space:]]*(#|;|$)' "$file" ;;
    set)
      [ $# -ge 4 ] || die "usage: $0 conf $which set KEY VALUE"
      backup_now "conf-$3"
      kv_set "$file" "$3" "$4"
      ok "$3 = $(kv_get "$file" "$3")"
      ;;
    *) die "usage: $0 conf $which [show|set KEY VALUE]" ;;
  esac
}

cmd_launch() {
  setup; need_game; need_wine
  local hud=0 debug=0 a
  for a in "$@"; do
    case "$a" in
      --hud) hud=1 ;;
      --debug) debug=1 ;;
      *) die "usage: $0 launch [--hud] [--debug]" ;;
    esac
  done
  local steam_dir
  for steam_dir in "$PREFIX/drive_c/Program Files (x86)/Steam" "$PREFIX/drive_c/Program Files/Steam"; do
    [ -f "$steam_dir/steam.exe" ] && break
  done
  [ -f "$steam_dir/steam.exe" ] || die "steam.exe not found in the prefix."
  if wine_running; then
    warn "Steam is already running: -applaunch would go to that instance and these env vars would NOT reach the game."
    confirm "Launch anyway?" || exit 1
  fi

  local ts log
  ts="$(date +%Y%m%d-%H%M%S)"
  log="$LOGDIR/launch-$ts.log"

  # MoltenVK: force full image-view swizzle so old D3D9 formats (L8, A8L8) can't sample as black.
  # Apple Silicon usually swizzles natively; this rules out the case where it doesn't.
  export MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE="${MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE:-1}"
  # Metal fast-math off while hunting black pixels (NaN propagation); set to 1 if it costs FPS.
  export MVK_CONFIG_FAST_MATH_ENABLED="${MVK_CONFIG_FAST_MATH_ENABLED:-0}"
  export WINEMSYNC="${WINEMSYNC:-1}"
  [ "$hud" = 1 ] && export DXVK_HUD="${DXVK_HUD:-fps,frametimes,drawcalls,version,api}"
  if [ "$debug" = 1 ]; then
    export DXVK_LOG_LEVEL=debug DXVK_LOG_PATH="$LOGDIR" MVK_CONFIG_LOG_LEVEL=2
    export WINEDEBUG="${WINEDEBUG:-err+all,warn+d3d,+loaddll}"
  fi

  info "Launching Steam → app $APPID  (log: $log)"
  # shellcheck disable=SC2086
  ( cd "$steam_dir" && WINEPREFIX="$PREFIX" WINEDEBUG="${WINEDEBUG:--all}" \
      "$WINE" steam.exe ${BRZ_STEAM_ARGS:--silent -nofriendsui -nochatui -noverifyfiles} -applaunch "$APPID" \
      > "$log" 2>&1 & )
  ok "Started. Check which DLLs loaded afterwards with: grep -i 'd3d9' \"$log\" (needs --debug)"
}

cmd_kill() {
  setup; need_wine
  local server
  server="$(dirname "$WINE")/wineserver"
  if [ -x "$server" ]; then
    WINEPREFIX="$PREFIX" "$server" -k && ok "wineserver killed for this prefix"
  else
    die "wineserver not found next to $WINE"
  fi
}

cmd_logs() {
  setup
  local ts out
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$BRZ_HOME/brz-diag-$ts"
  mkdir -p "$out"
  cmd_doctor > "$out/doctor.txt" 2>&1
  cp -p "$WRAPPER"/Contents/SharedSupport/Logs/*.log "$out/" 2>/dev/null
  if [ -n "$GAME_DIR" ]; then
    cp -p "$GAME_DIR"/*.log "$out/" 2>/dev/null
    [ -n "$INI" ] && cp -p "$INI" "$out/"
    cp -p "$GAME_DIR/dxvk.conf" "$GAME_DIR/dgVoodoo.conf" "$out/" 2>/dev/null
  fi
  # shellcheck disable=SC2012  # log names are ours (launch-<timestamp>.log)
  ls -t "$LOGDIR"/* 2>/dev/null | head -n 6 | while IFS= read -r f; do cp -p "$f" "$out/"; done
  [ -f "$BENCH_CSV" ] && cp -p "$BENCH_CSV" "$out/"
  if is_mac; then
    ditto -c -k --keepParent "$out" "$out.zip" && rm -rf "$out" && out="$out.zip"
  else
    tar -czf "$out.tar.gz" -C "$BRZ_HOME" "$(basename "$out")" && rm -rf "$out" && out="$out.tar.gz"
  fi
  ok "Diagnostics bundle: $out"
}

cmd_bench() {
  setup; need_game
  if [ $# -lt 5 ]; then
    die "usage: $0 bench \"MAP / scenario\" AVG_FPS MIN_FPS UNITS_OK(y/n) CUTSCENES_OK(y/n) [\"notes\"]"
  fi
  [ -f "$BENCH_CSV" ] || printf 'date,profile,HardwareTL,scenario,avg_fps,min_fps,units_ok,cutscenes_ok,notes\n' > "$BENCH_CSV"
  local profile htl notes
  profile="$(cat "$GAME_DIR/$PROFILE_NAME" 2>/dev/null || echo wrapper)"
  htl="$( [ -n "$INI" ] && kv_get "$INI" HardwareTL )"
  notes="$(printf '%s' "${6:-}" | tr -d '"')"
  printf '%s,%s,%s,"%s",%s,%s,%s,%s,"%s"\n' "$(date +%Y-%m-%dT%H:%M)" "$profile" "$htl" \
    "$(printf '%s' "$1" | tr -d '"')" "$2" "$3" "$4" "$5" "$notes" >> "$BENCH_CSV"
  ok "Recorded. Results so far:"
  column -s, -t < "$BENCH_CSV" 2>/dev/null || cat "$BENCH_CSV"
}

cmd_disk() {
  setup
  hdr "Space"
  df -h "$HOME" | awk 'NR==2 {print "  free on disk: " $4 " of " $2}'
  local p
  for p in "$WRAPPER" \
           "$PREFIX/drive_c/Program Files (x86)/Steam/steamapps/downloading" \
           "$PREFIX/drive_c/Program Files (x86)/Steam/steamapps/shadercache" \
           "$PREFIX/drive_c/Program Files (x86)/Steam/appcache/httpcache" \
           "$PREFIX/drive_c/users/$USER/AppData/Local/Steam/htmlcache" \
           "$LOGDIR"; do
    [ -e "$p" ] && printf '  %-8s %s\n' "$(du -sh "$p" 2>/dev/null | awk '{print $1}')" "$p"
  done
  [ "${1:-}" = "--clean" ] || { info "  (run '$0 disk --clean' to delete Steam download/shader/http caches and old logs)"; return; }
  need_stopped
  confirm "Delete the cache folders listed above (not the game, not saves)?" || exit 1
  for p in "$PREFIX/drive_c/Program Files (x86)/Steam/steamapps/downloading" \
           "$PREFIX/drive_c/Program Files (x86)/Steam/steamapps/shadercache" \
           "$PREFIX/drive_c/Program Files (x86)/Steam/appcache/httpcache" \
           "$PREFIX/drive_c/users/$USER/AppData/Local/Steam/htmlcache"; do
    case "$p" in "$PREFIX"/drive_c/*) [ -d "$p" ] && rm -rf "$p" && ok "cleared $p" ;; esac
  done
  find "$LOGDIR" -type f -mtime +7 -exec rm -f {} + 2>/dev/null
  ok "Done."
}

cmd_restore() {
  setup; need_game; need_stopped
  local stamp="$BACKUPS/original"
  [ -d "$stamp" ] || die "No original backup in $stamp — nothing was changed by this tool."
  confirm "Restore Battle_Realms.ini, user.reg and game-dir DLLs to the state before brz-mac first ran?" || exit 1
  remove_managed
  [ -f "$stamp/Battle_Realms.ini" ] && [ -n "$INI" ] && cp -p "$stamp/Battle_Realms.ini" "$INI"
  [ -f "$stamp/user.reg" ] && cp -p "$stamp/user.reg" "$PREFIX/user.reg"
  local f
  for f in d3d8.dll d3d9.dll dxgi.dll ddraw.dll D3DImm.dll dxvk.conf dgVoodoo.conf; do
    if [ -f "$stamp/$f" ]; then cp -p "$stamp/$f" "$GAME_DIR/$f"; fi
  done
  rm -f "$GAME_DIR/$PROFILE_NAME"
  ok "Restored original state."
}

cmd_help() {
  cat <<EOF
brz-mac $BRZ_VERSION — Battle Realms: Zen Edition on Apple Silicon (Sikarugir/Wine)

  doctor                          Check Mac, wrapper, game, renderer state
  profile wrapper                 Remove per-game overrides (use wrapper's Configure toggles)
  profile wined3d                 Force Wine's OpenGL D3D9 (baseline)
  profile dxvk DIR                Use 32-bit d3d9.dll from an extracted DXVK-MacOS release
  profile dgvoodoo DIR            Use dgVoodoo2 (D3D9 → D3D11; enable DXMT in Configure)
  ini [show|get K|set K V]        Read/edit Battle_Realms.ini (e.g. ini set HardwareTL 1)
  conf dxvk|dgvoodoo [show|set K V]  Edit dxvk.conf / dgVoodoo.conf in the game dir
  launch [--hud] [--debug]        Start Steam quietly and launch the game with diagnostics
  kill                            Stop all Wine processes of this wrapper
  bench SCENARIO AVG MIN U C [N]  Append a benchmark row to $BENCH_CSV
  disk [--clean]                  Show/clear space used by caches
  logs                            Bundle logs + config into a zip for bug reports
  restore                         Put everything back as it was before the first change

Environment: BRZ_WRAPPER, BRZ_GAME_DIR, BRZ_GAME_EXE, BRZ_DXVK_DIR, BRZ_DGV_DIR,
             BRZ_STEAM_ARGS, BRZ_HOME (default ~/.brz-mac), BRZ_YES=1 (no prompts)
EOF
}

main() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    doctor)  cmd_doctor "$@" ;;
    profile) cmd_profile "$@" ;;
    ini)     cmd_ini "$@" ;;
    conf)    cmd_conf "$@" ;;
    launch)  cmd_launch "$@" ;;
    kill)    cmd_kill "$@" ;;
    bench)   cmd_bench "$@" ;;
    disk)    cmd_disk "$@" ;;
    logs)    cmd_logs "$@" ;;
    restore) cmd_restore "$@" ;;
    version) info "$BRZ_VERSION" ;;
    help|-h|--help) cmd_help ;;
    *) cmd_help; exit 1 ;;
  esac
}

main "$@"
