# Battle Realms: Zen Edition on M1 — consultant's plan & toolkit

| | |
|---|---|
| **Client setup** | MacBook Air/Pro M1 (base: 8 GB RAM, 7/8-core GPU), ~17 GB free, Sikarugir / Porting Kit, Steam build of Zen Edition |
| **Problem** | OpenGL path (WineD3D) lags in battles and cutscenes. Vulkan path (D9VK/DXVK) fixes the lag but gives a black screen or black-shaded units and buildings |
| **Goal** | Vulkan-level performance with correct rendering, kept to ~7 GB of disk |
| **Deliverables** | This plan · [`RESEARCH.md`](RESEARCH.md) (background, sources) · [`brz-mac.sh`](brz-mac.sh) (toolkit) · [`templates/`](templates) · [`tests/`](tests) |

---

## 1. Executive summary

1. **The lag is solved in principle.** Your own test showed it: Vulkan removed it. The OpenGL path is the bottleneck, not the M1. We should **not** go back to tuning OpenGL.
2. **The black output is two separate bugs with separate fixes:**
   - *Fully black screen* = a **presentation** problem (fullscreen, Retina, mode switching). Fix it with window and Retina settings.
   - *Black units on visible terrain* = a **D3D9 → Vulkan → Metal shading/sampling** problem. Fix it with a newer DXVK D3D9 build, MoltenVK swizzle emulation, `dxvk.conf` settings, and the game's `HardwareTL` switch.
3. **There's a route that avoids Vulkan entirely:** dgVoodoo2 (D3D9 → D3D11) + DXMT (D3D11 → Metal). It's our fallback if Option A can't produce correct units.
4. **D3DMetal/GPTK can't help this game.** It only handles 64-bit DX11/12, and Battle Realms is a 32-bit DX9 game. Stop testing it.
5. **Expectation:** after the renderer fix, large 4v4 fights will still dip, because the game runs its simulation on one thread under Rosetta 2. Plan for a **stable 45–60 FPS cap**, not uncapped FPS.

## 2. Diagnosis — hypotheses and how we test each

| # | Hypothesis for black units | Confidence | Cheap test | Fix if confirmed |
|---|---|---|---|---|
| H1 | MoltenVK missing **texture swizzles** for old D3D9 formats | Low-medium (Apple Silicon has native swizzle; cheap to rule out) | `launch` (sets `MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE=1`) vs. launching from Finder | Always launch with the variable, or add it to the wrapper's environment |
| H2 | **Sampler aliasing** unsupported on Metal | Medium-high | `profile dxvk` with `d3d9.deAliasedSamplers = True` vs `False` | metalsharp DXVK + the conf key |
| H3 | **Software T&L emulation** lighting bug (`HardwareTL=0`) | Medium | `ini set HardwareTL 1` vs `0` | Keep whichever renders correctly |
| H4 | **NaN from float rules** in old shaders | Medium | `conf dxvk set d3d9.floatEmulation Strict` | Keep `Strict` (or `True` if FPS cost) |
| H5 | Older D3D9 code in the wrapper's **D9VK** | Medium | `profile wrapper` vs `profile dxvk` | Use metalsharp DLL per-game |
| H6 | The game's own **material bug** (also happens on Windows) | Low-medium | Do units turn black only after alt-tab or a long session? Same in `wined3d`? | Update to the latest patch, restart the match; not fixable on our side |
| H7 | MoltenVK version too old for DXVK 3.1 | Low | `profile dxvk` + the release's bundled MoltenVK | Swap the dylib (back up first) |

| # | Hypothesis for fully black screen | Confidence | Test | Fix |
|---|---|---|---|---|
| S1 | Exclusive fullscreen / mode change refused | High | `launch --hud`: HUD visible over black means frames are presenting | Retina off; game resolution = display mode; virtual desktop if offered |
| S2 | DXVK never loaded (wrong arch, override missing) | Medium | `doctor` shows `d3d9.dll (i386)` + `"d3d9"="native"` | `profile dxvk` handles both |
| S3 | `HardwareTL` / display init failure | Low | `ini set HardwareTL 0` | Per the Steam community fix |

## 3. Test plan (decision tree)

Each step changes **one** variable. After each run, log it: `./brz-mac.sh bench "Skirmish 4 AI, 10 min" AVG MIN y/n y/n "note"`.
Use the same map and AI count every time so the numbers can be compared.

```
0. doctor ──► fix anything red (Rosetta, Low Power Mode, <8 GB free)
1. profile wined3d            → baseline: correct image, slow   (proves the save/map renders correctly)
2. profile wrapper (D9VK on)  → your known-bad state, now with launch (swizzle on)
      units OK? ──yes──► done: H1 confirmed (keep launching via script)
3. profile dxvk <metalsharp>  → deAliasedSamplers + floatEmulation Strict
      units OK? ──yes──► done (H2/H4/H5)
4. ini set HardwareTL 1  (then 0)                                  (H3)
5. conf dxvk: forceSamplerTypeSpecConstants True → shaderModel 2
6. bundled MoltenVK from the metalsharp release                    (H7)
7. profile dgvoodoo <2.79.x>  (Configure: DXMT on, DXVK off) → then dgVoodoo 2.54
8. still failing → logs → file issues (metalsharp/DXVK-MacOS, Sikarugir) with the zip
```

**Acceptance criteria:** units and buildings correctly shaded for a full 20-minute skirmish, ≥ 45 FPS average and ≥ 25 FPS minimum in the 4-AI benchmark, cutscenes without audio/video drift, and total wrapper size ≤ 8 GB.

## 4. Toolkit — `brz-mac.sh`

A single bash script (works with macOS's built-in bash 3.2, no installs needed). It only changes things **for this game**: per-app DLL overrides, DLLs in the game folder, the game's ini. Everything is backed up to `~/.brz-mac/backups/` before the first change, and `restore` undoes it all.

```bash
# one-time
cd ~/Downloads/battle-realms-zen-macos && chmod +x brz-mac.sh
export BRZ_WRAPPER="$HOME/Applications/Sikarugir/Battle Realms.app"   # optional; auto-detected

./brz-mac.sh doctor                         # machine + wrapper + renderer state
./brz-mac.sh profile dxvk ~/Downloads/DXVK-MacOS-v3.1-MetalSharp
./brz-mac.sh ini set HardwareTL 1
./brz-mac.sh launch --hud                   # quiet Steam + DXVK HUD + MoltenVK swizzle fix
./brz-mac.sh bench "Skirmish 4 AI" 57 33 y y "dxvk, HTL=1"
./brz-mac.sh conf dxvk set d3d9.forceSamplerTypeSpecConstants True
./brz-mac.sh profile dgvoodoo ~/Downloads/dgVoodoo2_79_3
./brz-mac.sh logs                           # zip for a bug report
./brz-mac.sh restore                        # back to how it was
```

| Command | What it does |
|---|---|
| `doctor` | macOS version, RAM, Rosetta, Low Power Mode, battery, free disk, wrapper/wine/game paths, ini values, DLLs in the game folder (and whether they're i386), active overrides |
| `profile wrapper\|wined3d\|dxvk DIR\|dgvoodoo DIR` | Switches the game's D3D9 implementation. Picks the **32-bit** DLL automatically by reading the PE header, and refuses x64-only DLLs (they'd silently fail to load in this 32-bit game) |
| `ini …` / `conf dxvk\|dgvoodoo …` | Reads or edits `Battle_Realms.ini` / `dxvk.conf` / `dgVoodoo.conf`, keeping Windows line endings and the file's own `key = value` spacing |
| `launch [--hud] [--debug]` | Starts Steam with `-silent -nofriendsui -nochatui -noverifyfiles -applaunch 1025600`, plus the MoltenVK swizzle and MSync env vars. `--debug` writes DXVK, MoltenVK and Wine DLL-load logs to `~/.brz-mac/logs`. Steam args can be overridden with `BRZ_STEAM_ARGS` |
| `bench …` | Appends a row to `~/.brz-mac/bench.csv` (records the active profile and `HardwareTL` automatically) |
| `disk [--clean]` | Shows wrapper and cache sizes. `--clean` deletes only the Steam download/shader/http caches inside the wrapper (asks first) |
| `kill`, `logs`, `restore` | Stop the wrapper's Wine processes · zip diagnostics · undo everything |

**Important launch detail:** env vars only reach the game if **Steam isn't already running**. If Steam is running, `-applaunch` hands off to the existing Steam and the game starts without our settings. The script warns you about this. `dxvk.conf` is read from the game folder, so the conf settings apply however you launch.

**Verified here:** shellcheck clean. 38/38 tests pass against a mock wrapper (`bash tests/test-brz-mac.sh`), covering profile switching, i386 DLL selection and x64 rejection, registry overrides, CRLF-safe ini edits, benchmarking, launch command construction, logs, and restore. **Not verified:** a real Mac + Sikarugir run. Run `doctor` first and send me its output if anything looks off.

## 5. Resource plan (base M1, 17 GB free)

| Resource | Budget | Notes |
|---|---|---|
| Disk | ~7 GB for one wrapper (engine 1–1.5 GB + Steam 1–1.5 GB + game ~4 GB) | **One wrapper only.** Profiles switch renderers inside it. Keep ≥ 8–10 GB free for swap and Rosetta caches |
| RAM | 8 GB shared CPU/GPU | Close browsers and Electron apps. `doctor` flags low disk, which shows up as swap stutter |
| CPU | 1 busy thread under Rosetta 2 | Charger in, Low Power Mode off, 60 FPS cap (`d3d9.maxFrameRate`) so the GPU doesn't take the CPU's power and heat budget |
| GPU | Plenty for this game on DXVK/Metal | Lower shadows and AA in game first. Retina off |
| Steam | Needed for DRM, should stay idle | Overlay off + `-silent -nofriendsui -nochatui` (the script does this) |

## 6. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| metalsharp DXVK-MacOS is brand new (1 release, 1 maintainer) | Regressions, abandonment | Per-game install only; the D9VK toggle stays as the comparison; `restore` is one command |
| Sikarugir engine update resets the prefix's DLLs/registry | Profile silently lost | `doctor` shows the active profile and overrides; re-run `profile …` after updates |
| Swapping the MoltenVK dylib breaks other games in the wrapper | Other games break | One wrapper for this game only; back up the dylib first |
| dgVoodoo2's D3D9 support is partial | Option B may not render | It's the fallback; try 2.79.x then 2.54 |
| Zen Edition's own black-texture bug | Some black units remain on any renderer | Check the same scene in `wined3d`; if it's black there too, it's the game, not the port |
| Running the script while the game is open | Registry write races | The script detects running Wine processes and asks before continuing |

## 7. What I'd watch in the next 3–6 months

- **KosmicKrisp** (Mesa Vulkan-on-Metal, Vulkan 1.3 conformant, macOS 26/Metal 4) shipping as a selectable driver in Sikarugir or CrossOver. That would likely remove H1/H2/H7 entirely.
- **DXMT's D3D9 frontend + i386 builds** and **d9mt** (D3D9 straight to Metal). These are the long-term best fit for this game once they're past "tested on one title".
- Zen Edition patches touching the renderer (1.60 already reduced the black-texture bug).

## 8. What I need from you to close this out

1. `./brz-mac.sh doctor` output (paste it, or the zip from `logs`).
2. Your bench CSV after steps 1–3 of the test plan.
3. Screenshots: one of black units, and one with `launch --hud` running.

With those I can tell which hypothesis it is, rather than guessing.
