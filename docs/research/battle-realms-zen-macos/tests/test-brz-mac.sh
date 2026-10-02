#!/bin/bash
# Smoke tests for brz-mac.sh against a mock Sikarugir wrapper (no Wine or macOS needed).
# Usage: bash tests/test-brz-mac.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../brz-mac.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brz-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() { # description, command...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "ok   - $desc"
  else FAIL=$((FAIL + 1)); echo "FAIL - $desc"; fi
}

# Minimal PE files: "MZ", e_lfanew=0x40 at offset 0x3c, "PE\0\0" + machine at 0x40.
make_pe() { # path machine-hex-le (e.g. '\x4c\x01' for i386)
  {
    printf 'MZ'; head -c 58 /dev/zero
    printf '\x40\x00\x00\x00'
    printf 'PE\x00\x00'; printf '%b' "$2"
    head -c 64 /dev/zero
  } > "$1"
}

# --- mock wrapper -----------------------------------------------------------
W="$TMP/Battle Realms.app"
PFX="$W/Contents/SharedSupport/prefix"
GAME="$PFX/drive_c/Program Files (x86)/Steam/steamapps/common/Battle Realms Zen Edition"
mkdir -p "$W/Contents/SharedSupport/wine/bin" "$GAME" "$PFX/drive_c/users/me"
touch "$PFX/drive_c/Program Files (x86)/Steam/steam.exe"
printf 'WINE REGISTRY Version 2\r\n' > "$PFX/user.reg"
printf '[Settings]\r\nHardwareTL =0\r\nFullscreen=1\r\nWidth = 1024\r\n' > "$GAME/Battle_Realms.ini"
touch "$GAME/Battle_Realms_F.exe"

# Fake wine: implements just enough of `reg add/delete` to write user.reg like Wine does.
cat > "$W/Contents/SharedSupport/wine/bin/wine" <<'EOF'
#!/bin/bash
echo "wine $*" >> "$WINEPREFIX/wine-calls.log"
[ "$1" = "reg" ] || exit 0
key="${3#HKCU\\}"; key="${key//\\/\\\\}"
reg="$WINEPREFIX/user.reg"
if [ "$2" = "add" ]; then
  name="$5"; data="$9"
  grep -q "^\\[$(printf '%s' "$key" | sed 's/[][\\.]/\\&/g')\\]" "$reg" || printf '\n[%s]\n' "$key" >> "$reg"
  printf '"%s"="%s"\n' "$name" "$data" >> "$reg"
elif [ "$2" = "delete" ]; then
  grep -v "^\"$5\"=" "$reg" > "$reg.tmp"; mv "$reg.tmp" "$reg"
fi
EOF
chmod +x "$W/Contents/SharedSupport/wine/bin/wine"
printf '#!/bin/bash\nexit 0\n' > "$W/Contents/SharedSupport/wine/bin/wineserver"
chmod +x "$W/Contents/SharedSupport/wine/bin/wineserver"

# Fake DXVK release with both architectures, fake dgVoodoo
mkdir -p "$TMP/dxvk/x64" "$TMP/dxvk/x32" "$TMP/dgv/MS/x86" "$TMP/dgv/MS/x64"
make_pe "$TMP/dxvk/x64/d3d9.dll" '\x64\x86'
make_pe "$TMP/dxvk/x32/d3d9.dll" '\x4c\x01'
make_pe "$TMP/dgv/MS/x86/D3D9.dll" '\x4c\x01'
make_pe "$TMP/dgv/MS/x64/D3D9.dll" '\x64\x86'

export BRZ_WRAPPER="$W" BRZ_HOME="$TMP/home" BRZ_YES=1
run() { bash "$TOOL" "$@"; }

# --- tests ------------------------------------------------------------------
check "help runs"                         run help
check "doctor finds game"                 bash -c "bash '$TOOL' doctor | grep -q 'Battle_Realms_F.exe'"
check "ini get keeps spacing-insensitive" bash -c "[ \"\$(bash '$TOOL' ini get hardwaretl)\" = 0 ]"
check "ini set"                           run ini set HardwareTL 1
check "ini value changed"                 bash -c "[ \"\$(bash '$TOOL' ini get HardwareTL)\" = 1 ]"
check "ini keeps original '=' spacing"    grep -q $'^HardwareTL =1\r$' "$GAME/Battle_Realms.ini"
check "ini keeps CRLF endings"            bash -c "[ \$(grep -c \$'\\r\$' \"$GAME/Battle_Realms.ini\") -eq 4 ]"
check "ini set appends new key"           run ini set Windowed 1
check "appended key readable"             bash -c "[ \"\$(bash '$TOOL' ini get Windowed)\" = 1 ]"
check "original backup made"              test -f "$TMP/home/backups/original/Battle_Realms.ini"
check "original backup is untouched"      grep -q $'^HardwareTL =0\r$' "$TMP/home/backups/original/Battle_Realms.ini"

check "profile dxvk"                      run profile dxvk "$TMP/dxvk"
check "dxvk picked the i386 DLL"          cmp -s "$GAME/d3d9.dll" "$TMP/dxvk/x32/d3d9.dll"
check "dxvk.conf installed"               test -f "$GAME/dxvk.conf"
check "override set native"               grep -q '"d3d9"="native"' "$PFX/user.reg"
check "doctor shows override"             bash -c "bash '$TOOL' doctor | grep -q '\"d3d9\"=\"native\"'"
check "doctor shows i386 dll"             bash -c "bash '$TOOL' doctor | grep -q 'd3d9.dll (i386)'"
check "conf set"                          run conf dxvk set d3d9.maxFrameRate 45
check "conf value"                        grep -q '^d3d9.maxFrameRate = 45$' "$GAME/dxvk.conf"

check "profile dgvoodoo"                  run profile dgvoodoo "$TMP/dgv"
check "dgvoodoo dll in place"             cmp -s "$GAME/d3d9.dll" "$TMP/dgv/MS/x86/D3D9.dll"
check "dxvk.conf removed on switch"       test ! -f "$GAME/dxvk.conf"
check "dgVoodoo.conf installed"           test -f "$GAME/dgVoodoo.conf"

check "profile wined3d"                   run profile wined3d
check "managed dll removed"               test ! -f "$GAME/d3d9.dll"
check "override builtin"                  bash -c "grep '\"d3d9\"=' '$PFX/user.reg' | tail -n1 | grep -q builtin"

check "dxvk rejects x64-only release"     bash -c "mkdir -p '$TMP/x64only' && cp '$TMP/dxvk/x64/d3d9.dll' '$TMP/x64only/' && ! bash '$TOOL' profile dxvk '$TMP/x64only'"
check "unknown profile fails"             bash -c "! bash '$TOOL' profile nope"

check "bench row"                         run bench "Skirmish 4 AI" 58 31 y n "first try"
check "bench csv has header+row"          bash -c "[ \$(wc -l < '$TMP/home/bench.csv') -eq 2 ]"
check "bench records profile"             grep -q ',wined3d,1,' "$TMP/home/bench.csv"

check "launch builds steam command"       run launch --hud
sleep 1
check "launch used -applaunch"            grep -q 'steam.exe .*-applaunch 1025600' "$PFX/wine-calls.log"

check "restore"                           run restore
check "ini restored"                      grep -q $'^HardwareTL =0\r$' "$GAME/Battle_Realms.ini"
check "profile marker cleared"            test ! -f "$GAME/.brz-profile"

check "logs bundle"                       run logs
check "bundle exists"                     bash -c "ls '$TMP/home'/brz-diag-* >/dev/null"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
