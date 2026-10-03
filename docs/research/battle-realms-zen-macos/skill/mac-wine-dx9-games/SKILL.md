---
name: mac-wine-dx9-games
description: Diagnose and fix old 32-bit Windows games (DirectX 9 and earlier, roughly 1998-2010) that run badly in Wine on Apple Silicon Macs - black or dark units and textures, an all-black screen, lag in battles or cutscenes, stutter when new units or effects appear. Covers Sikarugir, Kegworks/Wineskin, Porting Kit, CrossOver and Whisky, and the D3D layers involved (WineD3D/OpenGL, D9VK/DXVK + MoltenVK, dgVoodoo2 + DXMT, and why D3DMetal/GPTK does nothing for these games). Ships a toolkit - per-game renderer profiles, a D3D9 probe that shows which layer renders black on this Mac, guided one-change-per-round triage, a log analyzer, and a D9VK build with the unreleased 16-bit texture fix. Proven on Battle Realms Zen Edition on a base M1 (black units and lag to a smooth 60 FPS). Use it whenever someone wants an older Windows or Steam game to look right or run smoothly on an M1/M2/M3/M4 Mac through Wine, or mentions D9VK, DXVK, MoltenVK, DXMT, D3DMetal or dgVoodoo for an old game, even if they never say Direct3D.
compatibility: macOS on Apple Silicon with Rosetta 2 and a Wine wrapper app (Sikarugir, Wineskin or Porting Kit bundle; CrossOver/Whisky bottles via a wrapper-shaped folder of symlinks); bash and curl. The bundled DLLs and probe are 32-bit Windows binaries that run inside Wine.
---

# Old DirectX games on Apple Silicon (Wine wrappers)

This skill gets an old Direct3D 8/9 Windows game from "laggy or black" to "correct and smooth" on an Apple Silicon Mac. It works by reasoning about the translation stack, proving hypotheses outside the game, and changing one thing at a time.

The toolkit lives in this skill's `scripts/toolkit/` folder. Run it as `bash <this skill's base directory>/scripts/toolkit/brz-mac.sh <command>`. Its defaults are tuned for *Battle Realms: Zen Edition*; [Other games](#other-games) shows how to point it at anything else.

## The stack, and the facts that save hours

```
game.exe (x86-32, D3D8/9) ── runs on Rosetta 2 + Wine (WoW64)
   └─ d3d9.dll ─┬─ WineD3D ──────────► OpenGL ─► Metal     correct, slow with many draw calls
                ├─ D9VK / DXVK ──────► Vulkan ─► MoltenVK ─► Metal   fast; correctness depends on build
                ├─ dgVoodoo2 ─► D3D11 ─► DXMT ─────────────► Metal   no Vulkan at all; fallback
                └─ (D3DMetal/GPTK: 64-bit D3D11/12 only, never used by these games)
```

- **D3DMetal/GPTK and the "DX3D" toggles do nothing for 32-bit DX8/9 games.** DXMT handles D3D10/11, so for these games it only helps behind dgVoodoo2.
- **Sikarugir's D9VK is a DXVK 1.10.3 *async* fork** (`Sikarugir-App/d9vk`, branch `moltenvk-version`). Its version string is hardcoded (`v1.10.3-20230507-async (macOS)`), so every build reports the same version. Identify builds by code traits instead (`brz-mac.sh identify`). Sikarugir's README lists D9VK as the default D3D9 path for "Apple Silicon & macOS Tahoe"; where it isn't used, D3D9 runs on OpenGL (the laggy path). `doctor` shows which `d3d9.dll` actually loads.
- **16-bit textures (A4R4G4B4, A1R5G5B5, R5G6B5)** are everywhere in early-2000s games. Their software conversion landed in d9vk commits `a9e0a68`/`f229921` (June 2026) and is **not in any d9vk release yet**. The bundled `d9vk` profile contains it.
- **D9VK/DXVK's fixed function reads an unbound texture as `(0,0,0,1)`, which is black.** So a texture that failed to create shows up as *black objects with correct shape and lighting*. That is the signature of the bug above.
- **DXVK 3.x forks** (metalsharp DXVK-MacOS) need MoltenVK ≥ 1.3.0 (`VK_KHR_load_store_op_none`); otherwise "No adapters found" and an abort. They also have no async pipeline compiling on MoltenVK, so first-time effects hitch more.
- **Game ini switches matter.** Battle Realms has `D3D9On12` (asks for Microsoft's D3D9-on-12, which nothing on a Mac implements) and `HardwareTL` (CPU vs GPU lighting). Look for similar switches in any game.
- **Install Sikarugir only from its Homebrew tap** (`brew install --cask Sikarugir-App/sikarugir/sikarugir`). Its README warns that sikarugir.com is not theirs.

Details and links: `references/evidence.md`.

## How to reason about it (what cracked Battle Realms)

1. **Separate speed from correctness.** If any path is fast (the Vulkan one usually is), the Mac's hardware is fine and the translation layer is the bottleneck. Don't tune the slow OpenGL path; make the fast path correct.
2. **"Black" is two different bugs.**
   - The *whole screen* black is presentation: exclusive fullscreen, a mode switch, or Retina scaling. Fix it with windowed mode, Retina off (wrapper-wide; Wine has no per-app Retina setting), and the display's scaled resolution.
   - *Objects* black on a correct scene is a texture/shading problem inside the D3D layer. Treat them separately or you'll chase the wrong one.
3. **Pin down the API and bitness first.** A 32-bit D3D9 game rules out half the toggles in the wrapper before you touch anything.
4. **Read the translation layer's source and release history, not just forums.** The Battle Realms fix existed upstream but sat unreleased, behind a version string that never changes. Fixes often live in commits that no release contains yet.
5. **Reproduce outside the game.** The probe (`scripts/toolkit/bin/brz-probe.exe`) draws the same D3D features (16-bit/DXT/L8 textures, TFACTOR team colour, fixed-function lighting, alpha test/blend, render-to-texture) under each layer, then reads the pixels back:
   - `BLACK`: the layer draws but loses the texture/light
   - `NOT DRAWN`: a shader was dropped
   - `CRASH`/`ABORT`/`DIED`: the layer can't run here

   Five minutes of probing replaces hours of guessing in the game.
6. **One change per round, per game, reversible.** Per-app Wine keys (`AppDefaults\<exe>\…`) and DLLs next to the game exe touch nothing else in the wrapper (Retina mode is the one exception: Wine only reads it wrapper-wide). A backup plus `restore` makes every experiment safe. Record each round so the winner is provable.
7. **Read *when* it stutters.**
   - A hitch when something *new* appears is pipeline compiling. Fix it with async compiling (`dxvk.enableAsync`) and the state cache.
   - Low FPS *throughout* a big fight is CPU-bound: the game's single simulation thread under Rosetta. Fix it with GPU lighting (`HardwareTL=1`-style switches), Low Power Mode off, the charger in, and a 60 FPS cap.

## Workflow

In the commands below, `brz-mac.sh` means this skill's `scripts/toolkit/brz-mac.sh`, or the same file in the user's clone of the research branch. Always run it with `bash`. Quit the game and Steam before each step that changes settings.

### Step 1: Inventory (`doctor`, 1 min)

```bash
bash brz-mac.sh doctor
```

It reports:
- **The Mac:** macOS, RAM, Rosetta, Low Power Mode, battery, free disk.
- **The wrapper:** wine version, MoltenVK version, DXMT/D3DMetal presence, and what `syswow64/d3d9.dll` really is.
- **The game:** exe arch, ini video keys, DLLs in the game folder, whether cutscenes are video files or in-engine.
- **Per-game Wine keys.**

Act on anything marked `!` first.

| doctor line | Meaning |
|---|---|
| `syswow64/d3d9 … Wine placeholder` | The wrapper runs D3D9 on OpenGL (the laggy path) |
| `syswow64/d3d9 … DXVK/D9VK` without `+16-bit-promotion` | Old D9VK: prime suspect for black units |
| `MoltenVK` below 1.3.0 | Skip DXVK 3.x (`dxvk` profile) |
| `videos 0 …` | Cutscenes are in-engine: same fix as battles |

### Step 2: Probe every layer (`probe`, 5-10 min, unattended)

```bash
bash brz-mac.sh fetch dxvk; bash brz-mac.sh fetch dgvoodoo   # optional extra columns
bash brz-mac.sh probe
```

It prints a test × renderer table (`~/.brz-mac/logs/probe-*/matrix.txt`). The columns are `wrapper` (whatever the wrapper selects), `wined3d`, `d9vk`, `wined3d-vk`, `dxvk` and `dgvoodoo`.

| Table shows | Meaning | Next |
|---|---|---|
| `wrapper` BLACK on 16-bit rows, `d9vk` ok | The 16-bit texture bug | `profile d9vk` |
| BLACK in every Vulkan column, `wined3d` ok | A MoltenVK problem | Flip *MoltenVK - (CodeWeavers version)* in Configure and re-probe; else `dgvoodoo` |
| `+died` / `DIED after` / `ABORT` / `CRASH` | That layer can't run here | `analyze` names the failing call; skip that layer |
| Everything ok | The cause is outside what the probe covers | Rounds including `d9vk-diag` |

Among the columns with 0 failures, the highest `benchmark` value is the best candidate.

### Step 3: In-game rounds (`triage`, 20-30 min)

Each round sets up one configuration and launches the game with an FPS overlay and full logs. The user plays ~3 minutes (a big fight, plus a cutscene), quits the game **and** Steam, and answers 5 questions:
1. Did it reach the menu?
2. Was the whole screen black?
3. Were units black?
4. FPS in the big fight?
5. Were cutscenes smooth?

| # | Round | Setup |
|---|---|---|
| 1 | baseline | `profile wrapper` |
| 2 | d9vk | `profile d9vk` (the 16-bit fix, async) |
| 3 | d9vk-on12off | + `ini set D3D9On12 0` |
| 4 | d9vk-htl | + `ini set HardwareTL` to the other value |
| 5 | d9vk-diag | `profile d9vk-diag`: only if units are still black; logs every texture format and blend stage |
| 6 | dxvk | `profile dxvk` (needs MoltenVK ≥ 1.3.0) |
| 7 | dgvoodoo | Configure → DXMT on; `profile dgvoodoo` |
| 8 | wined3d-vk | `profile wined3d-vk` |
| 9 | wined3d | `profile wined3d` (the slow-but-correct reference) |

Decisions:
- **Stop** at the first round with a correct picture and ≥ 45 FPS.
- **Whole screen black:** `ini set Fullscreen 0` + `retina off`, then repeat the same round.
- **Units still black after round 4:** run round 5, then `analyze`. Look for *"reads TEXTURE but no texture is bound"* or *"cannot map (FORMAT)"*.
- **Units black in `wined3d` too:** it's the game's own bug, not the port.

### Step 4: Lock in

The profile (a DLL next to the exe + a per-game override), `dxvk.conf`, the ini changes and the Retina setting all persist, so launching from the wrapper keeps the fix. `launch` additionally sets MoltenVK/MSync env vars. If the picture is only right via `launch`, give the user a desktop `.command` file that runs `bash …/brz-mac.sh launch`.

Speed: `HardwareTL 1` (if it renders correctly), `conf dxvk set d3d9.maxFrameRate 60`, the display's scaled resolution (1440×900 on a 13-inch M1), Low Power Mode off, Steam overlay and web-view GPU acceleration off.

### Step 5: Report

`bash brz-mac.sh report` writes one markdown file with everything: doctor output, ini, dxvk.conf, the probe table, the rounds, bench results and the log analysis. `logs` zips the raw logs.

## Running it from an assistant's shell

Your shell is non-interactive, so the script's `[y/N]` prompts can't be answered:
- Run `bash brz-mac.sh kill` first, so Steam and the game are closed.
- Prefix changing commands with `BRZ_YES=1`.
- If environment variables don't persist between your commands, repeat `BRZ_YES=1` / `BRZ_WRAPPER=…` on each line.

Other rules:
- **`triage` asks the user questions.** Either have the user run it in their own Terminal, or drive the same rounds yourself: `kill` → `profile X` → `ini set …` → `launch --hud --debug`. Then ask the user the 5 questions, record with `bench "Skirmish 4 AI" AVG MIN UNITS_OK CUTSCENES_OK "round X"`, and run `analyze`.
- **`probe` takes 5-10 minutes and flashes a window.** Warn the user, and use a long timeout or run it in the background (or `--quick`).
- **Ask before anything that needs the user's hands or eyes:** playing, opening Configure, installing software, a password.
- **Never delete or move the wrapper, Steam, game files or saves.** Never edit `system32`/`syswow64`. Undo with `BRZ_YES=1 bash brz-mac.sh restore`.

## Other games

The probe, `profile`, `launch`, `analyze`, `identify`, `fetch`, `report` and `restore` work for any D3D9 game. Tell the script which one:

```bash
export BRZ_GAME_DIR="$HOME/Applications/Sikarugir/My Game.app/Contents/SharedSupport/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/My Game"
export BRZ_GAME_EXE="game.exe"         # the exe that really runs (check Task Manager or the launch log)
export BRZ_APPID=123456                # Steam app id (from the store URL)
export BRZ_INI_NAME="settings.ini"     # the game's settings file, if it has one
export BRZ_INI_SECTION="Video"         # section where new ini keys should go
```

`triage`'s ini rounds (`D3D9On12`, `HardwareTL`) are Battle Realms switches. For other games, run the same idea by hand: find the game's own windowed/resolution/T&L/renderer switches and test each one as its own round.

**D3D8 games:** Sikarugir's D9VK (DXVK 1.10.3 base) has **no D3D8**. The options are:
- WineD3D (OpenGL)
- dgVoodoo2's `MS/x86/D3D8.dll` (→ D3D11 → DXMT)
- the `d3d8.dll` from a DXVK ≥ 2.4 fork such as metalsharp DXVK-MacOS (needs MoltenVK ≥ 1.3.0)

The toolkit's profiles swap `d3d9.dll` only, so for D3D8, copy the 32-bit `d3d8.dll` next to the exe and set the per-app override yourself: `wine reg add 'HKCU\Software\Wine\AppDefaults\game.exe\DllOverrides' /v d3d8 /d native /f` with the wrapper's wine and `WINEPREFIX`. The probe tests D3D9 only.

**CrossOver or Whisky bottles:** the reasoning and tables apply unchanged. The script expects a Wineskin-style bundle, so give it a wrapper-shaped folder of symlinks:
- `X.app/Contents/SharedSupport/prefix` → the bottle
- `X.app/Contents/SharedSupport/wine/bin/wine` and `wineserver` → a Wine build that honours `WINEPREFIX`

Then point `BRZ_WRAPPER` at `X.app`. Or apply the same per-app keys and DLLs by hand.

**D3D7 and older, and DirectDraw games:** dgVoodoo2 (`DDraw.dll` + `D3DImm.dll`) is the strongest option. For 2D DirectDraw games, Sikarugir's default cnc-ddraw is often enough.

## Worked example: Battle Realms: Zen Edition on a base M1

- **Symptoms:** OpenGL lagged in fights and cutscenes. D9VK/Vulkan was fast but showed a black screen or black units.
- **The game:** 32-bit D3D9 since update 1.58. Exe `Battle_Realms_F.exe`, Steam app `1025600`. `Battle_Realms.ini` `[VideoState]` has `D3D9On12` and `HardwareTL`.
- **Outcome:** with the probe and one-change-per-round triage above, the user reached correct units, smooth cutscenes and a steady 60 FPS in fights (Oct 2026). `~/.brz-mac/triage.log` on that Mac records which round won.

Full story and settings: `references/case-battle-realms.md`. The exact runbook the user followed: `references/playbook-battle-realms.md`.

## Reference files

| File | Read it when |
|---|---|
| `references/troubleshooting.md` | Any symptom: symptom → cause → how to confirm → fix |
| `references/evidence.md` | You need the why: source-level findings, commits, versions, links |
| `references/sikarugir-setup.md` | Building or checking a wrapper: install, exact Configure option names, Steam inside Wine, disk budget |
| `references/toolkit.md` | Every command, environment variable, `dxvk.conf` knob, and where files go |
| `references/case-battle-realms.md` | The worked example in detail |
| `references/playbook-battle-realms.md` | The full step-by-step runbook (fed to an assistant on the user's Mac) |
| `scripts/toolkit/dlls/README.md` | Provenance of the bundled D9VK DLLs (source commit, patches, checksums, rebuild script) |
| `scripts/toolkit/probe/README.md` | What the probe tests and how to run it by hand |
