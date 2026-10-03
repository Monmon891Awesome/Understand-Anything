#!/bin/bash
# brz-mac.sh — helper for old 32-bit Direct3D 9 games in Sikarugir (Wine) wrappers on Apple Silicon.
# Tuned for Battle Realms: Zen Edition (the defaults); other games: set BRZ_GAME_DIR, BRZ_GAME_EXE,
# BRZ_APPID (Steam app id) and BRZ_INI_NAME (the game's settings file, if it has one).
#
# Switches the game's Direct3D 9 path between renderer "profiles", runs a D3D9 feature probe
# under each renderer, walks you through a one-change-per-round triage, edits the game ini
# and dxvk.conf, launches Steam with diagnostics, analyzes the logs and writes a report.
# Everything it changes is backed up under $BRZ_HOME first; `restore` undoes it all.
#
# Written for the bash 3.2 that ships with macOS (no assoc arrays, no GNU-only flags).
# Run `./brz-mac.sh help` for usage.

set -u

BRZ_VERSION="2.1.0"
APPID="${BRZ_APPID:-1025600}"
INI_NAME="${BRZ_INI_NAME:-Battle_Realms.ini}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="$SCRIPT_DIR/templates"
BUNDLED="$SCRIPT_DIR/dlls"
PROBE_EXE="${BRZ_PROBE_EXE:-$SCRIPT_DIR/bin/brz-probe.exe}"
BRZ_HOME="${BRZ_HOME:-$HOME/.brz-mac}"
BACKUPS="$BRZ_HOME/backups"
LOGDIR="$BRZ_HOME/logs"
DOWNLOADS="$BRZ_HOME/downloads"
BENCH_CSV="$BRZ_HOME/bench.csv"
TRIAGE_LOG="$BRZ_HOME/triage.log"
TRIAGE_STATE="$BRZ_HOME/triage.state"
MANIFEST_NAME=".brz-managed"
PROFILE_NAME=".brz-profile"
STASH_SUFFIX=".brz-orig"
PROFILES="wrapper wined3d wined3d-vk d9vk d9vk-diag dxvk dgvoodoo"
D9VK_BUILD="d9vk-f229921"

WRAPPER="${BRZ_WRAPPER:-}"
GAME_DIR="${BRZ_GAME_DIR:-}"
PREFIX=""
WINE=""
WINESERVER=""
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
  read -r ans || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ask "question" default -> echoes the answer (reads stdin even with BRZ_YES, so tests can script it)
ask() {
  local q="$1" def="${2:-}" ans
  if [ -n "$def" ]; then printf '%s [%s] ' "$q" "$def" >&2; else printf '%s ' "$q" >&2; fi
  if ! read -r ans; then ans=""; fi
  [ -n "$ans" ] || ans="$def"
  printf '%s\n' "$ans"
}

is_mac() { [ "$(uname -s)" = "Darwin" ]; }

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

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
      if find "$app/Contents/SharedSupport/prefix/drive_c" -maxdepth 8 -name "$INI_NAME" 2>/dev/null | grep -q .; then
        [ -z "$match" ] && match="$app"
      fi
    done <<EOF
$found
EOF
    if [ -n "$match" ]; then
      WRAPPER="$match"
    else
      warn "Several wrappers found and none contains $INI_NAME:"
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
    if [ -x "$cand" ]; then WINE="$cand"; break; fi
  done
  if [ -z "$WINE" ]; then
    cand="$(find "$WRAPPER/Contents" -maxdepth 6 -path '*/bin/wine*' -type f -perm -u+x 2>/dev/null | grep -E '/wine(64)?$' | head -n 1)"
    [ -n "$cand" ] && WINE="$cand"
  fi
  [ -n "$WINE" ] && [ -x "$(dirname "$WINE")/wineserver" ] && WINESERVER="$(dirname "$WINE")/wineserver"
  return 0
}

find_game() {
  if [ -n "$GAME_DIR" ]; then
    GAME_DIR="${GAME_DIR%/}"
  else
    local ini
    ini="$(find "$PREFIX/drive_c" -maxdepth 8 -name "$INI_NAME" -not -path '*/users/*' -not -path '*/brz-probe/*' 2>/dev/null | head -n 1)"
    [ -n "$ini" ] && GAME_DIR="$(dirname "$ini")"
  fi
  [ -n "$GAME_DIR" ] || return 0
  [ -d "$GAME_DIR" ] || die "Game dir $GAME_DIR does not exist."
  [ -f "$GAME_DIR/$INI_NAME" ] && INI="$GAME_DIR/$INI_NAME"
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
  mkdir -p "$BACKUPS" "$LOGDIR" "$DOWNLOADS"
}

need_game() {
  [ -n "$GAME_DIR" ] || die "Game not found (looked for $INI_NAME under $PREFIX/drive_c). Install it via Steam in the wrapper and start it once, or set BRZ_GAME_DIR (and BRZ_GAME_EXE)."
  [ -n "$GAME_EXE" ] || die "No game exe found in $GAME_DIR. Set BRZ_GAME_EXE (the .exe the game really runs)."
}

need_wine() {
  [ -n "$WINE" ] || die "Could not find the wrapper's wine binary under $WRAPPER/Contents. Is the engine installed?"
}

wine_running() {
  is_mac || return 1
  pgrep -qi 'wineserver|steam\.exe|Battle_Realms|brz-probe' 2>/dev/null
}

need_stopped() {
  if wine_running; then
    warn "Wine/Steam/the game seems to be running. Quit it first (or run: $0 kill)."
    confirm "Continue anyway?" || exit 1
  fi
}

# Wait for this prefix's wineserver to exit so user.reg on disk is current.
wine_settle() {
  [ -n "$WINESERVER" ] && WINEPREFIX="$PREFIX" "$WINESERVER" -w 2>/dev/null
  return 0
}

# Windows-side path of a Unix directory, via the Z: drive if the prefix has one.
winpath() {
  # shellcheck disable=SC1003  # tr maps / to a single backslash
  if [ -e "$PREFIX/dosdevices/z:" ]; then printf 'Z:%s' "$1" | tr '/' '\\'; else printf ''; fi
}

# ---------------------------------------------------------------------------
# wine / registry (per-app keys only — the rest of the wrapper is untouched)

wine_run() { WINEPREFIX="$PREFIX" WINEDEBUG="${WINEDEBUG:--all}" "$WINE" "$@"; }

app_key() { printf 'HKCU\\Software\\Wine\\AppDefaults\\%s\\%s' "$1" "$2"; }  # exe subkey

reg_set() { # exe subkey name value
  need_wine
  wine_run reg add "$(app_key "$1" "$2")" /v "$3" /t REG_SZ /d "$4" /f >/dev/null 2>&1 \
    || die "wine reg add failed for $1 $2 $3=$4"
}

reg_del() { # exe subkey name
  need_wine
  wine_run reg delete "$(app_key "$1" "$2")" /v "$3" /f >/dev/null 2>&1 || true
}

reg_set_raw() { # key name type data   e.g. 'HKCU\Software\Wine\Mac Driver' RetinaMode REG_SZ N
  need_wine
  wine_run reg add "$1" /v "$2" /t "$3" /d "$4" /f >/dev/null 2>&1 || die "wine reg add failed for $1 $2=$4"
}

reg_del_raw() { # key name
  need_wine
  wine_run reg delete "$1" /v "$2" /f >/dev/null 2>&1 || true
}

# Retina mode exactly the way Sikarugir's Configure writes it. Wine's Mac driver reads RetinaMode
# only from the wrapper-wide key (no per-app lookup), so this affects the whole wrapper.
retina_set() { # on|off|default
  case "$1" in
    on)  reg_set_raw 'HKCU\Software\Wine\Mac Driver' RetinaMode REG_SZ Y
         reg_set_raw 'HKCU\Control Panel\Desktop' LogPixels REG_DWORD 192 ;;
    off) reg_set_raw 'HKCU\Software\Wine\Mac Driver' RetinaMode REG_SZ N
         reg_set_raw 'HKCU\Control Panel\Desktop' LogPixels REG_DWORD 96 ;;
    default) reg_del_raw 'HKCU\Software\Wine\Mac Driver' RetinaMode
             reg_del_raw 'HKCU\Control Panel\Desktop' LogPixels ;;
  esac
}

# Print per-app overrides for an exe straight from user.reg (call wine_settle first).
show_app_reg() { # exe
  local reg="$PREFIX/user.reg"
  [ -f "$reg" ] || { info "  (no user.reg yet)"; return; }
  awk -v exe="$1" '
    BEGIN { base = tolower("[Software\\\\Wine\\\\AppDefaults\\\\" exe "\\\\") }
    /^\[/ {
      l = tolower($0); blk = ""
      if (index(l, base "dlloverrides]") == 1) blk = "override"
      else if (index(l, base "direct3d]") == 1) blk = "direct3d"
      else if (index(l, base "mac driver]") == 1) blk = "mac driver"
      next
    }
    blk != "" && /^"/ { sub(/\r$/, ""); print "  " blk ": " $0; n++ }
    END { if (!n) print "  (none — wrapper defaults apply)" }
  ' "$reg"
  awk '
    /^\[Software\\\\Wine\\\\DllOverrides\]/ { inblk = 1; next }
    /^\[Software\\\\Wine\\\\Mac Driver\]/ { inblk = 2; next }
    /^\[/ { inblk = 0 }
    inblk == 1 && /^"\*?(d3d8|d3d9|d3d10core|d3d11|dxgi|ddraw)"/ { sub(/\r$/, ""); print "  global override: " $0 }
    inblk == 2 && /^"RetinaMode"/ { sub(/\r$/, ""); print "  global mac driver: " $0 }
  ' "$reg"
}

# ---------------------------------------------------------------------------
# key=value files (the game ini, dxvk.conf, dgVoodoo.conf)

kv_get() { # file key
  awk -v k="$2" '
    { line = $0; sub(/\r$/, "", line) }
    { l = line; sub(/^[ \t]+/, "", l) }
    tolower(substr(l, 1, length(k))) == tolower(k) {
      rest = substr(l, length(k) + 1)
      if (rest ~ /^[ \t]*=/) { sub(/^[ \t]*=[ \t]*/, "", rest); sub(/[ \t]+$/, "", rest); print rest; exit }
    }
  ' "$1"
}

# Replace the first active `key = ...` line, keeping the file's spacing and CRLF endings.
kv_replace() { # file key value
  local file="$1" key="$2" val="$3" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/brz.XXXXXX")" || die "mktemp failed"
  awk -v k="$key" -v v="$val" '
    BEGIN { done = 0 }
    {
      line = $0; cr = ""
      if (line ~ /\r$/) { cr = "\r"; sub(/\r$/, "", line) }
      l = line; sub(/^[ \t]+/, "", l)
      if (!done && tolower(substr(l, 1, length(k))) == tolower(k)) {
        rest = substr(l, length(k) + 1)
        if (rest ~ /^[ \t]*=/) {
          match(rest, /^[ \t]*=[ \t]*/)
          print substr(l, 1, length(k)) substr(rest, 1, RLENGTH) v cr
          done = 1
          next
        }
      }
      print $0
    }
  ' "$file" > "$tmp" || { rm -f "$tmp"; die "failed to edit $file"; }
  cat "$tmp" > "$file" && rm -f "$tmp"
}

# Insert `key=value` (known to be absent) after the last line of [section], creating the
# section at the end if needed; without a section it goes at the end of the file.
kv_insert() { # file key value [section]
  local file="$1" key="$2" val="$3" section="${4:-}" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/brz.XXXXXX")" || die "mktemp failed"
  awk -v k="$key" -v v="$val" -v sec="$section" '
    BEGIN { insec = 0; seen = 0; done = 0; crlf = 0; blanks = "" }
    {
      line = $0; cr = ""
      if (line ~ /\r$/) { cr = "\r"; crlf = 1; sub(/\r$/, "", line) }
      l = line; sub(/^[ \t]+/, "", l)
      if (l ~ /^\[/) {
        if (insec && !done) { print k "=" v cr; done = 1 }
        printf "%s", blanks; blanks = ""
        name = l; sub(/^\[/, "", name); sub(/\].*$/, "", name)
        insec = (sec != "" && tolower(name) == tolower(sec))
        if (insec) seen = 1
        print $0
        next
      }
      if (insec && l == "") { blanks = blanks $0 "\n"; next }   # hold trailing blank lines of the section
      printf "%s", blanks; blanks = ""
      print $0
    }
    END {
      eol = (crlf ? "\r" : "")
      if (!done && insec) { print k "=" v eol; done = 1 }
      printf "%s", blanks
      if (!done) {
        if (sec != "" && !seen) printf "[%s]%s\n", sec, eol
        printf "%s=%s%s\n", k, v, eol
      }
    }
  ' "$file" > "$tmp" || { rm -f "$tmp"; die "failed to edit $file"; }
  cat "$tmp" > "$file" && rm -f "$tmp"
}

kv_has() { # file key — true if an active `key =` line exists
  awk -v k="$2" '
    { l = $0; sub(/\r$/, "", l); sub(/^[ \t]+/, "", l) }
    tolower(substr(l, 1, length(k))) == tolower(k) && substr(l, length(k) + 1) ~ /^[ \t]*=/ { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

kv_upsert() { # file key value [section]
  if kv_has "$1" "$2"; then kv_replace "$1" "$2" "$3"; else kv_insert "$1" "$2" "$3" "${4:-}"; fi
}

ini_section_for() { # key -> section in Battle_Realms.ini
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    enabled|numsfxchannels|soundtimerperiod|soundtimerresolution) printf 'Sound' ;;
    *) printf '%s' "${BRZ_INI_SECTION:-VideoState}" ;;
  esac
}

# ---------------------------------------------------------------------------
# backups / managed files

backup_once() {
  local stamp="$BACKUPS/original"
  [ -d "$stamp" ] && return
  mkdir -p "$stamp"
  [ -n "$INI" ] && cp -p "$INI" "$stamp/$INI_NAME"
  [ -f "$PREFIX/user.reg" ] && cp -p "$PREFIX/user.reg" "$stamp/user.reg"
  local f
  for f in d3d8.dll d3d9.dll d3d11.dll dxgi.dll ddraw.dll D3DImm.dll dxvk.conf dgVoodoo.conf; do
    [ -f "$GAME_DIR/$f" ] && cp -p "$GAME_DIR/$f" "$stamp/$f"
  done
  printf '%s\n' "$GAME_DIR" > "$stamp/GAME_DIR"
  ok "Original state backed up to $stamp"
}

backup_now() { # label — timestamped copy of ini + user.reg + dxvk.conf
  local d
  d="$BACKUPS/$(date +%Y%m%d-%H%M%S)-$1"
  mkdir -p "$d"
  [ -n "$INI" ] && cp -p "$INI" "$d/"
  [ -f "$PREFIX/user.reg" ] && cp -p "$PREFIX/user.reg" "$d/"
  [ -n "$GAME_DIR" ] && [ -f "$GAME_DIR/dxvk.conf" ] && cp -p "$GAME_DIR/dxvk.conf" "$d/"
  return 0
}

# Remove files a profile installed into DIR and put back anything they replaced.
remove_managed() { # dir
  local dir="$1" m="$1/$MANIFEST_NAME" f
  [ -f "$m" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in */*|..*) continue ;; esac   # only plain file names inside the dir
    rm -f "$dir/$f"
    [ -f "$dir/$f$STASH_SUFFIX" ] && mv "$dir/$f$STASH_SUFFIX" "$dir/$f"
  done < "$m"
  rm -f "$m"
}

install_managed() { # src dir dest-name
  local dir="$2" name="$3"
  if [ -e "$dir/$name" ] && ! grep -qx "$name" "$dir/$MANIFEST_NAME" 2>/dev/null; then
    mv "$dir/$name" "$dir/$name$STASH_SUFFIX" || die "could not stash existing $dir/$name"
    info "  (kept the existing $name as $name$STASH_SUFFIX; it comes back on the next profile switch)"
  fi
  cp "$1" "$dir/$name" || die "copy failed: $1"
  printf '%s\n' "$name" >> "$dir/$MANIFEST_NAME"
}

# True if the PE file is 32-bit x86 (machine 0x014c). Reads the header with od, no `file` needed.
is_pe_i386() {
  local off machine
  off="$(od -An -t u4 -j 60 -N 4 "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$off" ] || return 1
  machine="$(od -An -t x2 -j $((off + 4)) -N 2 "$1" 2>/dev/null | tr -d ' ')"
  [ "$machine" = "014c" ]
}

pe_arch() {
  local off machine
  off="$(od -An -t u4 -j 60 -N 4 "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$off" ] || { printf 'not-PE'; return; }
  machine="$(od -An -t x2 -j $((off + 4)) -N 2 "$1" 2>/dev/null | tr -d ' ')"
  case "$machine" in 014c) printf 'i386' ;; 8664) printf 'x64' ;; aa64) printf 'arm64' ;; *) printf 'PE-%s' "$machine" ;; esac
}

find_dll() { # dir name — prefer 32-bit copies
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_pe_i386 "$f"; then printf '%s\n' "$f"; return 0; fi
  done <<EOF
$(find "$1" -iname "$2" -type f 2>/dev/null)
EOF
  return 1
}

# What is this d3d9.dll really? (Wine builtin / placeholder, DXVK/D9VK + build traits, dgVoodoo)
dll_kind() { # file
  local f="$1" kind traits=""
  [ -f "$f" ] || { printf 'missing'; return; }
  if grep -aq 'dgVoodoo' "$f"; then kind="dgVoodoo2"
  elif grep -aqi 'dxvk' "$f"; then
    kind="DXVK/D9VK"
    grep -aq 'Software Prom' "$f" && traits="$traits +16-bit-promotion"
    grep -aq 'D3D9-DIAG' "$f" && traits="$traits +diag-logging"
    grep -aq 'deAliasedSamplers' "$f" && traits="$traits +deAliasedSamplers(DXVK-3.x fork)"
    grep -aq 'enableAsync' "$f" && traits="$traits +async"
  elif grep -aq 'Wine placeholder DLL' "$f"; then kind="Wine placeholder (loads Wine builtin)"
  elif grep -aq 'Wine builtin DLL' "$f"; then kind="Wine builtin"
  else kind="unknown"
  fi
  printf '%s%s [%s, %s KB, sha256 %s]' "$kind" "$traits" "$(pe_arch "$f")" \
    "$(( $(wc -c < "$f") / 1024 ))" "$(sha256 "$f" | cut -c1-12)"
}

# ---------------------------------------------------------------------------
# renderer profiles — applied to a target dir + exe (the game, or the probe)

latest_download() { # kind -> newest extracted dir under $DOWNLOADS/<kind>
  local d best=""
  for d in "$DOWNLOADS/$1"/*/; do
    [ -d "$d" ] && best="${d%/}"
  done
  printf '%s' "$best"
}

profile_dir_arg() { # profile [explicit-dir] -> dir for dxvk/dgvoodoo
  local p="$1" dir="${2:-}"
  if [ -z "$dir" ]; then
    case "$p" in
      dxvk) dir="${BRZ_DXVK_DIR:-$(latest_download dxvk-macos)}" ;;
      dgvoodoo) dir="${BRZ_DGV_DIR:-$(latest_download dgvoodoo)}" ;;
    esac
  fi
  printf '%s' "$dir"
}

profile_available() { # profile -> 0 if everything it needs is present
  case "$1" in
    wrapper|wined3d|wined3d-vk) return 0 ;;
    d9vk) [ -f "$BUNDLED/$D9VK_BUILD/d3d9.dll" ] ;;
    d9vk-diag) [ -f "$BUNDLED/$D9VK_BUILD-diag/d3d9.dll" ] ;;
    dxvk|dgvoodoo) local d; d="$(profile_dir_arg "$1")"; [ -n "$d" ] && [ -d "$d" ] ;;
    *) return 1 ;;
  esac
}

# apply_profile DIR EXE PROFILE [EXTRA_DIR] — installs DLLs into DIR and sets per-app keys for EXE
apply_profile() {
  local dir="$1" exe="$2" name="$3" extra="${4:-}" src conf
  remove_managed "$dir"
  case "$name" in
    wrapper)
      reg_del "$exe" DllOverrides d3d9
      reg_del "$exe" Direct3D renderer
      ;;
    wined3d)
      reg_set "$exe" DllOverrides d3d9 builtin
      reg_set "$exe" Direct3D renderer gl
      ;;
    wined3d-vk)
      reg_set "$exe" DllOverrides d3d9 builtin
      reg_set "$exe" Direct3D renderer vulkan
      ;;
    d9vk|d9vk-diag)
      src="$BUNDLED/$D9VK_BUILD/d3d9.dll"
      [ "$name" = "d9vk-diag" ] && src="$BUNDLED/$D9VK_BUILD-diag/d3d9.dll"
      [ -f "$src" ] || die "bundled $src is missing — re-download the toolkit."
      install_managed "$src" "$dir" d3d9.dll
      [ -f "$dir/dxvk.conf" ] || install_managed "$TEMPLATES/dxvk.conf" "$dir" dxvk.conf
      reg_set "$exe" DllOverrides d3d9 native
      reg_del "$exe" Direct3D renderer
      ;;
    dxvk)
      extra="$(profile_dir_arg dxvk "$extra")"
      [ -n "$extra" ] && [ -d "$extra" ] || die "profile dxvk needs an extracted DXVK-MacOS release: '$0 fetch dxvk', or pass the folder, or set BRZ_DXVK_DIR."
      src="$(find_dll "$extra" d3d9.dll)" || die "No 32-bit (i386) d3d9.dll under $extra. The game is 32-bit; the x64 DLL will not load."
      install_managed "$src" "$dir" d3d9.dll
      [ -f "$dir/dxvk.conf" ] || install_managed "$TEMPLATES/dxvk.conf" "$dir" dxvk.conf
      reg_set "$exe" DllOverrides d3d9 native
      reg_del "$exe" Direct3D renderer
      ;;
    dgvoodoo)
      extra="$(profile_dir_arg dgvoodoo "$extra")"
      [ -n "$extra" ] && [ -d "$extra" ] || die "profile dgvoodoo needs an extracted dgVoodoo2 zip: '$0 fetch dgvoodoo', or pass the folder, or set BRZ_DGV_DIR."
      src="$(find "$extra" -path '*/MS/x86/D3D9.dll' -type f 2>/dev/null | head -n 1)"
      [ -n "$src" ] || src="$(find_dll "$extra" D3D9.dll)" || die "No 32-bit D3D9.dll under $extra (expected MS/x86/D3D9.dll)."
      install_managed "$src" "$dir" d3d9.dll
      conf="$TEMPLATES/dgVoodoo.conf"
      [ -f "$dir/dgVoodoo.conf" ] || install_managed "$conf" "$dir" dgVoodoo.conf
      reg_set "$exe" DllOverrides d3d9 native
      reg_del "$exe" Direct3D renderer
      ;;
    *) die "unknown profile '$name' (choose: $PROFILES)" ;;
  esac
  printf '%s\n' "$name" > "$dir/$PROFILE_NAME"
}

profile_blurb() {
  case "$1" in
    wrapper)    printf 'whatever the wrapper Configure toggles select (your current setup)' ;;
    wined3d)    printf 'Wine builtin D3D9 -> OpenGL (correct but slow baseline)' ;;
    wined3d-vk) printf 'Wine builtin D3D9 -> WineD3D Vulkan renderer -> MoltenVK' ;;
    d9vk)       printf 'bundled D9VK %s (16-bit texture fix, async) -> MoltenVK' "$D9VK_BUILD" ;;
    d9vk-diag)  printf 'bundled D9VK %s + D3D9-DIAG logging (evidence run)' "$D9VK_BUILD" ;;
    dxvk)       printf 'metalsharp DXVK-MacOS 3.x d3d9 -> MoltenVK' ;;
    dgvoodoo)   printf 'dgVoodoo2 D3D9 -> D3D11 -> DXMT (Metal); needs DXMT on in Configure' ;;
  esac
}

# ---------------------------------------------------------------------------
# launching

steam_dir() {
  local d
  for d in "$PREFIX/drive_c/Program Files (x86)/Steam" "$PREFIX/drive_c/Program Files/Steam"; do
    [ -f "$d/steam.exe" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# Exports the env used for game and probe runs. $1 = 1 for HUD, $2 = 1 for debug logging.
export_run_env() {
  local hud="${1:-0}" debug="${2:-0}" wlog
  # MoltenVK: force full image-view swizzle so old D3D9 formats (L8, A8L8) can't sample as black.
  # Apple Silicon usually swizzles natively; this rules out the case where it doesn't.
  export MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE="${MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE:-1}"
  # Metal fast-math off while hunting black pixels (NaN propagation); set to 1 if it costs FPS.
  export MVK_CONFIG_FAST_MATH_ENABLED="${MVK_CONFIG_FAST_MATH_ENABLED:-0}"
  export WINEMSYNC="${WINEMSYNC:-1}"
  [ "$hud" = 1 ] && export DXVK_HUD="${DXVK_HUD:-fps,frametimes,drawcalls,pipelines,version,api}"
  if [ "$debug" = 1 ]; then
    # MoltenVK level 3 (info) logs its version once at startup; that tells us which DXVK builds can run
    export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-info}" MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-3}"
    # Under Wine, DXVK only writes a log *file* when DXVK_LOG_PATH is a Windows path;
    # otherwise its lines go to Wine's output, which we capture anyway.
    wlog="$(winpath "$LOGDIR")"
    [ -n "$wlog" ] && export DXVK_LOG_PATH="$wlog"
    export WINEDEBUG="${WINEDEBUG:-err+all,warn+d3d,+loaddll}"
  fi
  if [ -n "${BRZ_MVK_DIR:-}" ]; then
    # experimental: use a different MoltenVK (e.g. the one shipped with DXVK-MacOS)
    export DYLD_LIBRARY_PATH="$BRZ_MVK_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  fi
}

launch_game() { # hud debug -> prints log path
  local hud="$1" debug="$2" sd ts log
  sd="$(steam_dir)" || die "steam.exe not found in the prefix."
  ts="$(date +%Y%m%d-%H%M%S)"
  log="$LOGDIR/launch-$ts.log"
  (
    export_run_env "$hud" "$debug"
    # shellcheck disable=SC2086  # BRZ_STEAM_ARGS is a list of flags
    cd "$sd" && WINEPREFIX="$PREFIX" WINEDEBUG="${WINEDEBUG:--all}" \
      "$WINE" steam.exe ${BRZ_STEAM_ARGS:--silent -nofriendsui -nochatui -noverifyfiles} -applaunch "$APPID" \
      > "$log" 2>&1 &
  )
  printf '%s' "$log"
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
  if [ -n "$WINE" ]; then
    ok "wine         $WINE"
    info "  version      $(WINEPREFIX="$PREFIX" "$WINE" --version 2>/dev/null | head -n 1)"
  else
    warn "wine binary not found"
  fi
  is_mac && info "  size         $(du -sh "$WRAPPER" 2>/dev/null | awk '{print $1}')"
  local mvk
  mvk="$(find "$WRAPPER/Contents" -name 'libMoltenVK.dylib' -type f 2>/dev/null | head -n 1)"
  if [ -n "$mvk" ]; then
    local mvkver=""
    if is_mac && xcode-select -p >/dev/null 2>&1; then
      mvkver="$(otool -L "$mvk" 2>/dev/null | sed -n 2p | sed -n 's/.*current version \([0-9.]*\).*/\1/p')"
    fi
    info "  MoltenVK     ${mvkver:-version unknown (shown in probe/launch logs)}  $mvk"
  fi
  find "$WRAPPER/Contents" -maxdepth 7 \( -iname '*winemetal*' -o -iname 'd3d11.dll' -path '*dxmt*' \) 2>/dev/null | grep -q . && info "  DXMT         present"
  find "$WRAPPER/Contents" -maxdepth 7 -name 'D3DMetal.framework' 2>/dev/null | grep -q . && info "  D3DMetal     present (64-bit DX11/12 only — not used by this game)"
  local sys
  for sys in syswow64 system32; do
    [ -f "$PREFIX/drive_c/windows/$sys/d3d9.dll" ] && info "  $sys/d3d9  $(dll_kind "$PREFIX/drive_c/windows/$sys/d3d9.dll")"
  done
  [ -f "$WRAPPER/Contents/SharedSupport/Logs/LastRunWine.log" ] && info "  last log     $WRAPPER/Contents/SharedSupport/Logs/LastRunWine.log"
  [ -e "$PREFIX/dosdevices/z:" ] || warn "No Z: drive in the prefix — DXVK log files will only appear in the launch log."

  hdr "Game"
  if [ -z "$GAME_DIR" ]; then warn "Game not found in the prefix (looked for $INI_NAME; set BRZ_GAME_DIR/BRZ_GAME_EXE for other games)"; return 0; fi
  info "  dir          $GAME_DIR"
  info "  exe          ${GAME_EXE:-?}$( [ -n "$GAME_EXE" ] && [ -f "$GAME_DIR/$GAME_EXE" ] && printf ' (%s)' "$(pe_arch "$GAME_DIR/$GAME_EXE")")"
  info "  profile      $(cat "$GAME_DIR/$PROFILE_NAME" 2>/dev/null || echo 'none (wrapper defaults)')"
  if [ -n "$INI" ]; then
    local k
    for k in Width Height Depth Fullscreen HardwareTL D3D9On12; do
      info "  ini $k$(printf '%*s' $((10 - ${#k})) '')$(kv_get "$INI" "$k")"
    done
  fi
  local f
  for f in d3d8.dll d3d9.dll d3d11.dll dxgi.dll ddraw.dll; do
    [ -f "$GAME_DIR/$f" ] && info "  game $f$(printf '%*s' $((9 - ${#f})) '') $(dll_kind "$GAME_DIR/$f")"
    [ -f "$GAME_DIR/$f$STASH_SUFFIX" ] && info "  game $f$STASH_SUFFIX (the game's own copy, stashed)"
  done
  for f in dxvk.conf dgVoodoo.conf; do
    [ -f "$GAME_DIR/$f" ] && info "  game has $f"
  done
  # Video cutscenes (FMV) vs in-engine cutscenes need different fixes
  local nbik navi nwmv bink=""
  nbik="$(find "$GAME_DIR" -maxdepth 4 -iname '*.bik' 2>/dev/null | wc -l | tr -d ' ')"
  navi="$(find "$GAME_DIR" -maxdepth 4 -iname '*.avi' 2>/dev/null | wc -l | tr -d ' ')"
  nwmv="$(find "$GAME_DIR" -maxdepth 4 \( -iname '*.wmv' -o -iname '*.mpg' -o -iname '*.mp4' \) 2>/dev/null | wc -l | tr -d ' ')"
  find "$GAME_DIR" -maxdepth 2 -iname 'binkw32.dll' 2>/dev/null | grep -q . && bink=", binkw32.dll present"
  info "  videos       $nbik .bik, $navi .avi, $nwmv .wmv/.mpg/.mp4$bink"
  if [ "$((nbik + navi + nwmv))" -eq 0 ]; then
    info "               (no video files: cutscenes are in-engine, so they lag for the same reason battles do)"
  elif [ "$((navi + nwmv))" -gt 0 ]; then
    info "               (AVI/WMV cutscenes go through Wine's DirectShow/GStreamer: if they stutter or stay black, that is a codec issue, not the renderer)"
  fi
  hdr "Per-game Wine settings ($GAME_EXE)"
  wine_settle
  show_app_reg "$GAME_EXE"
  return 0
}

cmd_identify() { # [files...]
  setup
  if [ $# -gt 0 ]; then
    local f
    for f in "$@"; do info "$f: $(dll_kind "$f")"; done
    return 0
  fi
  local p
  for p in "$PREFIX/drive_c/windows/syswow64/d3d9.dll" "$PREFIX/drive_c/windows/system32/d3d9.dll" \
           "${GAME_DIR:+$GAME_DIR/d3d9.dll}" "$BUNDLED/$D9VK_BUILD/d3d9.dll" "$BUNDLED/$D9VK_BUILD-diag/d3d9.dll"; do
    [ -n "$p" ] && [ -f "$p" ] && info "$p"$'\n'"    $(dll_kind "$p")"
  done
  find "$WRAPPER/Contents/SharedSupport/wine" -path '*i386-windows/d3d9.dll' -type f 2>/dev/null | head -n 1 | while IFS= read -r p; do
    info "$p"$'\n'"    $(dll_kind "$p")"
  done
  return 0
}

cmd_profile() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 profile <$(printf '%s' "$PROFILES" | tr ' ' '|')> [DIR]"
  setup; need_game; need_wine; need_stopped; backup_once
  backup_now "before-$name"
  apply_profile "$GAME_DIR" "$GAME_EXE" "$name" "${2:-}"
  wine_settle
  ok "profile $name: $(profile_blurb "$name")"
  case "$name" in
    dgvoodoo) warn "In the wrapper's Configure app: turn DXMT ON and DXVK/D9VK OFF, or D3D11 falls back to OpenGL." ;;
    d9vk|d9vk-diag|dxvk) info "  Tip: '$0 launch --hud' shows the DXVK HUD top-left when it is really active." ;;
  esac
}

cmd_ini() {
  setup; need_game
  [ -n "$INI" ] || die "$INI_NAME not found in $GAME_DIR (launch the game once to create it, or set BRZ_INI_NAME)."
  case "${1:-show}" in
    show) tr -d '\r' < "$INI" | grep -v '^[[:space:]]*$' ;;
    get)  [ $# -ge 2 ] || die "usage: $0 ini get KEY"; kv_get "$INI" "$2" ;;
    set)
      [ $# -ge 3 ] || die "usage: $0 ini set KEY VALUE"
      backup_once; backup_now "ini-$2"
      kv_upsert "$INI" "$2" "$3" "$(ini_section_for "$2")"
      ok "$2 = $(kv_get "$INI" "$2")"
      ;;
    *) die "usage: $0 ini [show|get KEY|set KEY VALUE]" ;;
  esac
}

cmd_conf() { # edit dxvk.conf or dgVoodoo.conf in the game dir
  setup; need_game
  local which="${1:-}" file section=""
  case "$which" in
    dxvk) file="$GAME_DIR/dxvk.conf" ;;
    dgvoodoo) file="$GAME_DIR/dgVoodoo.conf"; section="DirectX" ;;
    *) die "usage: $0 conf <dxvk|dgvoodoo> [show|set KEY VALUE]" ;;
  esac
  [ -f "$file" ] || die "$file not found — apply the matching profile first."
  case "${2:-show}" in
    show) grep -Ev '^[[:space:]]*(#|;|$)' "$file" ;;
    set)
      [ $# -ge 4 ] || die "usage: $0 conf $which set KEY VALUE"
      backup_now "conf-$3"
      kv_upsert "$file" "$3" "$4" "$section"
      ok "$3 = $(kv_get "$file" "$3")"
      ;;
    *) die "usage: $0 conf $which [show|set KEY VALUE]" ;;
  esac
}

cmd_launch() {
  setup; need_game; need_wine
  local hud=0 debug=0 a log
  for a in "$@"; do
    case "$a" in
      --hud) hud=1 ;;
      --debug) debug=1 ;;
      *) die "usage: $0 launch [--hud] [--debug]" ;;
    esac
  done
  if wine_running; then
    warn "Steam/Wine is already running: -applaunch would go to that instance and these env vars would NOT reach the game."
    confirm "Launch anyway?" || exit 1
  fi
  log="$(launch_game "$hud" "$debug")"
  ok "Started Steam → app $APPID. Log: $log"
  info "  When you have quit the game: '$0 analyze' reads this log."
}

cmd_retina() { # on|off|default — wrapper-wide, same keys as Configure's Retina option
  setup; need_game; need_wine; need_stopped; backup_once
  case "${1:-}" in
    on|off|default) retina_set "$1" ;;
    *) die "usage: $0 retina on|off|default   (wrapper-wide, like Configure's Retina option; 'off' is the usual black-screen fix)" ;;
  esac
  wine_settle
  ok "Retina mode: ${1} (wrapper-wide; backed up, 'restore' undoes it)"
}

cmd_kill() {
  setup; need_wine
  [ -n "$WINESERVER" ] || die "wineserver not found next to $WINE"
  WINEPREFIX="$PREFIX" "$WINESERVER" -k && ok "wineserver killed for this prefix"
}

# ---------------------------------------------------------------------------
# probe: run brz-probe.exe under several renderers and compare

cmd_probe() {
  setup; need_wine
  [ -f "$PROBE_EXE" ] || die "probe not found at $PROBE_EXE"
  local profiles="" quick=0 a
  for a in "$@"; do
    case "$a" in
      --quick) quick=1 ;;
      -*) die "usage: $0 probe [--quick] [profile ...]" ;;
      *) profiles="$profiles $a" ;;
    esac
  done
  if [ -z "$profiles" ]; then
    for a in wrapper wined3d d9vk wined3d-vk dxvk dgvoodoo; do
      profile_available "$a" && profiles="$profiles $a"
    done
  fi
  need_stopped

  local pdir="$PREFIX/drive_c/brz-probe" ts outdir p args ran="" rc last why pat
  ts="$(date +%Y%m%d-%H%M%S)"
  outdir="$LOGDIR/probe-$ts"
  mkdir -p "$pdir" "$outdir"
  cp "$PROBE_EXE" "$pdir/brz-probe.exe" || die "could not copy the probe into the prefix"
  args="--full --bench --frames 40 --draws 1000 --timeout 60"
  [ "$quick" = 1 ] && args="--bench --frames 30 --draws 800 --timeout 45"

  hdr "Probe run $ts:$profiles"
  for p in $profiles; do
    if ! profile_available "$p"; then
      warn "skipping $p (needs a download: '$0 fetch $( [ "$p" = dgvoodoo ] && echo dgvoodoo || echo dxvk )')"
      continue
    fi
    info "→ $p: $(profile_blurb "$p")"
    ran="$ran $p"
    [ "$p" = dgvoodoo ] && warn "  dgvoodoo needs DXMT switched on in the wrapper's Configure, or its D3D11 runs on OpenGL."
    apply_profile "$pdir" brz-probe.exe "$p"
    wine_settle
    rm -f "$pdir/brz-probe-$p.txt"
    # stderr of the subshell goes to the log too, so a segfault notice lands there, not on screen
    # shellcheck disable=SC2086
    ( export_run_env 0 1
      cd "$pdir" && WINEPREFIX="$PREFIX" WINEDEBUG="${WINEDEBUG:--all}" "$WINE" brz-probe.exe $args --label "$p" ) \
      > "$outdir/$p.stdout.log" 2>&1
    rc=$?
    if [ -f "$pdir/brz-probe-$p.txt" ]; then
      cp "$pdir/brz-probe-$p.txt" "$outdir/$p.txt"
      if ! grep -qE '^summary' "$outdir/$p.txt"; then
        # Died below the probe (e.g. an assertion inside Wine's Vulkan bridge): say where and why.
        last="$(awk '
          /^== /     { m = $0; gsub(/^== | ==$/, "", m); n = "start of " m }
          /^  [A-Z]/ { n = substr($0, 13, 34); sub(/ +$/, "", n) }
          /^phase /  { n = "the " substr($0, 12) }
          END { print n }' "$outdir/$p.txt")"
        why=""
        for pat in 'Assertion failed|_wassert' 'No adapters found' 'terminate called' 'Unhandled' 'Segmentation fault'; do
          why="$(grep -E "$pat" "$outdir/$p.stdout.log" | tail -n 1 | cut -c1-160)"
          [ -n "$why" ] && break
        done
        case "$why" in *"Segmentation fault"*) why="Segmentation fault (the Wine process crashed)" ;; esac
        printf '\nDIED after: %s (exit %s) %s\n' "${last:-device creation}" "$rc" "$why" >> "$outdir/$p.txt"
      fi
      info "  $(grep -E '^summary|^(CRASH|TIMEOUT|ABORT|DIED) ' "$outdir/$p.txt" | tail -n 1)"
    else
      printf 'no result file — the probe did not start (exit %s, see %s.stdout.log)\n' "$rc" "$p" > "$outdir/$p.txt"
      warn "  $p: probe produced no result (see $outdir/$p.stdout.log)"
    fi
  done
  wine_settle
  # shellcheck disable=SC2086  # ran is a word list of profile names
  probe_matrix "$outdir" $ran | tee "$outdir/matrix.txt"
  ok "Saved: $outdir (matrix.txt + one file per renderer)"
}

# Builds a test x renderer table from the per-renderer result files in DIR
# (columns in the given order, or every result file when no names are given).
probe_matrix() { # dir [name ...]
  local dir="$1" f files="" n
  shift
  if [ $# -gt 0 ]; then
    for n in "$@"; do [ -f "$dir/$n.txt" ] && files="$files $dir/$n.txt"; done
  else
    for f in "$dir"/*.txt; do
      case "$f" in */matrix.txt) continue ;; esac
      [ -f "$f" ] && files="$files $f"
    done
  fi
  [ -n "$files" ] || { warn "no probe results in $dir"; return 0; }
  # shellcheck disable=SC2086
  awk '
    FNR == 1 {
      n = split(FILENAME, parts, "/"); col = parts[n]; sub(/\.txt$/, "", col)
      cols[++ncol] = col; mode = "HW"
    }
    /^== / {
      if ($0 ~ /SWVP/) mode = "SW"; else if ($0 ~ /On12/) mode = "12"; else mode = "HW"
      next
    }
    /^  [A-Z]/ {
      status = substr($0, 3, 9); sub(/ +$/, "", status)
      name = substr($0, 13, 34); sub(/ +$/, "", name)
      key = mode ": " name
      if (!(key in seen)) { seen[key] = 1; rows[++nrow] = key }
      short = status
      if (status == "PASS") short = "ok"; else if (status == "NOT DRAWN") short = "none"
      else if (status == "SKIP") short = "skip"; else if (status == "WRONG") short = "wrong"
      else if (status == "ERROR") short = "err"
      cell[key SUBSEP col] = short
      if (status != "PASS" && status != "SKIP") bad[col]++
      next
    }
    /^bench/ { if (match($0, /\([0-9]+ fps\)/)) fps[col] = substr($0, RSTART + 1, RLENGTH - 2) }
    /^(CRASH|TIMEOUT|ABORT) during|^DIED after/ { abort[col] = $0 }
    /^no result file/ { abort[col] = "did not start" }
    END {
      w = 40
      printf "%-" w "s", "test"
      for (c = 1; c <= ncol; c++) printf " %-11s", cols[c]
      printf "\n"
      for (r = 1; r <= nrow; r++) {
        line = sprintf("%-" w "s", rows[r]); interesting = 0
        for (c = 1; c <= ncol; c++) {
          v = cell[rows[r] SUBSEP cols[c]]; if (v == "") v = "-"
          if (v != "ok" && v != "-" && v != "skip") interesting = 1
          line = line sprintf(" %-11s", v)
        }
        if (interesting || ENVIRON["BRZ_MATRIX_ALL"] == "1") print line
      }
      printf "%-" w "s", "FAILED (black/none/wrong/err)"
      for (c = 1; c <= ncol; c++) printf " %-11s", (bad[cols[c]] + 0) (abort[cols[c]] != "" ? "+died" : "")
      printf "\n%-" w "s", "benchmark (higher is better)"
      for (c = 1; c <= ncol; c++) printf " %-11s", (fps[cols[c]] != "" ? fps[cols[c]] : "-")
      printf "\n"
      for (c = 1; c <= ncol; c++) if (abort[cols[c]] != "") printf "%s: %s\n", cols[c], abort[cols[c]]
      printf "(rows where every renderer passed are hidden; BRZ_MATRIX_ALL=1 shows them)\n"
    }
  ' $files
}

# ---------------------------------------------------------------------------
# analyze: match known signatures in Wine / DXVK / MoltenVK / probe logs

analyze_files() { # files...
  awk '
    # does the C= or A= part of one stage segment actually consume a TEXTURE argument?
    function uses_texture(seg, which,   m, op, args, a1, a2, parts) {
      if (!match(seg, which "=[A-Z0-9_]+\\([^)]*\\)")) return 0
      m = substr(seg, RSTART + 2, RLENGTH - 2)
      op = m; sub(/\(.*/, "", op)
      args = m; sub(/^[^(]*\(/, "", args); sub(/\)$/, "", args)
      split(args, parts, ","); a1 = parts[1]; a2 = parts[2]
      if (op == "DISABLE") return 0
      if (op == "SELECTARG1") return (a1 ~ /TEXTURE/)
      if (op == "SELECTARG2") return (a2 ~ /TEXTURE/)
      if (op == "BLENDTEXTUREALPHA" || op == "BLENDTEXTUREALPHAPM") return 1
      return (a1 ~ /TEXTURE/ || a2 ~ /TEXTURE/)
    }
    function add(sev, msg, ex,   k) {
      k = sev "|" msg
      if (!(k in count)) { order[++n] = k; example[k] = ex }
      count[k]++
    }
    {
      l = $0; sub(/\r$/, "", l)
      if (l ~ /D3D9-DIAG: texture fmt=/) {
        t = l; sub(/.*texture fmt=D3D9Format::/, "", t); f = t; sub(/ .*/, "", f)
        v = t; sub(/.*-> vk=/, "", v); sub(/ .*/, "", v)
        cv = t; sub(/.*conversion=/, "", cv); sub(/ .*/, "", cv)
        p = t; sub(/.*pool=/, "", p); sub(/ .*/, "", p)
        tk = f " -> " v (cv != "0" ? " (converted)" : "")
        if (!(tk in texseen)) { texseen[tk] = 1; texlist[++ntex] = tk }
        if (l ~ /UNSUPPORTED/) add("BAD", "game created a texture in a format this D3D9 layer cannot map (" f ")", l)
        next
      }
      if (l ~ /D3D9-DIAG: CheckDeviceFormat .*NOTAVAILABLE/) {
        f = l; sub(/.*fmt=D3D9Format::/, "", f); sub(/ .*/, "", f)
        if (!(f in naseen)) { naseen[f] = 1; nalist = nalist " " f }
        next
      }
      if (l ~ /D3D9-DIAG: FF PS /) {
        ffps++
        nst = split(l, segs, / \| /)
        for (si = 2; si <= nst; si++) {
          sg = segs[si]
          if (sg !~ / tex=0/) continue
          # an unbound texture reads (0,0,0,1): black colour, but alpha = 1, so only colour use matters
          if (uses_texture(sg, "C"))
            add("BAD", "a fixed-function stage reads TEXTURE but no texture is bound -> D9VK/DXVK returns black (texture failed to create or was never set)", l)
        }
        if (l ~ /TFACTOR/) tf = 1
        next
      }
      if (l ~ /D3D9-DIAG: FF VS /) { ffvs++; if (l ~ /lighting=1/) fflit = 1; if (l ~ /positionT=1/) ffpret = 1; next }
      if (l ~ /D3D9-DIAG: device created/) {
        if (l ~ /SOFTWARE_VP/) add("INFO", "game created a SOFTWARE vertex processing device (HardwareTL=0 path)", l)
        else if (l ~ /MIXED_VP/) add("INFO", "game created a MIXED vertex processing device", l)
        else add("INFO", "game created a HARDWARE vertex processing device (HardwareTL=1 path)", l)
        if (l ~ /nullDescriptor=no/) add("WARN", "Vulkan driver lacks nullDescriptor: unbound textures may not read as D3D9 expects", l)
        next
      }
      if (l ~ /D3D9-DIAG: draw path/) { add("INFO", "draw path: " substr(l, index(l, "draw path") + 10), l); next }

      if (l ~ /DXVK: v[0-9]/) { v = l; sub(/.*DXVK: /, "", v); add("INFO", "DXVK/D9VK loaded: " v, l) }
      if (l ~ /Software Promotion/) add("INFO", "16-bit texture formats are being promoted to 32-bit (fixed D9VK build)", l)
      if (l ~ /9On12 functionality is unimplemented/) add("WARN", "game asked for D3D9On12 (ini D3D9On12=1); the layer ignores it — try D3D9On12=0", l)
      if (l ~ /Direct3DCreate9On12 is not exported/) add("WARN", "this d3d9.dll has no Direct3DCreate9On12 — set D3D9On12=0 in Battle_Realms.ini", l)
      if (l ~ /^err:.*D3D9|err: +D3D9|D3D9DeviceEx::.*[Ff]ailed|Failed to create (image|texture|surface)/) add("BAD", "D3D9 layer reported an error", l)
      if (l ~ /DxvkMemoryAllocator.*[Ff]ailed|Memory allocation failed|VK_ERROR_OUT_OF_DEVICE_MEMORY/) add("BAD", "GPU memory allocation failed", l)
      if (l ~ /VK_ERROR_DEVICE_LOST/) add("BAD", "Vulkan device lost (GPU crash/hang under MoltenVK)", l)
      if (l ~ /\[mvk-error\]/) {
        if (l ~ /[Ss]hader|MSL|SPIR-V|SPIRV/) add("BAD", "MoltenVK could not translate a shader -> those draws are dropped", l)
        else if (l ~ /[Ff]ormat/) add("BAD", "MoltenVK format error", l)
        else add("BAD", "MoltenVK error", l)
      }
      if (l ~ /\[mvk-warn\]/) add("WARN", "MoltenVK warning", l)
      if (l ~ /MoltenVK version [0-9]+\.[0-9]+\.[0-9]+/) {
        v = l; sub(/.*MoltenVK version /, "", v); sub(/[^0-9.].*/, "", v)
        add("INFO", "MoltenVK " v, l)
        split(v, mv, ".")
        if (mv[1] + 0 == 1 && mv[2] + 0 < 3)
          add("WARN", "MoltenVK " v " is older than 1.3.0: DXVK 3.x builds (metalsharp) will find no adapter; use the bundled d9vk, or BRZ_MVK_DIR with the MoltenVK from the DXVK-MacOS release", l)
      }
      if (l ~ /No adapters found/) add("BAD", "DXVK found no usable Vulkan device (driver missing a required feature) -> this DXVK build cannot run here", l)
      if (l ~ /Skipping: Device does not support required feature/) { v = l; sub(/.*required feature /, "", v); add("BAD", "Vulkan driver lacks " v " which this DXVK build requires", l) }
      if (l ~ /^ABORT during/) add("BAD", "probe " l, l)
      if (l ~ /err:module:import_dll|Library [^ ]+ \(which is needed by|could not load .*\.dll/) add("BAD", "a DLL failed to load", l)
      if (l ~ /Unhandled exception|Unhandled page fault|unhandled exception|starting debugger/) add("BAD", "a Windows program crashed", l)
      if (l ~ /^(CRASH|TIMEOUT) during/) add("BAD", "probe " l, l)
      if (l ~ /terminate called after throwing/) add("BAD", "a C++ D3D layer aborted (see the lines just before it)", l)
      if (l ~ /winevulkan/ && l ~ /_wassert|Assertion failed/) { v = l; sub(/.*&& \\?"/, "", v); sub(/\\?".*/, "", v); add("BAD", "Wine Vulkan bridge aborted on a failed driver call (" v ") -> GPU-driver/MoltenVK limitation or Wine bug; try another renderer", l) }
      if (l ~ /^DIED after/) { add("BAD", "probe " l, l); next }
      if (l ~ /Segmentation fault/) add("BAD", "the Wine process crashed (segmentation fault)", l)
      if (l ~ /^caps .* 0 texture stages/) add("WARN", "this D3D9 layer reports 0 fixed-function texture stages (WineD3D Vulkan renderer without fixed-function support) -> unusable for Battle Realms", l)
      if (l ~ /Could not find support(ed|et) display mode|Display Initiali[sz]e/) add("BAD", "game display-mode error -> toggle HardwareTL, use a listed resolution, or Fullscreen=0", l)
      if (l ~ /trace:loaddll.*d3d9\.dll/) { v = l; sub(/.*Loaded /, "", v); add("INFO", "d3d9.dll loaded: " v, l) }
      if (l ~ /wined3d|WineD3D/ && l ~ /err:|fixme:d3d/) add("INFO", "WineD3D (Wine builtin) messages present -> builtin d3d9 was used", l)
      if (l ~ /^  (BLACK|NOT DRAWN|WRONG|ERROR) /) add("BAD", "probe: " substr(l, 3), l)
      if (l ~ /^summary +[0-9]+ passed/) add("INFO", "probe " l, l)
    }
    END {
      if (ntex) {
        s = ""; for (i = 1; i <= ntex; i++) s = s (i > 1 ? ", " : "") texlist[i]
        add("INFO", "texture formats the game used: " s, "")
      }
      if (nalist != "") add("INFO", "formats the game probed but the layer refused:" nalist, "")
      if (ffps || ffvs) add("INFO", sprintf("fixed-function shaders: %d vertex / %d pixel keys%s%s%s", ffvs, ffps, fflit ? ", uses D3D lighting" : "", ffpret ? ", uses pre-transformed vertices" : "", tf ? ", uses TFACTOR (team colour)" : ""), "")
      split("BAD WARN INFO", sevs, " ")
      total = 0
      for (s = 1; s <= 3; s++) {
        printed = 0
        for (i = 1; i <= n; i++) {
          split(order[i], kv, "|"); if (kv[1] != sevs[s]) continue
          if (!printed) { printf "\n%s\n", (sevs[s] == "BAD" ? "Problems" : sevs[s] == "WARN" ? "Warnings" : "Facts"); printed = 1 }
          msg = substr(order[i], length(kv[1]) + 2)
          printf "  - %s%s\n", msg, (count[order[i]] > 1 ? sprintf("  (x%d)", count[order[i]]) : "")
          if (sevs[s] != "INFO" && example[order[i]] != "") printf "      e.g. %s\n", substr(example[order[i]], 1, 220)
          total++
        }
      }
      if (!total) print "  nothing recognised — send me the raw log"
    }
  ' "$@"
}

cmd_analyze() { # [files...]
  setup
  local files="" f
  if [ $# -gt 0 ]; then
    for f in "$@"; do [ -f "$f" ] && files="$files$f"$'\n'; done
  else
    # shellcheck disable=SC2012  # our own timestamped names
    f="$(ls -t "$LOGDIR"/launch-*.log 2>/dev/null | head -n 1)"; [ -n "$f" ] && files="$files$f"$'\n'
    for f in "$WRAPPER/Contents/SharedSupport/Logs/LastRunWine.log" "$LOGDIR"/*_d3d9.log "${GAME_DIR:-/nonexistent}"/*_d3d9.log; do
      [ -f "$f" ] && files="$files$f"$'\n'
    done
    # shellcheck disable=SC2012
    f="$(ls -td "$LOGDIR"/probe-* 2>/dev/null | head -n 1)"
    if [ -n "$f" ]; then
      for f in "$f"/*.txt; do case "$f" in */matrix.txt) ;; *) [ -f "$f" ] && files="$files$f"$'\n' ;; esac; done
    fi
  fi
  [ -n "$files" ] || die "no logs found yet — run '$0 launch --debug' (or '$0 probe') first."
  hdr "Analyzing"
  printf '%s' "$files" | sed 's/^/  /'
  local IFS=$'\n'
  # shellcheck disable=SC2086
  analyze_files $files
}

# ---------------------------------------------------------------------------
# fetch: download renderer packages (the Mac has normal internet access)

github_asset_url() { # owner/repo tag-or-latest regex
  local api
  if [ "$2" = latest ]; then api="https://api.github.com/repos/$1/releases/latest"
  else api="https://api.github.com/repos/$1/releases/tags/$2"; fi
  curl -fsSL "$api" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(http[^"]*\)"/\1/' | grep -E "$3" | head -n 1
}

extract_to() { # archive dest
  mkdir -p "$2"
  case "$1" in
    *.zip) if is_mac; then ditto -x -k "$1" "$2"; else unzip -q -o "$1" -d "$2"; fi ;;
    *.tar.gz|*.tgz) tar -xzf "$1" -C "$2" ;;
    *.tar.xz) tar -xJf "$1" -C "$2" ;;
    *) die "don't know how to extract $1" ;;
  esac
}

cmd_fetch() {
  setup
  local what="${1:-}" ver url name dest
  case "$what" in
    dxvk)
      url="$(github_asset_url metalsharp/DXVK-MacOS "${2:-latest}" '\.(tar\.gz|tar\.xz|tgz|zip)$')"
      [ -n "$url" ] || die "could not find a DXVK-MacOS release asset (check https://github.com/metalsharp/DXVK-MacOS/releases)"
      name="$(basename "$url")"; dest="$DOWNLOADS/dxvk-macos/${name%%.*}"
      ;;
    dgvoodoo)
      ver="${2:-2.87.5}"
      url="$(github_asset_url dege-diosg/dgVoodoo2 "v$ver" '\.zip$')"
      [ -n "$url" ] || url="https://github.com/dege-diosg/dgVoodoo2/releases/download/v$ver/dgVoodoo2_$(printf '%s' "$ver" | sed 's/^2\.//; s/\./_/g').zip"
      name="$(basename "$url")"; dest="$DOWNLOADS/dgvoodoo/$ver"
      ;;
    *) die "usage: $0 fetch dxvk [TAG] | fetch dgvoodoo [VERSION, default 2.87.5; also try 2.79.3, 2.54]" ;;
  esac
  info "Downloading $url"
  mkdir -p "$DOWNLOADS/tmp"
  curl -fL --retry 3 -o "$DOWNLOADS/tmp/$name" "$url" || die "download failed"
  info "  sha256 $(sha256 "$DOWNLOADS/tmp/$name")"
  extract_to "$DOWNLOADS/tmp/$name" "$dest"
  rm -f "$DOWNLOADS/tmp/$name"
  ok "Extracted to $dest (probe/triage/profile pick it up automatically)"
  local d9
  d9="$(find_dll "$dest" d3d9.dll || true)"
  [ -n "$d9" ] && info "  32-bit d3d9.dll: $d9"$'\n'"    $(dll_kind "$d9")"
  return 0
}

# ---------------------------------------------------------------------------
# triage: guided, one change per round, answers recorded

TRIAGE_STEPS="baseline d9vk d9vk-on12off d9vk-htl d9vk-diag dxvk dgvoodoo wined3d-vk wined3d"

triage_describe() {
  case "$1" in
    baseline)     printf 'Your current setup, launched with diagnostics (reproduce + capture logs).' ;;
    d9vk)         printf 'Bundled D9VK with the June-2026 16-bit texture fix (A4R4G4B4/A1R5G5B5/R5G6B5).' ;;
    d9vk-on12off) printf 'Same, plus D3D9On12=0 in Battle_Realms.ini (no D3D9-on-12 request).' ;;
    d9vk-htl)     printf 'Same, plus HardwareTL flipped (game lighting on CPU vs D3D lighting on GPU).' ;;
    d9vk-diag)    printf 'Diagnostic D9VK build: logs every texture format and blend stage the game uses.' ;;
    dxvk)         printf 'metalsharp DXVK-MacOS 3.x (newer D3D9 code, de-aliased samplers; no async).' ;;
    dgvoodoo)     printf 'dgVoodoo2 -> D3D11 -> DXMT (Metal). No Vulkan/MoltenVK at all.' ;;
    wined3d-vk)   printf 'Wine builtin D3D9 with its Vulkan renderer (separates DXVK bugs from MoltenVK bugs).' ;;
    wined3d)      printf 'Wine builtin D3D9 on OpenGL: the slow-but-correct reference.' ;;
  esac
}

triage_profile_for() {
  case "$1" in
    baseline) printf 'wrapper' ;;
    d9vk|d9vk-on12off|d9vk-htl) printf 'd9vk' ;;
    *) printf '%s' "$1" ;;
  esac
}

triage_apply() { # step
  local step="$1" htl
  apply_profile "$GAME_DIR" "$GAME_EXE" "$(triage_profile_for "$step")"
  case "$step" in
    d9vk-on12off|d9vk-htl|d9vk-diag|dxvk|dgvoodoo|wined3d-vk|wined3d)
      [ -n "$INI" ] && kv_upsert "$INI" D3D9On12 0 VideoState ;;
  esac
  if [ "$step" = d9vk-htl ] && [ -n "$INI" ]; then
    htl="$(kv_get "$INI" HardwareTL)"
    if [ "$htl" = 1 ]; then kv_upsert "$INI" HardwareTL 0 VideoState; else kv_upsert "$INI" HardwareTL 1 VideoState; fi
  fi
  wine_settle
}

# shellcheck disable=SC2086  # TRIAGE_STEPS is a word list
nth_step() { printf '%s\n' $TRIAGE_STEPS | sed -n "${1}p"; }

cmd_triage() {
  setup; need_game; need_wine
  local idx=1 total step a_menu a_screen a_units a_fps a_cut log res best="" best_fps=0 screen_fix_done=0 dl
  if [ "${1:-}" = "--reset" ]; then rm -f "$TRIAGE_STATE"; ok "triage reset"; fi
  [ -f "$TRIAGE_STATE" ] && idx="$(cat "$TRIAGE_STATE")"
  # shellcheck disable=SC2086
  total="$(printf '%s\n' $TRIAGE_STEPS | wc -l | tr -d ' ')"
  backup_once
  hdr "Battle Realms triage — one change per round"
  info "Each round I set up one configuration and launch the game with diagnostics. You play"
  info "~3 minutes (a skirmish with a big fight, plus a cutscene if you can), quit, and answer 5 questions."
  info "Answers go to $TRIAGE_LOG. Ctrl-C any time; '$0 triage' resumes, '$0 triage --reset' starts over."
  [ -f "$TRIAGE_LOG" ] || printf 'time|step|profile|HardwareTL|D3D9On12|Fullscreen|reached_menu|screen_black|units_black|fps|cutscenes_ok|launch_log\n' > "$TRIAGE_LOG"

  while [ "$idx" -le "$total" ]; do
    step="$(nth_step "$idx")"
    printf '%s\n' "$idx" > "$TRIAGE_STATE"
    hdr "Round $idx/$total: $step"
    info "  $(triage_describe "$step")"
    if [ "$step" = d9vk-diag ] && [ -n "$best" ]; then
      info "  skipped: an earlier round already rendered correctly, no evidence run needed"
      idx=$((idx + 1)); continue
    fi
    if ! profile_available "$(triage_profile_for "$step")"; then
      dl="dxvk"; [ "$step" = dgvoodoo ] && dl="dgvoodoo"
      if confirm "  This round needs a download ($dl). Fetch it now?"; then
        ( cmd_fetch "$dl" ) || warn "  download failed"
      fi
      if ! profile_available "$(triage_profile_for "$step")"; then
        warn "  skipping $step"; idx=$((idx + 1)); continue
      fi
    fi
    if [ "$step" = dgvoodoo ]; then
      warn "  Open the wrapper's Configure app: DXMT ON, DXVK/D9VK OFF. Close it again."
      confirm "  Done?" || { warn "  skipping dgvoodoo"; idx=$((idx + 1)); continue; }
    fi
    confirm "  Apply this setup and launch the game?" || { info "  stopped (resume with '$0 triage')"; return 0; }
    triage_apply "$step"
    log="(not launched)"
    if [ "${BRZ_TRIAGE_NOLAUNCH:-0}" != 1 ]; then
      need_stopped
      log="$(launch_game 1 1)"
      info "  Launched (log: $log). Play, then QUIT the game and Steam, then come back here."
    fi
    ask "  Press Enter when you've quit the game…" "" >/dev/null
    a_menu="$(ask '  Did the game reach the main menu? (y/n)' y)"
    a_screen="$(ask '  Was the whole screen black? (y/n)' n)"
    a_units="$(ask '  Were units/buildings black? (y/n/?)' '?')"
    a_fps="$(ask '  Typical FPS in the big fight (number from the HUD, or ?)' '?')"
    a_cut="$(ask '  Were cutscenes smooth? (y/n/?)' '?')"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$(date +%Y-%m-%dT%H:%M)" "$step" "$(triage_profile_for "$step")" \
      "$( [ -n "$INI" ] && kv_get "$INI" HardwareTL)" "$( [ -n "$INI" ] && kv_get "$INI" D3D9On12)" \
      "$( [ -n "$INI" ] && kv_get "$INI" Fullscreen)" "$a_menu" "$a_screen" "$a_units" \
      "$a_fps" "$a_cut" "$log" >> "$TRIAGE_LOG"
    if [ -f "$log" ]; then
      analyze_files "$log" > "$LOGDIR/triage-$idx-$step.analysis.txt" 2>&1
      info "  log analysis: $LOGDIR/triage-$idx-$step.analysis.txt"
      grep -A1 '^Problems' "$LOGDIR/triage-$idx-$step.analysis.txt" | tail -n 1 | sed 's/^/  /'
    fi

    if [ "$a_screen" = y ] && [ "$screen_fix_done" = 0 ] && [ -n "$INI" ]; then
      screen_fix_done=1
      warn "  Black screen = presentation problem. Repeating this round windowed (Fullscreen=0, Retina off)."
      kv_upsert "$INI" Fullscreen 0 VideoState
      retina_set off
      wine_settle
      info "  Retina mode is now OFF (wrapper-wide). If still black, set Width/Height to your display's scaled size."
      continue                                   # same idx again
    fi
    res="no"
    [ "$a_menu" = y ] && [ "$a_screen" = n ] && [ "$a_units" = n ] && res="yes"
    if [ "$res" = yes ]; then
      [ -z "$best" ] && best="$step"
      case "$a_fps" in
        ''|*[!0-9]*) ;;
        *) if [ "$a_fps" -gt "$best_fps" ]; then best_fps="$a_fps"; best="$step"; fi
           if [ "$a_fps" -ge 45 ]; then ok "  Correct image at ${a_fps} FPS — this is the configuration to keep."; break; fi ;;
      esac
      info "  Correct image. Continuing to look for a faster one…"
    fi
    idx=$((idx + 1))
  done
  rm -f "$TRIAGE_STATE"
  hdr "Triage summary"
  column -s'|' -t < "$TRIAGE_LOG" 2>/dev/null || cat "$TRIAGE_LOG"
  if [ -n "$best" ]; then
    ok "Best correct configuration: $best ($(triage_describe "$best"))"
    info "  Re-apply it any time with: $0 profile $(triage_profile_for "$best")  (ini values are in the table above)"
  else
    warn "No round produced a correct image. Run '$0 report' and send me the file — the diag round tells us why."
  fi
}

# ---------------------------------------------------------------------------
# report: one markdown file with everything needed to debug remotely

# shellcheck disable=SC2016  # the backticks below are literal markdown fences
cmd_report() {
  setup
  local ts out latest
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$BRZ_HOME/report-$ts.md"
  {
    printf '# brz-mac report %s\n\n' "$ts"
    printf 'brz-mac %s\n\n## doctor\n\n```\n' "$BRZ_VERSION"
    cmd_doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    printf '```\n\n## %s\n\n```\n' "$INI_NAME"
    [ -n "$INI" ] && tr -d '\r' < "$INI"
    printf '```\n\n## dxvk.conf (active lines)\n\n```\n'
    [ -n "$GAME_DIR" ] && [ -f "$GAME_DIR/dxvk.conf" ] && grep -Ev '^[[:space:]]*(#|$)' "$GAME_DIR/dxvk.conf"
    printf '```\n\n## latest probe matrix\n\n```\n'
    # shellcheck disable=SC2012
    latest="$(ls -td "$LOGDIR"/probe-* 2>/dev/null | head -n 1)"
    [ -n "$latest" ] && [ -f "$latest/matrix.txt" ] && cat "$latest/matrix.txt"
    printf '```\n\n## triage log\n\n```\n'
    [ -f "$TRIAGE_LOG" ] && cat "$TRIAGE_LOG"
    printf '```\n\n## bench.csv\n\n```\n'
    [ -f "$BENCH_CSV" ] && cat "$BENCH_CSV"
    printf '```\n\n## log analysis\n\n```\n'
    cmd_analyze 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    printf '```\n'
  } > "$out" 2>&1
  ok "Report: $out"
  info "  Send me this file (and the zip from '$0 logs' if I ask for raw logs)."
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
  ls -t "$LOGDIR"/*.log 2>/dev/null | head -n 8 | while IFS= read -r f; do cp -p "$f" "$out/"; done
  # shellcheck disable=SC2012
  ls -td "$LOGDIR"/probe-* 2>/dev/null | head -n 1 | while IFS= read -r d; do cp -Rp "$d" "$out/"; done
  [ -f "$BENCH_CSV" ] && cp -p "$BENCH_CSV" "$out/"
  [ -f "$TRIAGE_LOG" ] && cp -p "$TRIAGE_LOG" "$out/"
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
  [ -f "$BENCH_CSV" ] || printf 'date,profile,HardwareTL,D3D9On12,scenario,avg_fps,min_fps,units_ok,cutscenes_ok,notes\n' > "$BENCH_CSV"
  local profile htl on12 notes
  profile="$(cat "$GAME_DIR/$PROFILE_NAME" 2>/dev/null || echo wrapper)"
  htl="$( [ -n "$INI" ] && kv_get "$INI" HardwareTL )"
  on12="$( [ -n "$INI" ] && kv_get "$INI" D3D9On12 )"
  notes="$(printf '%s' "${6:-}" | tr -d '",')"
  printf '%s,%s,%s,%s,"%s",%s,%s,%s,%s,"%s"\n' "$(date +%Y-%m-%dT%H:%M)" "$profile" "$htl" "$on12" \
    "$(printf '%s' "$1" | tr -d '",')" "$2" "$3" "$4" "$5" "$notes" >> "$BENCH_CSV"
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
           "$LOGDIR" "$DOWNLOADS"; do
    [ -e "$p" ] && printf '  %-8s %s\n' "$(du -sh "$p" 2>/dev/null | awk '{print $1}')" "$p"
  done
  [ "${1:-}" = "--clean" ] || { info "  (run '$0 disk --clean' to delete Steam download/shader/http caches and logs older than 7 days)"; return 0; }
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
  confirm "Restore $INI_NAME, user.reg and game-dir DLLs to the state before brz-mac first ran?" || exit 1
  wine_settle      # a lingering wineserver would overwrite user.reg on exit
  remove_managed "$GAME_DIR"
  [ -f "$stamp/$INI_NAME" ] && [ -n "$INI" ] && cp -p "$stamp/$INI_NAME" "$INI"
  [ -f "$stamp/user.reg" ] && cp -p "$stamp/user.reg" "$PREFIX/user.reg"
  local f
  for f in d3d8.dll d3d9.dll d3d11.dll dxgi.dll ddraw.dll D3DImm.dll dxvk.conf dgVoodoo.conf; do
    if [ -f "$stamp/$f" ]; then cp -p "$stamp/$f" "$GAME_DIR/$f"; fi
  done
  rm -f "$GAME_DIR/$PROFILE_NAME" "$TRIAGE_STATE"
  ok "Restored original state."
}

cmd_help() {
  cat <<EOF
brz-mac $BRZ_VERSION — old D3D9 games on Apple Silicon (Sikarugir/Wine); defaults: Battle Realms: Zen Edition

 Start here
  doctor                          Check Mac, wrapper, game, renderer state
  probe [--quick] [profiles]      Run the D3D9 feature probe under each renderer -> comparison table
  triage [--reset]                Guided rounds: one change, you play, answer 5 questions
  report                          One markdown file with everything (send it to me)

 Manual control
  profile NAME [DIR]              Renderer for the game: $PROFILES
  ini [show|get K|set K V]        Read/edit the game ini ($INI_NAME; e.g. ini set D3D9On12 0)
  conf dxvk|dgvoodoo [show|set K V]  Edit dxvk.conf / dgVoodoo.conf in the game dir
  launch [--hud] [--debug]        Start Steam quietly and launch the game with diagnostics
  retina on|off|default           Retina mode, wrapper-wide like Configure's option (off = usual black-window fix)
  analyze [files]                 Explain what the latest logs say
  identify [files]                What each d3d9.dll really is (Wine/D9VK/DXVK/dgVoodoo + traits)
  fetch dxvk|dgvoodoo [ver]       Download metalsharp DXVK-MacOS / dgVoodoo2 into $DOWNLOADS
  bench SCENARIO AVG MIN U C [N]  Append a benchmark row to $BENCH_CSV
  kill | disk [--clean] | logs | restore

Environment: BRZ_WRAPPER, BRZ_GAME_DIR, BRZ_GAME_EXE, BRZ_APPID, BRZ_INI_NAME, BRZ_INI_SECTION, BRZ_DXVK_DIR, BRZ_DGV_DIR, BRZ_MVK_DIR,
             BRZ_STEAM_ARGS, BRZ_HOME (default ~/.brz-mac), BRZ_YES=1 (no prompts)
EOF
}

main() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    doctor)   cmd_doctor "$@" ;;
    identify) cmd_identify "$@" ;;
    profile)  cmd_profile "$@" ;;
    ini)      cmd_ini "$@" ;;
    conf)     cmd_conf "$@" ;;
    launch)   cmd_launch "$@" ;;
    kill)     cmd_kill "$@" ;;
    retina)   cmd_retina "$@" ;;
    probe)    cmd_probe "$@" ;;
    analyze)  cmd_analyze "$@" ;;
    fetch)    cmd_fetch "$@" ;;
    triage)   cmd_triage "$@" ;;
    report)   cmd_report "$@" ;;
    bench)    cmd_bench "$@" ;;
    disk)     cmd_disk "$@" ;;
    logs)     cmd_logs "$@" ;;
    restore)  cmd_restore "$@" ;;
    version)  info "$BRZ_VERSION" ;;
    help|-h|--help) cmd_help ;;
    *) cmd_help; exit 1 ;;
  esac
}

main "$@"
