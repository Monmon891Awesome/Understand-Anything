# Toolkit reference (`scripts/toolkit/`)

## Contents

- [Layout](#layout)
- [Commands](#commands)
- [Environment variables](#environment-variables)
- [Profiles: what each one changes](#profiles-what-each-one-changes)
- [dxvk.conf knobs](#dxvkconf-knobs)
- [Files it writes](#files-it-writes)
- [Maintaining the toolkit](#maintaining-the-toolkit)

## Layout

```
scripts/toolkit/
├── brz-mac.sh                     the tool: bash 3.2 + BSD/BWK tools, nothing to install
├── templates/dxvk.conf            installed next to the game with the d9vk/dxvk profiles
├── templates/dgVoodoo.conf        installed with the dgvoodoo profile (D3D11 FL11_0, no watermark)
├── dlls/d9vk-f229921/d3d9.dll     D9VK + June 2026 16-bit texture fix (32-bit)
├── dlls/d9vk-f229921-diag/d3d9.dll  same + D3D9-DIAG logging
├── dlls/README.md, SHA256SUMS     provenance and checksums
├── bin/brz-probe.exe              D3D9 feature probe (source in probe/)
├── patches/d9vk/*.patch           the two patches applied on top of upstream d9vk
├── tools/build-d9vk.sh            rebuilds both DLLs from public source
└── reference-results/             what the probe printed on a Linux/Wine 9.0 reference box
```

Run every command as `bash scripts/toolkit/brz-mac.sh <command>`. Execute permissions don't matter that way, and the script finds its own files from any directory.

## Commands

| Command | What it does |
|---|---|
| `doctor` | Checks the Mac (macOS, RAM, Rosetta, Low Power Mode, battery, free disk), the wrapper (wine and MoltenVK versions, DXMT/D3DMetal presence, what `syswow64`/`system32` `d3d9.dll` really is), and the game (exe arch, ini video keys, DLLs in the game folder, cutscene video files). Also prints the per-game Wine keys. |
| `probe [--quick] [profiles…]` | Copies `brz-probe.exe` to `drive_c/brz-probe/` and runs it under each profile. Default profiles: `wrapper wined3d d9vk wined3d-vk` + `dxvk`/`dgvoodoo` if downloaded. Prints and saves a test × renderer table. The game is never touched. |
| `triage [--reset]` | Interactive rounds: baseline → d9vk → D3D9On12=0 → HardwareTL flip → d9vk-diag → dxvk → dgvoodoo → wined3d-vk → wined3d. Asks 5 questions per round, analyzes each log, stops at the first correct round with ≥ 45 FPS. A black screen repeats the round windowed with Retina off. Resumable. |
| `profile NAME [DIR]` | Switches the game's D3D9 implementation (see below) |
| `ini [show \| get K \| set K V]` | Reads/edits the game ini. Keeps CRLF endings and the file's `key = value` spacing; new keys go into the right section. |
| `conf dxvk\|dgvoodoo [show \| set K V]` | Edits `dxvk.conf` / `dgVoodoo.conf` in the game folder |
| `retina on\|off\|default` | Wrapper-wide Retina mode, written exactly like Configure: `Mac Driver\RetinaMode` + `Control Panel\Desktop\LogPixels` (192/96). Wine has no per-app Retina setting. |
| `launch [--hud] [--debug]` | `steam.exe -silent -nofriendsui -nochatui -noverifyfiles -applaunch APPID` with the MoltenVK/MSync env. `--hud` adds the DXVK overlay; `--debug` adds DXVK/MoltenVK/Wine logging. Warns if Steam is already running, since env vars would then not reach the game. |
| `analyze [files…]` | Matches log lines against known signatures. Groups the output into Problems, Warnings and Facts, including the texture formats and fixed-function setups the game used. |
| `identify [files…]` | What a `d3d9.dll` really is, with traits (`+16-bit-promotion`, `+diag-logging`, `+async`, `+deAliasedSamplers`), arch, size and sha256 |
| `fetch dxvk\|dgvoodoo [ver]` | Downloads the metalsharp DXVK-MacOS release, or dgVoodoo2 (default 2.87.5; try 2.79.3 and 2.54 if needed), via the GitHub API |
| `bench SCENARIO AVG MIN UNITS_OK CUTSCENES_OK [notes]` | Appends a row to `bench.csv`; the profile and ini values are filled in automatically |
| `report` | One markdown file with doctor, ini, dxvk.conf, the latest probe table, the triage log, bench and analysis |
| `logs` | Zip of raw logs |
| `kill` | `wineserver -k` for this prefix |
| `disk [--clean]` | Space use; `--clean` removes Steam download/shader/web caches and logs older than 7 days |
| `restore` | Puts back the ini, `user.reg` and game-folder DLLs as they were before the first change |

## Environment variables

| Variable | Default | Use |
|---|---|---|
| `BRZ_WRAPPER` | auto (`/Applications`, `~/Applications`, their `Sikarugir`/`Porting Kit` folders) | Path to the wrapper `.app` |
| `BRZ_GAME_DIR` | the folder containing `BRZ_INI_NAME` | The game folder inside `drive_c` |
| `BRZ_GAME_EXE` | `Battle_Realms_F.exe` / `Battle_Realms*.exe` | The exe the per-app Wine keys apply to |
| `BRZ_APPID` | `1025600` | Steam app id for `launch` |
| `BRZ_INI_NAME` | `Battle_Realms.ini` | The game's settings file (also used to find the game) |
| `BRZ_INI_SECTION` | `VideoState` | Section for new ini keys |
| `BRZ_DXVK_DIR`, `BRZ_DGV_DIR` | newest `fetch` result | Your own extracted DXVK-MacOS / dgVoodoo2 folders |
| `BRZ_MVK_DIR` | (unset) | Experimental: prepends a MoltenVK folder to `DYLD_LIBRARY_PATH` |
| `BRZ_STEAM_ARGS` | `-silent -nofriendsui -nochatui -noverifyfiles` | Steam flags for `launch` |
| `BRZ_HOME` | `~/.brz-mac` | Where backups, logs, downloads and reports go |
| `BRZ_YES` | 0 | `1` answers yes to every prompt (assistants, scripts) |
| `BRZ_MATRIX_ALL` | 0 | `1` shows every probe row, not just the ones that differ |

`launch`/`probe` export `MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE=1`, `MVK_CONFIG_FAST_MATH_ENABLED=0` and `WINEMSYNC=1`.
- `--hud` adds `DXVK_HUD`.
- `--debug` adds `DXVK_LOG_LEVEL=info`, `MVK_CONFIG_LOG_LEVEL=3` (logs the MoltenVK version), `WINEDEBUG=err+all,warn+d3d,+loaddll`, and `DXVK_LOG_PATH` as a `Z:` path.

## Profiles: what each one changes

All profiles act only on the game exe's per-app keys (`HKCU\Software\Wine\AppDefaults\<exe>\…`) and on files next to the exe. Any file a profile replaces is stashed as `<name>.brz-orig` and put back on the next switch.

| Profile | DLL next to exe | `DllOverrides\d3d9` | `Direct3D\renderer` |
|---|---|---|---|
| `wrapper` | none | removed (the wrapper's global setting applies) | removed |
| `wined3d` | none | `builtin` | `gl` |
| `wined3d-vk` | none | `builtin` | `vulkan` |
| `d9vk` | bundled `d9vk-f229921` + `dxvk.conf` | `native` | removed |
| `d9vk-diag` | bundled diag build + `dxvk.conf` | `native` | removed |
| `dxvk` | i386 `d3d9.dll` from the DXVK-MacOS release + `dxvk.conf` | `native` | removed |
| `dgvoodoo` | `MS/x86/D3D9.dll` + `dgVoodoo.conf` | `native` | removed (needs DXMT on in Configure) |

## dxvk.conf knobs

| Key | Template | When to change |
|---|---|---|
| `d3d9.floatEmulation` | `Strict` | `True` if Strict costs FPS and nothing turns black |
| `d3d9.deAliasedSamplers` | `True` | DXVK 3.x fork only (ignored by D9VK) |
| `d3d9.forceSamplerTypeSpecConstants` | commented | Try `True` if units are still black |
| `d3d9.shaderModel` | commented | Try `2` if units are invisible or black |
| `dxvk.enableAsync` | `True` | D9VK: compile pipelines in the background (fewer hitches) |
| `dxvk.enableStateCache` | `True` | Keep pipelines between sessions (`<exe>.dxvk-cache` next to the game) |
| `d3d9.maxFrameRate` | `60` | A steady cap keeps an M1 cool |
| `d3d9.maxFrameLatency`, `d3d9.presentInterval` | `1`, `1` | Leave |
| `dxvk.hud` | commented | An overlay without the script's `--hud` |

## Files it writes

`~/.brz-mac/` (or `BRZ_HOME`) contains:
- `backups/original/`: the state before the first change, used by `restore`
- `backups/<time>-<label>/`: a snapshot before each change
- `logs/`: `launch-*.log`, DXVK logs, `probe-<time>/` (one file per renderer + `matrix.txt`), triage analyses
- `downloads/`: `fetch` results
- `bench.csv`, `triage.log`, `report-*.md`

## Maintaining the toolkit

- **Canonical copy:** `docs/research/battle-realms-zen-macos/` on the `research/battle-realms-zen-macos` branch of the user's repo. `tools/sync-skill.sh` copies it into this skill, and the test suite fails if the copies drift.
- **Tests:** `bash tests/test-brz-mac.sh` (mock wrapper with a Python fake `wine`; needs python3) covers profiles, ini editing, probe matrix, death detection, analyzer signatures, triage, overrides for other games, and restore.
- **Rebuild the DLLs:** `tools/build-d9vk.sh` (mingw-w64, meson, ninja, glslang).
- **Rebuild the probe:** `probe/build.sh`.
