# Battle Realms: Zen Edition on a base M1: the whole playbook

**Everything you need to do, in order, in one file.** It works two ways:

- **You follow it by hand** in Terminal, or
- **you feed it to an AI assistant running in your Mac's terminal** (for example Claude Code: `claude "Read PLAYBOOK.md and walk me through it, one step at a time"`) and decide each step together.

Total time: about 45–60 minutes. **Nothing here deletes anything.** Every change is per game, backed up first, and `bash brz-mac.sh restore` undoes it all.

---

## Contents

1. [Brief for the AI assistant](#1-brief-for-the-ai-assistant-read-this-first)
2. [The situation in plain words](#2-the-situation-in-plain-words)
3. [Step 0: Get the toolkit](#3-step-0-get-the-toolkit-2-min)
4. [Step 1: Check the setup (`doctor`)](#4-step-1-check-the-setup-doctor-1-min)
5. [Step 2: Probe every renderer (`probe`)](#5-step-2-probe-every-renderer-probe-510-min-unattended)
6. [Step 3: In-game rounds (`triage`)](#6-step-3-in-game-rounds-2030-min)
7. [Step 4: Lock in the winner and play](#7-step-4-lock-in-the-winner-and-play)
8. [Step 5: Report](#8-step-5-report)
9. [Decision tree on one screen](#9-decision-tree-on-one-screen)
10. [Troubleshooting](#10-troubleshooting-symptom--cause--confirm--fix)
- [Appendix A: Build a clean wrapper (only if needed)](#appendix-a-build-a-clean-wrapper-only-if-needed)
- [Appendix B: Command reference](#appendix-b-command-reference)
- [Appendix C: Settings reference](#appendix-c-settings-reference)
- [Appendix D: Files, safety, undo](#appendix-d-files-safety-undo)
- [Appendix E: Why we think this (evidence)](#appendix-e-why-we-think-this-evidence)

---

## 1. Brief for the AI assistant (read this first)

**Who and what:** you're helping the user, on this MacBook, fix *Battle Realms: Zen Edition* (Steam app `1025600`, a **32-bit Direct3D 9** game) running in a **Sikarugir** Wine wrapper on a **base M1** (8 GB RAM, ~17 GB free disk).

**History:**
- The OpenGL path (WineD3D) gives a correct picture but lags in battles and cutscenes.
- The Vulkan path (D9VK → MoltenVK) has **no lag**, but either the **whole screen is black** or **units/buildings are shaded black**.

**The toolkit** in this folder was built for exactly this:
- `brz-mac.sh`: one bash script.
- Bundled 32-bit D9VK DLLs, including one with an unreleased upstream fix for 16-bit textures.
- `bin/brz-probe.exe`: a D3D9 test program.

The script changes **only this game's** settings inside the wrapper and backs up everything first.

**"Done" means:**
- Units and buildings correctly shaded through a 20-minute skirmish.
- At least **45 FPS average** and **25 FPS minimum** in a 4-AI fight.
- Cutscenes without drift.
- Wrapper ≤ 8 GB.

**Rules:**
1. Run everything as `bash brz-mac.sh …` from the toolkit folder (`~/brz/docs/research/battle-realms-zen-macos`), or use the full path `bash ~/brz/docs/research/battle-realms-zen-macos/brz-mac.sh …`. The script finds its own files from any directory.
2. **Your shell is non-interactive,** so the script's `[y/N]` prompts can't be answered. Before `probe`, `profile`, `retina` or `restore`:
   - make sure the game and Steam are closed (`bash brz-mac.sh kill`);
   - then prefix the command with `BRZ_YES=1`.
   If your tool doesn't keep environment variables between commands, put `BRZ_YES=1` (and `BRZ_WRAPPER=…`, if needed) on **every** command line.
3. **`triage` asks the user questions.** Either ask the user to run it themselves in a separate Terminal window, or drive the same rounds yourself with **Step 3, option B** (non-interactive commands, and you ask the user the 5 questions in chat).
4. **`probe` takes 5–10 minutes and flashes a small window** on the user's screen. Tell them before you start. Run it with a long timeout (≥ 10 min) or in the background. If that's impossible, run `probe --quick`, or split it: `probe wrapper wined3d d9vk`, then `probe dxvk dgvoodoo`.
5. **Ask the user before anything that needs their hands or eyes:** playing the game, opening the wrapper's *Configure* app, installing software, entering a password.
6. **One change per round,** recorded with `bench`. Decide with the tables in this file; don't guess.
7. **Never delete or move** the wrapper, Steam, game files or saves. **Never edit** `drive_c/windows/system32` or `syswow64`. To undo: `BRZ_YES=1 bash brz-mac.sh restore`.
8. **Only install Sikarugir from its Homebrew tap** (`brew install --cask Sikarugir-App/sikarugir/sikarugir`). **sikarugir.com is not theirs**: their own README says to scan for malware if you came from it.
9. **When done or stuck:** run `bash brz-mac.sh report`, tell the user the winning configuration (Step 4), and point them to the report file.

---

## 2. The situation in plain words

- **Leading suspect for the black units (high confidence):**
  - Old D3D9 games keep unit textures in **16-bit formats** (A4R4G4B4, A1R5G5B5, R5G6B5).
  - Sikarugir's D9VK got a fix for those formats in **June 2026**, but **no D9VK release includes it yet**.
  - When such a texture fails to load, nothing is attached to the unit. D9VK then draws it **black**, with correct shape and lighting, which is exactly the symptom.
  - The bundled `d9vk` profile contains that fix.
- **Other suspects, each tested one at a time:**
  - `D3D9On12=1` in the game's ini (no Mac layer supports what it asks for, so `0` removes an unknown)
  - the game's `HardwareTL` lighting switch
  - a MoltenVK difference (the CodeWeavers MoltenVK option in Configure)
  - Zen Edition's own long-known black-texture bug (it also happens on Windows)
- **The whole-screen-black problem** is separate: it's about how the picture reaches the screen (fullscreen, Retina). Fix: windowed mode and Retina off for the game.
- **The "lag when more units come in"** is likely new effects building their shaders. The provided `dxvk.conf` switches on background building (`dxvk.enableAsync`). **Big 4v4 fights will still dip a bit:** the game's simulation runs on one CPU core through Rosetta 2. Aim for a **steady 45–60 FPS**, not uncapped.

---

## 3. Step 0: Get the toolkit (2 min)

```bash
git clone -b research/battle-realms-zen-macos https://github.com/monmon891awesome/understand-anything.git ~/brz
cd ~/brz/docs/research/battle-realms-zen-macos
```

- Already cloned? `cd ~/brz && git pull && cd docs/research/battle-realms-zen-macos`.
- No git? On GitHub, open the branch `research/battle-realms-zen-macos`, use **Code → Download ZIP**, unzip it, and `cd` into `docs/research/battle-realms-zen-macos`.

The script looks for wrappers in `/Applications`, `~/Applications` and their `Sikarugir` / `Porting Kit` subfolders. This lists every Wine wrapper on the Mac:

```bash
find ~/Applications /Applications -maxdepth 3 -type d -name "*.app" \
  -exec test -d "{}/Contents/SharedSupport/prefix/drive_c" \; -print 2>/dev/null
```

If it finds more than one, or none in those places, tell the script which one:

```bash
export BRZ_WRAPPER="$HOME/Applications/Sikarugir/Battle Realms.app"   # use your wrapper's real path
```

---

## 4. Step 1: Check the setup: `doctor` (1 min)

Quit the game **and Steam** first, then:

```bash
bash brz-mac.sh doctor
```

| What doctor shows | What it means | What to do |
|---|---|---|
| `No Wine wrapper found` | It looked in the usual folders and found none | Set `BRZ_WRAPPER` (Step 0), or build one ([Appendix A](#appendix-a-build-a-clean-wrapper-only-if-needed)) |
| `Battle Realms not found in the prefix` | The game isn't installed in this wrapper | Install it via Steam *inside* the wrapper, start it once, quit |
| `! Rosetta 2 missing` | x86 code can't run | `softwareupdate --install-rosetta --agree-to-license` (may ask for your password) |
| `! Low Power Mode is ON` | CPU is throttled, so big fights suffer | System Settings → Battery → Low Power Mode → **Never** |
| `! On battery` | Clocks drop | Plug in the charger |
| `! Free disk: … (<8 GB …)` | macOS will swap and stutter | `bash brz-mac.sh disk --clean`, then free more space |
| `syswow64/d3d9 … Wine placeholder` | The wrapper runs this game on WineD3D/OpenGL (the laggy path) | Expected on older macOS. The `d9vk` profile bypasses it. |
| `syswow64/d3d9 … DXVK/D9VK` **without** `+16-bit-promotion` | The wrapper's D9VK predates the 16-bit fix | **Prime suspect.** Step 2 will confirm. |
| `ini D3D9On12  1` | The game requests D3D9-on-12 | Tested at `0` in round 3 |
| `ini HardwareTL  0` or `1` | CPU lighting (`0`) or GPU lighting (`1`) | Tested both ways in round 4 |
| `MoltenVK 1.x.y` below **1.3.0** | DXVK 3.x (`dxvk` profile) can't start | Skip the `dxvk` column/round |
| `videos 0 .bik, 0 .avi …` | Cutscenes are in-engine | Cutscene lag = the same fix as battle lag |
| `videos N .avi/.wmv …` | Cutscenes are video files | If they stutter, that's a codec issue, not the renderer |
| `game d3d9.dll …` or `….brz-orig` | A DLL in the game folder (`.brz-orig` = the game's own copy, stashed by the script) | Nothing; the script manages these |

---

## 5. Step 2: Probe every renderer: `probe` (5–10 min, unattended)

`probe` runs a small test program inside your wrapper with each graphics layer in turn. It doesn't touch the game. Each run draws 31 known patterns three ways (hardware vertex processing, software vertex processing, D3D9-on-12), covering:
- 16-bit, compressed and alpha textures
- the team-colour blend
- fixed-function lighting
- alpha test/blend
- render-to-texture

It reads the pixels back and reports `PASS`, `BLACK`, `NOT DRAWN` (dropped), `WRONG`, or `SKIP`. It also measures a "many small units" benchmark.

Optional, for a fuller comparison, download the two alternative layers first (~10–40 MB each):

```bash
bash brz-mac.sh fetch dxvk         # metalsharp DXVK-MacOS 3.x (adds the "dxvk" column)
bash brz-mac.sh fetch dgvoodoo     # dgVoodoo2 2.87.5 (adds "dgvoodoo"; needs DXMT on in Configure)
```

Then, with Steam closed:

```bash
bash brz-mac.sh probe              # AI assistant: BRZ_YES=1 bash brz-mac.sh probe   (long timeout)
```

You get a table, also saved as `~/.brz-mac/logs/probe-<time>/matrix.txt`. Rows where everything passed are hidden.

```
test                                     wrapper     wined3d     d9vk        wined3d-vk  dxvk        dgvoodoo
HW: tex A4R4G4B4 managed                 BLACK       ok          ok          ok          ok          ok
HW: team colour A4R4G4B4 alpha=0         BLACK       ok          ok          ok          ok          ok
FAILED (black/none/wrong/err)            6           0           0           0           0           0
benchmark (higher is better)             310 fps     45 fps      305 fps     120 fps     280 fps     150 fps
```

| The table shows | Meaning | Next |
|---|---|---|
| `wrapper` has `BLACK` on 16-bit rows (`tex A4R4G4B4…`, `tex A1R5G5B5…`, `tex R5G6B5…`, `team colour…`) and `d9vk` is all `ok` | **16-bit texture bug confirmed** | Step 3. Round 2 (`d9vk`) should fix it. |
| `d9vk` FAILED `0`, and nothing black anywhere | The bundled D9VK handles every tested feature | Step 3, normal order |
| `BLACK` in **every** Vulkan column (`wrapper`, `d9vk`, `wined3d-vk`, `dxvk`) but `wined3d` all `ok` | A MoltenVK-level problem | Flip **MoltenVK - (CodeWeavers version)** in Configure, then `bash brz-mac.sh probe wrapper d9vk` again. Still black → the `dgvoodoo` route. |
| `dgvoodoo` FAILED `0` | dgVoodoo → DXMT (Metal, no Vulkan) works here | Your fallback, round 7 |
| A column shows `+died`, or a line below says `DIED after… / ABORT… / CRASH… / TIMEOUT…` | That layer can't run in this wrapper | `bash brz-mac.sh analyze` names the failing call. Skip that layer in Step 3. |
| `wined3d-vk` dies or `analyze` says *0 fixed-function texture stages* | WineD3D's Vulkan mode can't do this game | Skip it |
| `dxvk` says *No adapters found* / `ABORT during CreateDevice` | MoltenVK is older than 1.3.0 | Skip `dxvk` |
| Everything `ok` in every column | The black comes from something the probe doesn't cover | Step 3, including the `d9vk-diag` round |

**Benchmark row:** among columns with `FAILED 0`, the highest number is the best candidate. The in-game rounds decide.

**Optional A/B test (5 min):** in the wrapper's Configure, flip *MoltenVK - (CodeWeavers version)*, then run `bash brz-mac.sh probe wrapper d9vk`. If the black rows disappear, CrossOver's MoltenVK fork alone fixes it.

---

## 6. Step 3: In-game rounds (20–30 min)

One change per round. Each round:
1. Set up one configuration.
2. Launch Steam → Battle Realms with an FPS overlay (top-left) and full logging.
3. You play a skirmish for ~3 minutes: a big fight, plus a cutscene if you can.
4. **Quit the game and Steam.**
5. Answer 5 questions:
   1. Did you reach the main menu?
   2. Was the **whole screen** black?
   3. Were **units/buildings** black?
   4. Typical **FPS in the big fight** (overlay number)?
   5. Were **cutscenes** smooth?

### Option A: you run `triage` (interactive)

```bash
bash brz-mac.sh triage            # resumable: run it again to continue; `triage --reset` starts over
```

It runs the rounds below by itself, asks the questions, analyzes each round's log, and stops at the first round that's correct at ≥ 45 FPS.

### Option B: the assistant drives the same rounds (non-interactive)

For each round:

```bash
BRZ_YES=1 bash brz-mac.sh kill                    # Steam/game must be closed
BRZ_YES=1 bash brz-mac.sh profile <PROFILE>       # from the table below
bash brz-mac.sh ini set <KEY> <VALUE>             # only if the round changes the ini
bash brz-mac.sh launch --hud --debug              # starts quiet Steam -> the game
```

Then ask the user to play, quit the game **and** Steam, and answer the 5 questions. Record the round and read its log:

```bash
bash brz-mac.sh bench "Skirmish 4 AI" <AVG_FPS|?> <MIN_FPS|?> <UNITS_OK y/n> <CUTSCENES_OK y/n> "round <name>"
bash brz-mac.sh analyze
```

`UNITS_OK` is `y` when units look **right**, and `n` when they were black.

### The rounds, in order

| # | Round | Setup (option B commands) | What it tests |
|---|---|---|---|
| 1 | `baseline` | `profile wrapper` | Your current setup, reproduced with logging on |
| 2 | `d9vk` | `profile d9vk` | **The 16-bit texture fix** (bundled D9VK) |
| 3 | `d9vk-on12off` | keep `d9vk`; `ini set D3D9On12 0` | No D3D9-on-12 request |
| 4 | `d9vk-htl` | keep both; `ini set HardwareTL <the other value>` | CPU lighting vs GPU lighting |
| 5 | `d9vk-diag` | `profile d9vk-diag` (keep the ini) | **Only if units are still black:** logs every texture format and blend stage |
| 6 | `dxvk` | `fetch dxvk` (once); `profile dxvk` | metalsharp DXVK 3.x (skip if MoltenVK < 1.3.0) |
| 7 | `dgvoodoo` | user: Configure → **DXMT on**; `fetch dgvoodoo` (once); `profile dgvoodoo` | dgVoodoo2 → DXMT: no Vulkan at all |
| 8 | `wined3d-vk` | `profile wined3d-vk` | Separates D9VK bugs from MoltenVK bugs |
| 9 | `wined3d` | `profile wined3d` | The slow-but-correct OpenGL reference |

### Decisions after each round

| Answers | Do this |
|---|---|
| Menu yes, screen fine, units fine, FPS **≥ 45** | **Winner.** Go to Step 4. |
| Correct picture but FPS < 45 | Note it as a candidate, continue to look for a faster round, then apply the speed tips in Step 4 |
| **Whole screen black** | `ini set Fullscreen 0` + `BRZ_YES=1 bash brz-mac.sh retina off`, then **repeat the same round**. Still black → `ini set Width 1440` + `ini set Height 900` and repeat once more. |
| Units black (rounds 2–4) | Continue to the next round |
| Units still black after round 4 | Run round 5 (`d9vk-diag`), then `analyze`. Look for *"reads TEXTURE but no texture is bound"* or *"cannot map (FORMAT)"*. Continue with rounds 6–9. |
| Game didn't reach the menu | `analyze` (look for *a DLL failed to load*, *aborted*, *crashed*), then the next round |
| Units black in **`wined3d` too** | It's Zen Edition's own bug, not the Mac port. Update the game and restart the match. |
| Nothing correct after round 9 | Step 5 (report). The `d9vk-diag` round tells us why. |

---

## 7. Step 4: Lock in the winner and play

**What stays applied after the winning round:**
- the renderer profile (a DLL next to the game exe + a per-game Wine setting)
- `dxvk.conf` in the game folder
- your `Battle_Realms.ini` changes
- per-game Retina mode

So **launching the game normally from the wrapper keeps working** with the fix.

**One catch:** `launch` also sets a few environment variables (MoltenVK texture swizzle, Metal fast-math off, MSync, overlay, logging) that a normal Finder launch doesn't. If the picture is only right when started via the script, use a double-clickable launcher instead:

```bash
cat > ~/Desktop/"Battle Realms.command" <<'EOF'
#!/bin/bash
cd ~/brz/docs/research/battle-realms-zen-macos && bash brz-mac.sh launch
EOF
chmod +x ~/Desktop/"Battle Realms.command"
```

**Speed settings for big fights:**

```bash
bash brz-mac.sh ini set HardwareTL 1                    # if it renders correctly: GPU lighting, less CPU
bash brz-mac.sh conf dxvk set d3d9.maxFrameRate 60      # steady cap, less heat/throttling (d9vk/dxvk winners)
bash brz-mac.sh ini set Width 1440                      # 13-inch M1 scaled size; 1280 x 800 if FPS is tight
bash brz-mac.sh ini set Height 900
```

Also:
- Keep **Low Power Mode off** and the charger in. Close browsers and other heavy apps (8 GB RAM is shared with the GPU).
- In Steam, keep the overlay and *GPU accelerated rendering in web views* **off**.
- In Configure, turn *Performance HUD* back **off** once testing is done.
- The second session in the same build is smoother than the first (the shader cache `Battle_Realms_F.dxvk-cache` builds up next to the game).

**To switch back:** `BRZ_YES=1 bash brz-mac.sh profile wrapper` (the wrapper's own setup) or `BRZ_YES=1 bash brz-mac.sh restore` (everything as it was before the toolkit).

---

## 8. Step 5: Report

```bash
bash brz-mac.sh report     # one markdown file: doctor, ini, dxvk.conf, probe table, rounds, bench, log analysis
bash brz-mac.sh logs       # optional zip of the raw logs
```

It prints the paths (`~/.brz-mac/report-<time>.md`). Share that file, plus **one screenshot** (⌘⇧4) if units were still black, with whoever is helping (the cloud session included).

---

## 9. Decision tree on one screen

```
doctor ── problems marked "!" ? ──yes──► fix them (table in Step 1)
   │
   ▼
probe ──► wrapper BLACK on 16-bit rows, d9vk ok? ──yes──► round 2 (d9vk) ──► units ok? ──yes──► Step 4
   │                                                                              │no
   │                                                                              ▼
   │                                               round 3 (D3D9On12=0) ─► round 4 (HardwareTL flip)
   │                                                                              │ still black
   │                                                                              ▼
   │                                               round 5 (d9vk-diag) + analyze ─► rounds 6-9 ─► report
   │
   ├─ black in every Vulkan column, wined3d ok ──► flip "MoltenVK - (CodeWeavers version)" + probe again
   │                                               └─ still black ──► dgvoodoo route (round 7)
   │
   └─ everything ok ──► rounds 1-9 in order (the diag round explains what the probe can't)

At any round: whole screen black ──► Fullscreen=0 + retina off ──► repeat that round
```

---

## 10. Troubleshooting: symptom → cause → confirm → fix

Commands are `bash brz-mac.sh <command>`.

### Picture problems

| Symptom | Most likely cause | Confirm with | Fix |
|---|---|---|---|
| **Units/buildings black, terrain fine** | 16-bit unit textures fail in D9VK builds older than the June 2026 fix. Nothing gets bound, and the fixed-function stage reads **(0,0,0,1) = black**. | `probe`: `BLACK` on 16-bit rows under `wrapper`, `ok` under `d9vk`. `doctor`: no `+16-bit-promotion` | `profile d9vk` |
| Units black even with `d9vk` | A texture format or blend stage nobody has fixed yet | Round 5 (`d9vk-diag`) + `analyze`: *"reads TEXTURE but no texture is bound"* / *"cannot map (X)"* | `report`; meanwhile try `dgvoodoo` |
| Units black only with `HardwareTL=1` (or only `0`) | The two lighting paths differ | Rounds 3 vs 4; the probe's `light:` rows | Keep the value that renders correctly (`1` is cheaper on the CPU) |
| Black specks or shimmering black spots | NaN from float rules in old shaders | `analyze` shows nothing | `conf dxvk set d3d9.floatEmulation Strict` (already in the template) |
| **Whole screen black**, sound plays | Presentation: fullscreen, mode switch, Retina | `launch --hud`: the overlay draws over black → frames are being presented | `ini set Fullscreen 0`; `retina off`; `Width`/`Height` 1440/900; `ini set D3D9On12 0` |
| Whole screen black, no overlay | The D3D9 layer never loaded, or crashed at start | `analyze`: *a DLL failed to load* / *aborted*; `identify` | `profile wrapper` or `profile d9vk`; `identify` must say **i386** |
| Units **invisible** (not black) | MoltenVK couldn't translate a shader, so those draws are dropped | `analyze`: *could not translate a shader*; probe `none` | `conf dxvk set d3d9.shaderModel 2`, or another layer |
| Black minimap / wrong cursor texture | Zen Edition's own bug (also on Windows) | Same in `wined3d` | Update the game; restart the match |

### Speed problems

| Symptom | Most likely cause | Confirm with | Fix |
|---|---|---|---|
| Hitch whenever **new units/effects** appear | New shaders compiling (SPIR-V → Metal) | Overlay `pipelines` counter jumps at the same moment | `dxvk.enableAsync = True` (in the template; D9VK only); the 2nd session is smoother. Avoid DXVK 3.x here. |
| Low FPS **throughout** big battles | CPU-bound: one simulation thread under Rosetta 2 | FPS low while the probe benchmark was high | `HardwareTL=1`; Low Power Mode off; charger; 60 FPS cap; fewer AIs |
| Everything slow, even menus | Still on OpenGL (WineD3D) | `doctor`/`identify`: `Wine builtin`; no overlay with `--hud` | `profile d9vk` |
| **Cutscene** lag | In-engine: same as battles. Video files: CPU/codec path | `doctor` → `videos …` | In-engine: battle fixes. AVI/WMV: Wine codecs, or skip intros |
| Stutter after an hour | Heat throttling or memory pressure | Activity Monitor → Memory Pressure | 60 FPS cap; close browsers; keep 8–10 GB free |
| "Lag" only online | Network desync (on every OS) | FPS fine, units rubber-band | Not a port problem |

### Start-up problems

| Symptom | Most likely cause | Confirm with | Fix |
|---|---|---|---|
| `ABORT during CreateDevice` / *No adapters found* | DXVK 3.x needs MoltenVK ≥ 1.3.0 | `analyze`: *lacks 'khrLoadStoreOpNone'* | Use `d9vk` |
| `DIED after: …` + *Assertion failed … winevulkan …* | Wine's Vulkan bridge aborts when MoltenVK fails a call | `analyze` names the call | Another layer for the game; `report` |
| `wined3d-vk`: *0 texture stages* | WineD3D-Vulkan lacks fixed function | `analyze` | Skip `wined3d-vk` |
| dgVoodoo `CRASH during CreateDevice` | DXMT off, or an incompatible version | probe column `dgvoodoo` | Configure → DXMT on; `fetch dgvoodoo 2.79.3` (then `2.54`); probe again |
| "Could not find supported display mode" | Mode list mismatch | — | `ini set HardwareTL 0`; a listed resolution |
| "Display Initialize" error | — | — | `ini set HardwareTL 1` |
| Game won't start after a profile change | Wrong-architecture DLL or a missing dependency | `identify` (**i386**); `analyze` | `profile wrapper`; `restore` |
| Steam keeps updating / won't open | Steam client inside Wine | — | Open Steam once from the wrapper, let it finish, then `launch` |
| `launch` settings don't seem to apply | Steam was already running | `launch` warns about this | `kill`, then `launch` |

---

## Appendix A: Build a clean wrapper (only if needed)

Only if `doctor` finds no usable wrapper, or you want to start fresh. Reuse the existing one when you can: disk space is tight.

**Install (official only):**

```bash
/usr/sbin/softwareupdate --install-rosetta --agree-to-license
brew upgrade
brew trust Sikarugir-App/sikarugir
brew install --cask Sikarugir-App/sikarugir/sikarugir
```

Sikarugir needs macOS 14.6+. Per its README, D9VK is the default D3D9 path on "Apple Silicon & macOS Tahoe"; older macOS runs D3D9 on OpenGL.

**Create:** open **Sikarugir Creator** → pick the newest engine (it must support 32-bit/WoW64; current ones do) → name it `Battle Realms`. It lands in `~/Applications/Sikarugir/`.

**Configure (exact option names):**

| Option | Set to | Why |
|---|---|---|
| *DirectX to Metal translation layer - (DXMT)* | on | Needed only for the `dgvoodoo` route; harmless otherwise |
| *Direct3D to Metal translation layer - (D3DMetal)* | off | 64-bit D3D11/12 only, so it never helps this game |
| *DirectX to Vulkan translation layer - (DXVK)* | off | D3D10/11 only; D3D9 comes from D9VK or our per-game DLL |
| *MoltenVK - (CodeWeavers version)* | try both | The A/B test in Step 2 |
| *MoltenVK FastMath* | off while debugging | NaNs can cause black pixels |
| *mach semaphore-based synchronization (msync)* | on | Less CPU overhead (then *esync* off) |
| *Limit to 1 CPU core* | **off** | It would cripple big battles |
| *Performance HUD - (DXVK/Metal)* | on while testing | Overlay even from Finder |
| *Always make Log file, not only when doing a Test Run* | on | More for `analyze` to read |
| *Disable winedbg dialog* | on | Crashes go to the log instead of hanging |

**Steam inside the wrapper:**
1. Configure → **Install Software** → *Choose Setup Executable* → `SteamSetup.exe` from steampowered.com (install to `C:`).
2. Start Steam once and let it fully update. Log in, "remember me".
3. Steam settings:
   - **In Game:** overlay off
   - **Interface:** *GPU accelerated rendering in web views* off
   - **Downloads:** *Shader Pre-caching* off
4. Install the game, start it **once** (this creates `Battle_Realms.ini`), and quit.
5. Optional: Configure's *Windows EXE* = `C:\Program Files (x86)\Steam\steam.exe` with flags `-silent -nofriendsui -nochatui -applaunch 1025600`, so double-clicking the wrapper starts the game directly.

**Disk:** one wrapper ≈ 7 GB (engine 1–1.5 GB + Steam 1–1.5 GB + game ~4 GB). Keep 8–10 GB free. `bash brz-mac.sh disk` shows the breakdown, and `disk --clean` drops Steam caches.

---

## Appendix B: Command reference

All commands are `bash brz-mac.sh <command>`.

| Command | What it does |
|---|---|
| `doctor` | Checks the Mac, wrapper, game, ini, cutscene files, which `d3d9.dll` really loads, and per-game Wine settings |
| `probe [--quick] [profiles…]` | Runs the D3D9 test under each renderer and prints a comparison table (`~/.brz-mac/logs/probe-*/matrix.txt`) |
| `triage [--reset]` | Guided in-game rounds, one change each; asks 5 questions; resumable |
| `report` | Writes one markdown file with everything (`~/.brz-mac/report-*.md`) |
| `profile NAME [DIR]` | Switches the game's D3D9 layer: `wrapper`, `wined3d`, `wined3d-vk`, `d9vk`, `d9vk-diag`, `dxvk`, `dgvoodoo` |
| `ini [show \| get K \| set K V]` | Reads/edits `Battle_Realms.ini` (new keys go into the right `[section]`) |
| `conf dxvk\|dgvoodoo [show \| set K V]` | Edits `dxvk.conf` / `dgVoodoo.conf` in the game folder |
| `retina on\|off\|default` | Per-game Retina mode (`off` is the usual black-screen fix) |
| `launch [--hud] [--debug]` | Quiet Steam → the game, with the overlay (`--hud`) and full logging (`--debug`) |
| `analyze [files…]` | Explains what the latest logs say (problems / warnings / facts) |
| `identify [files…]` | What a `d3d9.dll` really is (Wine / D9VK + traits / DXVK / dgVoodoo, and its architecture) |
| `fetch dxvk\|dgvoodoo [version]` | Downloads metalsharp DXVK-MacOS or dgVoodoo2 (default 2.87.5) into `~/.brz-mac/downloads` |
| `bench SCENARIO AVG MIN UNITS_OK CUTSCENES_OK [notes]` | Adds a row to `~/.brz-mac/bench.csv` (records the profile and ini automatically) |
| `kill` | Stops all Wine processes of this wrapper (Steam and the game) |
| `disk [--clean]` | Shows space use; `--clean` removes Steam download/shader/web caches and old logs |
| `logs` | Zips the raw logs |
| `restore` | Puts everything back as it was before the toolkit's first change |

**Environment variables:**

| Variable | Use |
|---|---|
| `BRZ_WRAPPER` | Path to the wrapper `.app` |
| `BRZ_GAME_DIR`, `BRZ_GAME_EXE` | Override game folder/exe detection |
| `BRZ_DXVK_DIR`, `BRZ_DGV_DIR` | Use your own extracted DXVK-MacOS / dgVoodoo2 folders |
| `BRZ_YES=1` | Answer yes to every prompt (for AI assistants and scripts) |
| `BRZ_STEAM_ARGS` | Replace the default Steam flags |
| `BRZ_MVK_DIR` | Experimental: use a different MoltenVK |
| `BRZ_HOME` | Where results go (default `~/.brz-mac`) |
| `BRZ_MATRIX_ALL=1` | Show every probe row, not just the interesting ones |

---

## Appendix C: Settings reference

**`Battle_Realms.ini`** (in the game folder):

| Section | Key | Values / advice |
|---|---|---|
| `[VideoState]` | `Width`, `Height` | Your display's scaled size: 1440 × 900 on a 13-inch M1 (1280 × 800 if FPS is tight) |
| | `Depth` | 32 |
| | `Fullscreen` | `1`, or `0` (windowed) if the screen is black |
| | `HardwareTL` | `1` = GPU lighting (less CPU). `0` only if `1` renders wrong or won't start. |
| | `D3D9On12` | `0`: no Mac layer implements D3D9-on-12 |
| | `Monitor`, `Adapter` | Leave at `0` |
| `[Sound]` | `Enabled`, `NumSFXChannels`, `SoundTimerPeriod`, `SoundTimerResolution` | Leave as is |

**`dxvk.conf`** (installed next to the game with the `d9vk`/`dxvk` profiles):

| Key | Default here | When to change |
|---|---|---|
| `d3d9.floatEmulation` | `Strict` | `True` if Strict costs FPS and nothing turns black |
| `d3d9.deAliasedSamplers` | `True` | DXVK 3.x only; ignored by D9VK |
| `d3d9.forceSamplerTypeSpecConstants` | (commented) | Try `True` if units are still black |
| `d3d9.shaderModel` | (commented) | Try `2` if units are invisible/black |
| `dxvk.enableAsync` | `True` | D9VK: shaders build in the background (fewer hitches) |
| `dxvk.enableStateCache` | `True` | Keeps compiled pipelines between sessions |
| `d3d9.maxFrameRate` | `60` | Steady cap for the M1 |
| `d3d9.maxFrameLatency`, `d3d9.presentInterval` | `1`, `1` | Leave |
| `dxvk.hud` | (commented) | `fps,frametimes,drawcalls,pipelines,version,api` for an overlay without the script |

**Environment the script sets** for `launch`/`probe`:
- `MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE=1`, `MVK_CONFIG_FAST_MATH_ENABLED=0`, `WINEMSYNC=1`
- with `--hud`: `DXVK_HUD`
- with `--debug`: `DXVK_LOG_LEVEL=info`, `MVK_CONFIG_LOG_LEVEL=3`, `WINEDEBUG=err+all,warn+d3d,+loaddll`, and `DXVK_LOG_PATH=Z:\…\.brz-mac\logs` (Wine needs a Windows-style path there)

---

## Appendix D: Files, safety, undo

| Where | What |
|---|---|
| `~/brz/docs/research/battle-realms-zen-macos/` | The toolkit (script, bundled DLLs, probe, docs) |
| `~/.brz-mac/backups/original/` | Your ini, Wine registry and any game-folder DLLs **before the first change** |
| `~/.brz-mac/backups/<time>-<label>/` | A snapshot before each later change |
| `~/.brz-mac/logs/` | Launch logs, DXVK logs, probe runs (`probe-<time>/matrix.txt`) |
| `~/.brz-mac/downloads/` | `fetch` results (DXVK-MacOS, dgVoodoo2) |
| `~/.brz-mac/bench.csv`, `triage.log`, `report-*.md` | Your rounds and reports |

- **What the script changes:**
  - files next to the game exe (and puts back any it replaced: originals become `*.brz-orig` until the next switch)
  - per-game Wine registry keys (`AppDefaults\Battle_Realms_F.exe\…`)
  - `Battle_Realms.ini`

  **Never** system32/syswow64 or other games.
- **Undo everything:** `bash brz-mac.sh restore` (assistant: `BRZ_YES=1 bash brz-mac.sh restore`).
- **Bundled DLLs:** checksums are in `dlls/SHA256SUMS`. They're rebuildable from public source with `tools/build-d9vk.sh`; provenance is in `dlls/README.md`.

---

## Appendix E: Why we think this (evidence)

- **16-bit fix not released:** [Sikarugir-App/d9vk](https://github.com/Sikarugir-App/d9vk/tree/moltenvk-version) commits `a9e0a68` and `f229921` (June 2026) add *software promotion* for A4R4G4B4/A1R5G5B5/R5G6B5. The newest [release](https://github.com/Sikarugir-App/d9vk/releases) is `v1.10.3-20250511`.
- **Why failed textures look black:** D9VK's fixed-function code returns `(0,0,0,1)` for a texture stage with nothing bound.
- **`D3D9On12`:** [DXVK](https://github.com/doitsujin/dxvk/blob/master/src/d3d9/d3d9_main.cpp) logs *"9On12 functionality is unimplemented"* and falls back. [Wine master](https://github.com/wine-mirror/wine/blob/master/dlls/d3d9/d3d9_main.c) also falls back, and Wine 9.0 doesn't export the function at all.
- **DXVK 3.x needs MoltenVK ≥ 1.3.0:** it requires `VK_KHR_load_store_op_none`, which [MoltenVK added in v1.3.0](https://github.com/KhronosGroup/MoltenVK/blob/main/MoltenVK/MoltenVK/Layers/MVKExtensions.def) (2025-04-28). Reproduced: "No adapters found" + abort.
- **Async:** D9VK is the DXVK 1.10.3 *async* branch (`dxvk.enableAsync`). DXVK 3.x on MoltenVK has no async.
- **Sikarugir:** the Configure option names come from [Sikarugir-foss-sources](https://github.com/Sikarugir-App/Sikarugir-foss-sources); the install command and the sikarugir.com warning from the [Sikarugir README](https://github.com/Sikarugir-App/Sikarugir).
- **The game:** Zen Edition moved from D3D7 to **D3D9** in update 1.58; patch 1.60 reduced its own black-texture bug.
- **Verified before handing over (Linux + Wine 9.0, not yet a Mac):**
  - the script passes 88 tests under macOS's bash 3.2.57 and awk
  - the probe passes 62/62 on WineD3D and 93/93 with both bundled D9VK builds
  - a full `probe` ran end to end through real Wine

More detail: `README.md` (plan), `RESEARCH.md` (all sources), `TROUBLESHOOTING.md`, `WRAPPER-SETUP.md`, `dlls/README.md`, `probe/README.md`.
