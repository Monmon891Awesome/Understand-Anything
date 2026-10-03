# Morning runbook: debug the black units in ~45 minutes

> **Everything in one file (good for feeding to an AI assistant in your Mac terminal): [`PLAYBOOK.md`](PLAYBOOK.md).**

Do these four steps in order. Each step writes its results to `~/.brz-mac/`, and the last step bundles everything into one file for me. You don't need to interpret anything yourself, but the meanings are listed so you can.

> Everything here changes **only this game's** settings inside the wrapper, and backs up first.
> `bash brz-mac.sh restore` puts everything back as it was.

---

## 0. Get the toolkit onto the Mac (2 min)

```bash
git clone -b research/battle-realms-zen-macos https://github.com/monmon891awesome/understand-anything.git ~/brz
cd ~/brz/docs/research/battle-realms-zen-macos
```

(No git? On GitHub, switch to the branch `research/battle-realms-zen-macos`, then use **Code → Download ZIP**, unzip it, and `cd` into `docs/research/battle-realms-zen-macos`.)

Always run the tool as `bash brz-mac.sh …` so execute permissions don't matter. If you have more than one wrapper, tell it which one:

```bash
export BRZ_WRAPPER="$HOME/Applications/Sikarugir/Battle Realms.app"   # your wrapper's path
```

## 1. Check the setup (1 min)

Quit the game **and Steam** first, then:

```bash
bash brz-mac.sh doctor
```

Fix anything marked `!`: Rosetta missing, Low Power Mode on, less than 8 GB free, on battery. Also note these lines:

| Line | What it tells us |
|---|---|
| `syswow64/d3d9 … DXVK/D9VK` with **no** `+16-bit-promotion` | Your wrapper's D9VK predates the June 2026 fix for 16-bit textures. This is the prime suspect for black units. |
| `ini D3D9On12 1` | The game asks for Direct3D 9-on-12, which no Mac layer supports (they quietly ignore it). We'll test `0`. |
| `ini HardwareTL 0/1` | Whether the game lights units itself on the CPU (`0`) or asks DirectX to do it on the GPU (`1`). |
| `videos …` | Whether cutscenes are video files or rendered in-engine. This decides how we fix cutscene lag. |
| `MoltenVK 1.x.y` | Below 1.3.0, the newer DXVK 3.x build can't start at all. |

## 2. Run the probe (5–10 min, unattended)

Optional, but it gives a fuller comparison: download the two alternative renderers first, so the probe includes them.

```bash
bash brz-mac.sh fetch dxvk        # metalsharp DXVK-MacOS (DXVK 3.1 for macOS)
bash brz-mac.sh fetch dgvoodoo    # dgVoodoo2 2.87.5 (D3D9 -> D3D11 -> DXMT/Metal)
```

Then:

```bash
bash brz-mac.sh probe
```

A small window will flash several times. Each time, it renders 31 test patterns with a different graphics layer and reads the pixels back:
- the 16-bit and compressed textures early-2000s games use
- the team-colour blend
- fixed-function lighting
- alpha test and alpha blend
- render-to-texture

It also runs a "many small units" benchmark. It does **not** touch the game. You get a table like this:

```
test                                     wrapper     wined3d     d9vk        dxvk        dgvoodoo
HW: tex A4R4G4B4 managed                 BLACK       ok          ok          ok          ok
HW: team colour A4R4G4B4 alpha=0         BLACK       ok          ok          ok          ok
FAILED (black/none/wrong/err)            6           0           0           0           0
benchmark (higher is better)             310 fps     45 fps      305 fps     280 fps     150 fps
```

How to read it:
- **`BLACK` under `wrapper` but `ok` under `d9vk`:** the 16-bit texture bug is confirmed. The fix is `bash brz-mac.sh profile d9vk`.
- **`BLACK` in every Vulkan column (wrapper, d9vk, dxvk, wined3d-vk), `ok` under `wined3d`:** it's a MoltenVK problem. `dgvoodoo` (Metal, no Vulkan) is the way around it.
- **Everything `ok` everywhere:** the black units come from something the probe doesn't use. The diagnostic round in step 3 will catch it.
- **`CRASH`/`ABORT`/`TIMEOUT` for a column:** that layer can't run in this wrapper. The line under the table says why.
- **The `benchmark` row** compares raw draw-call speed between layers on *your* Mac. The best candidate has 0 failures and the highest number.
- **`+died` in the FAILED row / `DIED after: …`:** the layer crashed under the probe. The line under the table and `bash brz-mac.sh analyze` name the failing call.

Optional A/B test (5 min): in the wrapper's Configure, flip **MoltenVK - (CodeWeavers version)**, then run `bash brz-mac.sh probe wrapper d9vk` again. If the black rows disappear, CrossOver's MoltenVK fork alone fixes it.

## 3. Triage in the game (20–30 min)

```bash
bash brz-mac.sh triage
```

Each round sets up one configuration and launches Steam → Battle Realms with an FPS overlay and full logging. Play a skirmish for about 3 minutes, enough for a big fight and, if you can, one cutscene. Then **quit the game and Steam** and answer 5 questions:
1. Did you reach the menu?
2. Was the whole screen black?
3. Were units black?
4. What was the FPS during the big fight? Read it from the overlay's top-left corner.
5. Were the cutscenes smooth?

The rounds, in order:
1. `baseline`: your current setup (reproduces the problem with logs on)
2. `d9vk`: D9VK with the 16-bit texture fix
3. `d9vk-on12off`: … plus `D3D9On12=0`
4. `d9vk-htl`: … plus `HardwareTL` flipped
5. `d9vk-diag`: diagnostic build. It only runs if units are still black, and it logs every texture format and blend stage the game uses.
6. `dxvk`: metalsharp DXVK 3.x
7. `dgvoodoo`: dgVoodoo2 → DXMT. It will ask you to switch DXMT on in the wrapper's Configure.
8. `wined3d-vk`: Wine's own D3D9 on Vulkan
9. `wined3d`: Wine on OpenGL, the slow but correct reference

The triage stops as soon as a round gives a correct picture at 45 FPS or more. A whole-screen-black answer automatically repeats that round in windowed mode (`Fullscreen=0`) with Retina off for the game. Ctrl-C is safe at any time, and `bash brz-mac.sh triage` resumes where you stopped.

## 4. Send me the report (1 min)

```bash
bash brz-mac.sh report
```

It prints the path of a single `report-*.md` file. Paste it here, together with **one screenshot of the black units** (⌘⇧4) if they were still black anywhere. If I need raw logs, `bash brz-mac.sh logs` makes a zip.

---

## If you only have 10 minutes

```bash
bash brz-mac.sh doctor
bash brz-mac.sh profile d9vk
bash brz-mac.sh ini set D3D9On12 0
bash brz-mac.sh launch --hud --debug      # play a skirmish, quit
bash brz-mac.sh analyze
```

## Undo everything

```bash
bash brz-mac.sh restore
```
