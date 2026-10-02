# Troubleshooting: symptom → cause → how to confirm → fix

Commands are `bash brz-mac.sh <command>`. "Confirm" means the evidence that tells this cause apart from the others.

## Picture problems

| Symptom | Most likely cause | Confirm with | Fix |
|---|---|---|---|
| **Units/buildings black, terrain fine** (Vulkan path) | 16-bit unit textures (A4R4G4B4 / A1R5G5B5 / R5G6B5) don't survive D9VK → MoltenVK in D9VK builds older than the June 2026 fix. The texture fails, nothing gets bound, and the fixed-function stage then reads **(0,0,0,1) = black**. | `probe`: `BLACK` on `tex A4R4G4B4…`/`team colour…` under `wrapper`, `ok` under `d9vk`. `doctor`: syswow64 D9VK without `+16-bit-promotion`. | `profile d9vk` |
| Units black even with `d9vk` | A texture format or blend stage nobody has fixed yet | Triage round `d9vk-diag`, then `analyze` → look for *"reads TEXTURE but no texture is bound"* or *"format this D3D9 layer cannot map (X)"* | Send me the `report`; meanwhile try `dgvoodoo` |
| Units black only with `HardwareTL=1` (or only with `0`) | The two lighting paths differ: the game's own CPU lighting vs fixed-function lighting | Triage rounds `d9vk-on12off` vs `d9vk-htl`; the probe's `light:` rows | Keep the value that renders correctly. `1` is cheaper on the CPU. |
| Black pixels in odd places, shimmering black spots | NaN from float rules in old shaders | `analyze` shows nothing; the problem disappears with `floatEmulation` | `conf dxvk set d3d9.floatEmulation Strict` (already in the template) |
| **Whole screen black**, sound plays | Presentation: exclusive fullscreen, mode switch or Retina scaling | `launch --hud`: if the HUD draws over black, frames are being presented | `ini set Fullscreen 0`; Configure → Retina **off**; set `Width`/`Height` to your scaled display size (e.g. 1440×900); `ini set D3D9On12 0` |
| Whole screen black, no HUD at all | The D3D9 layer never loaded, or crashed at start | `analyze` → *"a DLL failed to load"* / *"aborted"*; `identify` | `profile wrapper` or `profile d9vk`; check `identify` shows **i386** |
| Units **invisible** (not black) | MoltenVK couldn't translate a shader to Metal, so those draws are dropped | `analyze` → *"MoltenVK could not translate a shader"*; probe shows `none` (NOT DRAWN) | `conf dxvk set d3d9.shaderModel 2`; or a different layer |
| Black minimap / wrong cursor texture | A known Zen Edition bug that also happens on Windows (reduced since 1.58/1.60) | Same in `wined3d` = it's the game, not the port | Update the game; restart the match |

## Speed problems

| Symptom | Most likely cause | Confirm with | Fix |
|---|---|---|---|
| Hitch every time **new units/effects appear** | Each new pipeline compiles SPIR-V → Metal on first use | HUD `pipelines` counter jumps at the same moment as the hitch | `dxvk.enableAsync = True` (D9VK; already in the template). The state cache makes the 2nd session smoother. Avoid DXVK 3.x here, since it has no async on MoltenVK. |
| Low FPS **throughout** big battles | CPU-bound: one simulation thread running x86 code under Rosetta 2 | HUD FPS drops but GPU-side frametimes look flat; probe benchmark is high | `HardwareTL=1` (GPU does the lighting); Low Power Mode off; charger in; fps cap 60; fewer AIs |
| Everything slow, even menus | Running on OpenGL (WineD3D) rather than Vulkan | `doctor` / `identify`: `Wine builtin`; no HUD shows with `--hud` | `profile d9vk` |
| **Cutscene** lag | In-engine cutscenes: same cause as battles. Video files: CPU decode/codec path | `doctor` → `videos …` line | In-engine: same fixes as battles. AVI/WMV: Wine DirectShow codecs (see `WRAPPER-SETUP.md`), or skip intros |
| Stutter after an hour of play | Heat throttling or memory pressure (8 GB shared) | Activity Monitor → Memory Pressure yellow/red | Cap 60 fps; close browsers; keep ≥8–10 GB disk free for swap |
| "Lag" only in online games | Network/P2P desync, a known Zen Edition issue on every OS | FPS fine, units rubber-band | Not a port problem |

## Start-up problems

| Symptom | Most likely cause | Confirm with | Fix |
|---|---|---|---|
| Probe/game: `ABORT during CreateDevice`, log says *No adapters found* | DXVK 3.x needs `VK_KHR_load_store_op_none`, which MoltenVK only has from **1.3.0** | `analyze` → *"Vulkan driver lacks 'khrLoadStoreOpNone'"*; `doctor` MoltenVK version | Use `d9vk`; or `BRZ_MVK_DIR=<release's MoltenVK dir>` (experimental) |
| "Could not find supported display mode" | Mode list mismatch | — | `ini set HardwareTL 0` (community fix); choose a listed resolution |
| "Display Initialize" error | — | — | `ini set HardwareTL 1` (community fix) |
| Game doesn't start after a profile change | Wrong-architecture DLL, or a missing dependency | `identify` (must say **i386**); `analyze` | `profile wrapper`, then retry; `restore` |
| Probe: `DIED after: <test>` with *Assertion failed … winevulkan … vkCreateGraphicsPipelines / vkAllocateDescriptorSets* | Wine's Vulkan bridge aborts when the driver (MoltenVK) fails a call. The probe can't catch that from inside. | `analyze` names the failing Vulkan call; it's the last line of `<renderer>.stdout.log` | Use a different renderer for the game. Send me the report: the failing call tells us what MoltenVK lacks. |
| Probe `wined3d-vk`: `0 texture stages`, then everything fails or dies | WineD3D's Vulkan renderer has no fixed-function support in older Wine (seen in Wine 9.0) | `analyze` → *"reports 0 fixed-function texture stages"* | Skip `wined3d-vk` for this game |
| dgVoodoo: `CRASH during CreateDevice` | dgVoodoo's D3D11 path couldn't start (DXMT off, or an incompatible dgVoodoo version) | probe column `dgvoodoo` | Configure → DXMT on; `fetch dgvoodoo 2.79.3` (then 2.54) and probe again |
| Steam keeps updating / won't open | Steam client inside Wine | — | Launch Steam once normally from the wrapper and let it finish updating, then use `launch` |
| `launch` settings don't seem to apply | Steam was already running, so `-applaunch` went to the old Steam (without our env vars) | `launch` warns about this | Quit Steam fully (`kill`), then `launch` |
