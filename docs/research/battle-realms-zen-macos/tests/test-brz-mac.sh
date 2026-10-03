#!/bin/bash
# Tests for brz-mac.sh against a mock Sikarugir wrapper (no Wine or macOS needed).
# Usage: bash tests/test-brz-mac.sh        (needs python3 for the fake wine)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/brz-mac.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brz-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() { # description, command...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "ok   - $desc"
  else FAIL=$((FAIL + 1)); echo "FAIL - $desc"; fi
}
out_has() { # description, needle, command... — command output must contain needle
  local desc="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qF -- "$needle"; then PASS=$((PASS + 1)); echo "ok   - $desc"
  else FAIL=$((FAIL + 1)); echo "FAIL - $desc"; printf '%s\n' "$out" | sed 's/^/       | /' | head -n 30; fi
}

# Minimal PE files: "MZ", e_lfanew=0x40 at offset 0x3c, "PE\0\0" + machine at 0x40, then a marker string.
make_pe() { # path machine-escape marker
  {
    printf 'MZ'; head -c 58 /dev/zero
    printf '\x40\x00\x00\x00'
    printf 'PE\x00\x00'; printf '%b' "$2"
    head -c 64 /dev/zero
    printf '%s' "${3:-}"
  } > "$1"
}

# --- mock wrapper -----------------------------------------------------------
W="$TMP/Battle Realms.app"
PFX="$W/Contents/SharedSupport/prefix"
GAME="$PFX/drive_c/Program Files (x86)/Steam/steamapps/common/Battle Realms Zen Edition"
mkdir -p "$W/Contents/SharedSupport/wine/bin" "$GAME" "$PFX/drive_c/users/me" "$PFX/drive_c/windows/syswow64" "$PFX/dosdevices"
ln -s / "$PFX/dosdevices/z:"
touch "$PFX/drive_c/Program Files (x86)/Steam/steam.exe"
printf 'WINE REGISTRY Version 2\r\n' > "$PFX/user.reg"
printf '[VideoState]\r\nWidth = 1024\r\nHeight = 768\r\nFullscreen = 1\r\nHardwareTL =0\r\nD3D9On12 = 1\r\n\r\n[Sound]\r\nEnabled = 1\r\n' > "$GAME/Battle_Realms.ini"
make_pe "$GAME/Battle_Realms_F.exe" '\x4c\x01'
make_pe "$GAME/d3d9.dll" '\x4c\x01' 'GAME-OWN-D3D9'                     # the game ships its own d3d9.dll
make_pe "$PFX/drive_c/windows/syswow64/d3d9.dll" '\x4c\x01' 'Wine placeholder DLL'

cp "$HERE/fake-wine.py" "$W/Contents/SharedSupport/wine/bin/wine"
chmod +x "$W/Contents/SharedSupport/wine/bin/wine"
printf '#!/bin/bash\nexit 0\n' > "$W/Contents/SharedSupport/wine/bin/wineserver"
chmod +x "$W/Contents/SharedSupport/wine/bin/wineserver"

# Fake downloads: a DXVK-MacOS release with both architectures, and dgVoodoo
mkdir -p "$TMP/dxvk/x64" "$TMP/dxvk/x32" "$TMP/dgv/MS/x86" "$TMP/dgv/MS/x64"
make_pe "$TMP/dxvk/x64/d3d9.dll" '\x64\x86' 'dxvk'
make_pe "$TMP/dxvk/x32/d3d9.dll" '\x4c\x01' 'dxvk deAliasedSamplers'
make_pe "$TMP/dgv/MS/x86/D3D9.dll" '\x4c\x01' 'dgVoodoo'
make_pe "$TMP/dgv/MS/x64/D3D9.dll" '\x64\x86' 'dgVoodoo'

export BRZ_WRAPPER="$W" BRZ_HOME="$TMP/home" BRZ_YES=1
run() { bash "$TOOL" "$@"; }

# --- basics ------------------------------------------------------------------
check   "help runs"                               run help
out_has "doctor finds the game exe"               "Battle_Realms_F.exe (i386)" run doctor
out_has "doctor shows D3D9On12"                   "D3D9On12  1" run doctor
out_has "doctor identifies syswow64 d3d9"         "Wine placeholder" run doctor
out_has "doctor shows wine version"               "wine-9.0 (fake)" run doctor
out_has "doctor: no videos -> in-engine cutscenes" "cutscenes are in-engine" run doctor

# --- ini editing ---------------------------------------------------------------
check   "ini get (case-insensitive key)"          bash -c "[ \"\$(bash '$TOOL' ini get hardwaretl)\" = 0 ]"
check   "ini set existing key"                    run ini set HardwareTL 1
check   "  value changed"                         bash -c "[ \"\$(bash '$TOOL' ini get HardwareTL)\" = 1 ]"
check   "  keeps the file's '=' spacing"          grep -q $'^HardwareTL =1\r$' "$GAME/Battle_Realms.ini"
check   "ini set new video key"                   run ini set VSync 1
check   "  inserted inside [VideoState], not [Sound]" bash -c "tr -d '\r' < \"$GAME/Battle_Realms.ini\" | awk '/^\[Sound\]/{s=1} /^VSync=1/{print (s?\"bad\":\"good\")}' | grep -qx good"
check   "  inserted before the section's blank line" bash -c "tr -d '\r' < \"$GAME/Battle_Realms.ini\" | grep -n '' | grep -q '^7:VSync=1'"
check   "  CRLF line endings preserved everywhere" bash -c "[ \$(grep -c \$'\\r\$' \"$GAME/Battle_Realms.ini\") -eq \$(wc -l < \"$GAME/Battle_Realms.ini\") ]"
check   "ini set sound key lands in [Sound]"      run ini set NumSFXChannels 32
check   "  after Enabled"                         bash -c "tr -d '\r' < \"$GAME/Battle_Realms.ini\" | tail -n 1 | grep -qx 'NumSFXChannels=32'"
check   "original backup made and untouched"      grep -q $'^HardwareTL =0\r$' "$TMP/home/backups/original/Battle_Realms.ini"

# --- profiles -------------------------------------------------------------------
check   "profile d9vk (bundled)"                  run profile d9vk
check   "  installed the bundled DLL"             cmp -s "$GAME/d3d9.dll" "$ROOT/dlls/d9vk-f229921/d3d9.dll"
check   "  stashed the game's own d3d9.dll"       grep -q 'GAME-OWN-D3D9' "$GAME/d3d9.dll.brz-orig"
check   "  dxvk.conf installed"                   test -f "$GAME/dxvk.conf"
check   "  per-app override native"               grep -q '"d3d9"="native"' "$PFX/user.reg"
out_has "  doctor sees the 16-bit fix build"      "+16-bit-promotion" run doctor
out_has "  identify the diag DLL"                 "+diag-logging" run identify "$ROOT/dlls/d9vk-f229921-diag/d3d9.dll"
check   "conf set"                                run conf dxvk set d3d9.maxFrameRate 45
check   "  value"                                 grep -q '^d3d9.maxFrameRate = 45$' "$GAME/dxvk.conf"
check   "conf set new key appends"                run conf dxvk set dxvk.hud fps
check   "  appended"                              bash -c "tail -n 1 '$GAME/dxvk.conf' | grep -qx 'dxvk.hud=fps'"

check   "profile dxvk (external, picks i386)"     run profile dxvk "$TMP/dxvk"
check   "  i386 DLL in place"                     cmp -s "$GAME/d3d9.dll" "$TMP/dxvk/x32/d3d9.dll"
check   "  game's own DLL still stashed once"     bash -c "grep -q GAME-OWN-D3D9 '$GAME/d3d9.dll.brz-orig' && [ \$(ls '$GAME' | grep -c brz-orig) -eq 1 ]"
check   "dxvk rejects an x64-only release"        bash -c "mkdir -p '$TMP/x64only' && cp '$TMP/dxvk/x64/d3d9.dll' '$TMP/x64only/' && ! bash '$TOOL' profile dxvk '$TMP/x64only'"

check   "profile dgvoodoo"                        run profile dgvoodoo "$TMP/dgv"
check   "  dgVoodoo DLL in place"                 cmp -s "$GAME/d3d9.dll" "$TMP/dgv/MS/x86/D3D9.dll"
check   "  dgVoodoo.conf installed"               test -f "$GAME/dgVoodoo.conf"
check   "  dxvk.conf removed with its profile"    test ! -f "$GAME/dxvk.conf"

check   "profile wined3d-vk"                      run profile wined3d-vk
check   "  renderer=vulkan for the game exe"      grep -q '"renderer"="vulkan"' "$PFX/user.reg"
check   "  builtin d3d9"                          grep -q '"d3d9"="builtin"' "$PFX/user.reg"
check   "  game's own d3d9.dll is back"           grep -q 'GAME-OWN-D3D9' "$GAME/d3d9.dll"
check   "profile wined3d -> renderer gl"          bash -c "bash '$TOOL' profile wined3d >/dev/null && grep -q '\"renderer\"=\"gl\"' '$PFX/user.reg'"
check   "profile wrapper clears per-app keys"     bash -c "bash '$TOOL' profile wrapper >/dev/null && ! grep -q '\"renderer\"=' '$PFX/user.reg' && ! grep -q '\"d3d9\"=' '$PFX/user.reg'"
check   "unknown profile fails"                   bash -c "! bash '$TOOL' profile nope"
check   "retina off"                              run retina off
check   "  wrapper-wide key, like Configure"      bash -c "awk '/^\[Software\\\\\\\\Wine\\\\\\\\Mac Driver\]/{f=1;next} /^\[/{f=0} f && /\"RetinaMode\"=\"N\"/{ok=1} END{exit !ok}' \"\$1\"" _ "$PFX/user.reg"
check   "  LogPixels 96 like Configure"           grep -q '"LogPixels"="96"' "$PFX/user.reg"
check   "  not written per app (Wine ignores it)" bash -c "! grep -qi 'AppDefaults.*Mac Driver' \"\$1\"" _ "$PFX/user.reg"
out_has "  doctor shows it"                       'global mac driver: "RetinaMode"="N"' run doctor
check   "retina default removes it"               bash -c "bash '$TOOL' retina default >/dev/null && ! grep -q RetinaMode '$PFX/user.reg'"

# --- probe + matrix -------------------------------------------------------------
out_has "probe runs wrapper/wined3d/d9vk"         "FAILED (black/none/wrong/err)" run probe wrapper wined3d d9vk
# shellcheck disable=SC2012  # temp dir with our own names
M="$(ls -td "$TMP"/home/logs/probe-* | head -n 1)/matrix.txt"
check   "  matrix saved"                          test -f "$M"
check   "  matrix shows wrapper BLACK on A4R4G4B4" bash -c "grep 'HW: tex A4R4G4B4 managed' '$M' | grep -q 'BLACK'"
check   "  columns in run order"                  bash -c "head -n 1 '$M' | awk '{print \$2, \$3, \$4}' | grep -qx 'wrapper wined3d d9vk'"
check   "  matrix shows d9vk ok on A4R4G4B4"      bash -c "grep 'HW: tex A4R4G4B4 managed' '$M' | awk '{print \$NF}' | grep -qx ok"
check   "  matrix has benchmark row"              bash -c "grep '^benchmark' '$M' | grep -q '88'"
check   "  probe left the game alone"             grep -q 'GAME-OWN-D3D9' "$GAME/d3d9.dll"
out_has "probe wined3d-vk shows NOT DRAWN"        "none" run probe wined3d-vk
out_has "probe: a run that dies is reported"      "DIED after: the benchmark (1000 draws/frame)" env BRZ_DXVK_DIR="$TMP/dxvk" bash "$TOOL" probe dxvk
# shellcheck disable=SC2012
D2="$(ls -td "$TMP"/home/logs/probe-* | head -n 1)"
check   "  matrix marks it +died"                 bash -c "grep '^FAILED' '$D2/matrix.txt' | grep -q '+died'"
out_has "  analyze names the failed Vulkan call"  "(vkCreateGraphicsPipelines)" run analyze "$D2/dxvk.stdout.log"

# --- analyze ---------------------------------------------------------------------
cat > "$TMP/game.log" <<'EOF'
info:  DXVK: v1.10.3-brz-f229921-diag (macOS)
[mvk-info] MoltenVK version 1.2.9, supporting Vulkan version 1.2.290.
info:  D3D9-DIAG: device created, BehaviorFlags=0x42 HARDWARE_VP FPU_PRESERVE robustness2=no nullDescriptor=no
info:  D3D9-DIAG: texture fmt=D3D9Format::A4R4G4B4 type=TEXTURE pool=MANAGED usage=0x0 size=64x64 levels=1 -> vk=VK_FORMAT_B8G8R8A8_UNORM conversion=9
info:  D3D9-DIAG: texture fmt=D3D9Format::P8 type=TEXTURE pool=MANAGED usage=0x0 size=64x64 levels=1 -> vk=VK_FORMAT_UNDEFINED conversion=0 UNSUPPORTED
info:  D3D9-DIAG: CheckDeviceFormat fmt=D3D9Format::A8P8 rtype=TEXTURE usage=0x0 -> NOTAVAILABLE
info:  D3D9-DIAG: FF PS FF_FS_aaaa | s0 C=SELECTARG2(TEXTURE,DIFFUSE) A=SELECTARG2(TEXTURE,DIFFUSE) tex=0 type=0
info:  D3D9-DIAG: FF PS FF_FS_bbbb | s0 C=BLENDTEXTUREALPHA(TEXTURE,TFACTOR) A=SELECTARG1(TEXTURE,DIFFUSE) tex=0 type=0
info:  D3D9-DIAG: FF PS FF_FS_cccc | s0 C=SELECTARG1(TFACTOR,DIFFUSE) A=SELECTARG1(TEXTURE,DIFFUSE) tex=0 type=0
warn:  Direct3DCreate9On12: 9On12 functionality is unimplemented.
[mvk-error] VK_ERROR_INITIALIZATION_FAILED: Shader library compile failed (Error code 3): program_source:12: error
EOF
A="$(bash "$TOOL" analyze "$TMP/game.log" 2>&1)"
check   "analyze: unbound TEXTURE flagged once (colour BLENDTEXTUREALPHA only; not SELECTARG2, not alpha-only)" \
        bash -c "printf '%s' \"\$1\" | grep -c 'reads TEXTURE but no texture is bound' | grep -qx 1 && printf '%s' \"\$1\" | grep -q 'FF_FS_bbbb' && ! printf '%s' \"\$1\" | grep -qE 'FF_FS_(aaaa|cccc)'" _ "$A"
check   "analyze: unsupported texture format"     bash -c "printf '%s' \"\$1\" | grep -q 'cannot map (P8)'" _ "$A"
check   "analyze: refused formats listed"         bash -c "printf '%s' \"\$1\" | grep -q 'refused: A8P8'" _ "$A"
check   "analyze: old MoltenVK warning"           bash -c "printf '%s' \"\$1\" | grep -q 'MoltenVK 1.2.9 is older than 1.3.0'" _ "$A"
check   "analyze: D3D9On12 hint"                  bash -c "printf '%s' \"\$1\" | grep -q 'try D3D9On12=0'" _ "$A"
check   "analyze: MoltenVK shader failure"        bash -c "printf '%s' \"\$1\" | grep -q 'could not translate a shader'" _ "$A"
check   "analyze: texture format summary"         bash -c "printf '%s' \"\$1\" | grep -q 'A4R4G4B4 -> VK_FORMAT_B8G8R8A8_UNORM (converted)'" _ "$A"
check   "analyze: TFACTOR noted"                  bash -c "printf '%s' \"\$1\" | grep -q 'uses TFACTOR (team colour)'" _ "$A"
printf 'warn:  DXVK: No adapters found. Please check your device filter settings\ninfo:    Skipping: Device does not support required feature '"'"'khrLoadStoreOpNone'"'"' (extension: VK_KHR_load_store_op_none)\n' > "$TMP/noadapter.log"
out_has "analyze: no-adapter explained"           "lacks 'khrLoadStoreOpNone'" run analyze "$TMP/noadapter.log"

# --- triage (scripted answers, no real launch) ---------------------------------------
# round 1 (baseline): reached menu, screen ok, units black, fps 90, cutscenes ?
# round 2 (d9vk):     reached menu, screen ok, units fine,  fps 60 -> stop
answers=$'\ny\nn\ny\n90\n?\n\ny\nn\nn\n60\ny\n'
TRI="$(printf '%s' "$answers" | BRZ_TRIAGE_NOLAUNCH=1 bash "$TOOL" triage 2>&1)"
check   "triage stops at the first good round"    bash -c "printf '%s' \"\$1\" | grep -q 'Correct image at 60 FPS'" _ "$TRI"
check   "triage recommends d9vk"                  bash -c "printf '%s' \"\$1\" | grep -q 'Best correct configuration: d9vk'" _ "$TRI"
check   "triage log has two rounds"               bash -c "[ \$(grep -c '^20' '$TMP/home/triage.log') -eq 2 ]"
check   "triage left d9vk applied"                cmp -s "$GAME/d3d9.dll" "$ROOT/dlls/d9vk-f229921/d3d9.dll"
check   "triage state cleared when finished"      test ! -f "$TMP/home/triage.state"

# black screen -> Fullscreen=0 and the same round repeats
rm -f "$TMP/home/triage.log"
answers=$'\ny\ny\n?\n?\n?\n\ny\nn\nn\n50\ny\n'
TRI="$(printf '%s' "$answers" | BRZ_TRIAGE_NOLAUNCH=1 bash "$TOOL" triage --reset 2>&1)"
check   "black screen sets Fullscreen=0"          bash -c "[ \"\$(bash '$TOOL' ini get Fullscreen)\" = 0 ]"
check   "  and RetinaMode=N for the game"         grep -q '"RetinaMode"="N"' "$PFX/user.reg"
check   "  and repeats the same round"            bash -c "[ \$(grep -c '|baseline|' '$TMP/home/triage.log') -eq 2 ]"

# --- bench / report / logs / restore ----------------------------------------------------
check   "bench row"                               run bench "Skirmish 4 AI" 58 31 y n "first, try"
check   "  csv header + row"                      bash -c "[ \$(wc -l < '$TMP/home/bench.csv') -eq 2 ]"
check   "  commas in notes don't break columns"   bash -c "tail -n 1 '$TMP/home/bench.csv' | awk -F, '{exit (NF==10)?0:1}'"
out_has "report written"                          "Report:" run report
# shellcheck disable=SC2012
R="$(ls -t "$TMP"/home/report-*.md | head -n 1)"
check   "  report has probe matrix + triage"      bash -c "grep -q '## latest probe matrix' '$R' && grep -q 'baseline' '$R' && grep -q 'FAILED' '$R'"
check   "logs bundle"                             run logs
check   "  bundle exists"                         bash -c "ls '$TMP/home'/brz-diag-* >/dev/null"

check   "launch builds the steam command"         run launch --hud --debug
sleep 1
check   "  used -applaunch"                       grep -q 'steam.exe .*-applaunch 1025600' "$PFX/wine-calls.log"

check   "restore"                                 run restore
check   "  ini restored"                          grep -q $'^HardwareTL =0\r$' "$GAME/Battle_Realms.ini"
check   "  game's own d3d9.dll restored"          grep -q 'GAME-OWN-D3D9' "$GAME/d3d9.dll"
check   "  no stash left behind"                  bash -c "! ls '$GAME' | grep -q brz-orig"
check   "  profile marker cleared"                test ! -f "$GAME/.brz-profile"

# --- the bundled skill copy -------------------------------------------------------------
SKILLTOOL="$ROOT/skill/mac-wine-dx9-games/scripts/toolkit/brz-mac.sh"
check   "skill copy is in sync with the toolkit"  bash "$ROOT/tools/sync-skill.sh" --check
out_has "skill copy runs (help)"                  "brz-mac" bash "$SKILLTOOL" help
out_has "skill copy finds its own DLLs"           "+16-bit-promotion" bash "$SKILLTOOL" identify "$ROOT/skill/mac-wine-dx9-games/scripts/toolkit/dlls/d9vk-f229921/d3d9.dll"
check   "skill copy applies profile d9vk"         bash -c "BRZ_YES=1 bash '$SKILLTOOL' profile d9vk >/dev/null && cmp -s \"\$1/d3d9.dll\" '$ROOT/skill/mac-wine-dx9-games/scripts/toolkit/dlls/d9vk-f229921/d3d9.dll'" _ "$GAME"
check   "  and back to the wrapper"               bash -c "BRZ_YES=1 bash '$SKILLTOOL' profile wrapper >/dev/null && grep -q GAME-OWN-D3D9 \"\$1/d3d9.dll\"" _ "$GAME"

# --- other games: BRZ_APPID / BRZ_INI_NAME / BRZ_GAME_EXE ------------------------------
check   "BRZ_APPID changes -applaunch"            env BRZ_APPID=4242 bash "$TOOL" launch
sleep 1
check   "  used -applaunch 4242"                  grep -q 'steam.exe .*-applaunch 4242' "$PFX/wine-calls.log"

W2="$TMP/Other Game.app"; PFX2="$W2/Contents/SharedSupport/prefix"
G2="$PFX2/drive_c/Program Files (x86)/Steam/steamapps/common/Some Old RTS"
mkdir -p "$W2/Contents/SharedSupport/wine/bin" "$G2" "$PFX2/dosdevices"
cp "$W/Contents/SharedSupport/wine/bin/wine" "$W/Contents/SharedSupport/wine/bin/wineserver" "$W2/Contents/SharedSupport/wine/bin/"
printf 'WINE REGISTRY Version 2\r\n' > "$PFX2/user.reg"
printf '[Video]\r\nWindowed=0\r\n' > "$G2/game.ini"
make_pe "$G2/rts.exe" '\x4c\x01'
other() { env BRZ_WRAPPER="$W2" BRZ_HOME="$TMP/home2" BRZ_INI_NAME=game.ini BRZ_GAME_EXE=rts.exe bash "$TOOL" "$@"; }
out_has "other game: doctor finds it"             "rts.exe (i386)" other doctor
check   "other game: ini set (own section)"       other ini set Windowed 1
check   "  value"                                 bash -c "tr -d '\r' < \"\$1\" | grep -qx 'Windowed=1'" _ "$G2/game.ini"
check   "other game: new key goes to BRZ_INI_SECTION" bash -c "env BRZ_WRAPPER='$W2' BRZ_HOME='$TMP/home2' BRZ_INI_NAME=game.ini BRZ_GAME_EXE=rts.exe BRZ_INI_SECTION=Video bash '$TOOL' ini set Gamma 5 >/dev/null && tr -d '\r' < \"\$1\" | awk '/^\[/{sec=\$0} /^Gamma=5/{print sec}' | grep -qx '\[Video\]'" _ "$G2/game.ini"
check   "other game: profile d9vk"                other profile d9vk
check   "  DLL next to rts.exe"                   cmp -s "$G2/d3d9.dll" "$ROOT/dlls/d9vk-f229921/d3d9.dll"
check   "  per-app override for rts.exe"          grep -q 'AppDefaults\\\\rts.exe\\\\DllOverrides' "$PFX2/user.reg"
check   "other game: restore"                     other restore
check   "  DLL removed again"                     test ! -f "$G2/d3d9.dll"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
