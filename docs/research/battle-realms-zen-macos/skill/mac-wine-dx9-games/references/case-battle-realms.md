# Worked example: Battle Realms: Zen Edition on a base M1

## The situation

- **Machine:** MacBook M1 base model (8 GB unified memory, 7/8-core GPU), ~17 GB free disk.
- **Wrapper:** Sikarugir / Porting Kit. Steam inside the wrapper, with the overlay disabled and a quiet launch.
- **Game:** Battle Realms: Zen Edition (Steam `1025600`), 32-bit, Direct3D 9 since update 1.58.
- **Symptoms before:**
  - OpenGL (WineD3D) path: correct picture but lag in big battles, when more units arrive, and in cutscenes.
  - Vulkan path: no lag, but either a fully black screen or units/buildings shaded black.
  - D3DMetal/"DX3D" toggles: no change, which is expected for a 32-bit D3D9 game.

## The reasoning, in order

1. **"Vulkan removed the lag"** → the M1 is fast enough. Make the fast path correct instead of tuning OpenGL.
2. **Black screen and black units are different bugs:**
   - black screen = presentation: fullscreen, mode switch, Retina
   - black units = texture/shading inside the D3D layer
3. **Identify the stack:** 32-bit D3D9 means D3DMetal and DXMT alone are irrelevant. The candidates are D9VK, DXVK 3.x, dgVoodoo2 + DXMT, and WineD3D.
4. **Read the source:**
   - Sikarugir's d9vk fixed 16-bit texture formats in June 2026, but no release ships it.
   - D9VK's fixed function draws a stage with no bound texture as black.
   - So a failed 16-bit unit texture renders exactly as "black units on correct terrain".
5. **Read the game's ini:** `D3D9On12=1` requests a layer nothing on a Mac implements. Setting it to `0` removes an unknown.
6. **Build what's missing:**
   - the 32-bit D9VK with the fix
   - a diagnostic build that logs every texture format and blend stage
   - a D3D9 probe that reproduces the game's features and reads the pixels back
7. **Experiment safely:**
   - per-game Wine keys and DLLs only, with backups and `restore`
   - the probe first, then one-change-per-round in-game triage, with each round's log analyzed automatically
8. **Plan for the remaining CPU-bound part:** the game's simulation runs on one thread under Rosetta 2. Use GPU lighting (`HardwareTL=1`), a 60 FPS cap, Low Power Mode off, and the charger in.

## What the user ran

`PLAYBOOK.md` (this skill's `references/playbook-battle-realms.md`), fed to Claude Code in the Mac terminal:

```bash
git clone -b research/battle-realms-zen-macos https://github.com/monmon891awesome/understand-anything.git ~/brz
cd ~/brz/docs/research/battle-realms-zen-macos
bash brz-mac.sh doctor
bash brz-mac.sh probe
bash brz-mac.sh triage          # or the assistant-driven rounds
bash brz-mac.sh report
```

## Outcome (user-confirmed, October 2026)

> "it worked, 60 fps buttery smooth cutscenes and fights and everything"

The triage stops at the first round that renders correctly at ≥ 45 FPS. The deciding round is recorded on that Mac in `~/.brz-mac/triage.log` (and `bench.csv`, `report-*.md`). The flat 60 FPS matches the 60 FPS cap in the installed `dxvk.conf` and the display's 60 Hz vsync. **Once the user shares the winning round, record it here** ("Winning round: …, ini: …") so the next run can start from it.

## Settings that matter for this game

| Where | Setting | Value |
|---|---|---|
| `Battle_Realms.ini` `[VideoState]` | `D3D9On12` | `0` |
| | `HardwareTL` | `1` if it renders correctly (less CPU), else `0` |
| | `Fullscreen` | `1`, or `0` if the screen is black |
| | `Width` / `Height` | `1440` / `900` (13-inch M1 scaled size) |
| `dxvk.conf` (game folder) | `dxvk.enableAsync`, `d3d9.floatEmulation`, `d3d9.maxFrameRate` | `True`, `Strict`, `60` |
| Wine (wrapper-wide) | `RetinaMode` | `N` if the screen is black (`retina off`) |
| Configure | *Limit to 1 CPU core* off, *msync* on, *D3DMetal* off, *Performance HUD* off after testing | |
| Steam | overlay off; *GPU accelerated rendering in web views* off; *Shader Pre-caching* off | |
