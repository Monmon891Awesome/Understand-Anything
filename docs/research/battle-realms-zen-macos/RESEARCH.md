# Battle Realms: Zen Edition on a base M1 MacBook — renderer research

_Revision 3: added the source-level evidence in §0 (16-bit texture formats, `D3D9On12`, async, MoltenVK version gate), made the bundled D9VK build the first option, and corrected the HardwareTL explanation. Start with `MORNING.md` (steps) or `README.md` (plan)._

_Research notes, October 2026. Target: MacBook (M1, 8-core CPU, 7/8-core GPU, 8 GB unified memory), ~17 GB free disk, Steam version of Battle Realms: Zen Edition (app 1025600), running through Wine (Sikarugir wrapper / Porting Kit)._

---

## 0. Evidence gathered from source code and builds

These findings come from reading and building the actual code: Sikarugir's d9vk, metalsharp's DXVK-MacOS, MoltenVK, Wine, and Sikarugir's Configure. They aren't based on forum reports.

1. **`Battle_Realms.ini` has a `D3D9On12` switch** in `[VideoState]`, next to `Width`, `Height`, `Depth`, `Fullscreen`, `HardwareTL`, `Monitor` and `Adapter`. With `1`, the game calls `Direct3DCreate9On12`. On a Mac nothing implements D3D9-on-12:
   - DXVK/D9VK logs *"9On12 functionality is unimplemented"* and creates a normal D3D9 device.
   - Wine master falls back the same way.
   - **Wine 9.0 doesn't export the function at all** (seen in the probe).

   `D3D9On12=0` removes the variable.
2. **Sikarugir's D9VK = DXVK 1.10.3 "async" + `[MTLHACK]` commits** (branch `moltenvk-version`). Its `version.h.in` hardcodes `v1.10.3-20230507-async (macOS)`, so every build reports the same version. `brz-mac.sh identify` checks code traits instead.
3. **16-bit textures.** Commits `a9e0a68` and `f229921` (pengwing, June 2026) add *software promotion* for `A4R4G4B4`, `A1R5G5B5` and `R5G6B5`: those textures are converted to `B8G8R8A8` in software, and `A4R4G4B4` is always converted. These are exactly the formats an early-2000s RTS uses for unit sprites/skins and team-colour masks. **The newest d9vk release tag (`v1.10.3-20250511`) predates them.**
4. **Why a failed texture is *black*, not missing:** in `d3d9_fixed_function.cpp`, a fixed-function stage that reads `D3DTA_TEXTURE` with no texture bound gets the constant `(0, 0, 0, 1)`. A unit whose texture couldn't be created is therefore drawn with correct geometry and lighting, in black. That matches the symptom.
5. **MoltenVK** (main) maps `A4R4G4B4`→`ABGR4Unorm` (swizzled), `R5G6B5`→`B5G6R5Unorm` and `A1R5G5B5`→`BGR5A1Unorm` on Apple GPUs, so current MoltenVK *can* represent these. The d9vk fix still exists because the older DXVK code path broke on Metal in practice. The probe settles it on your Mac.
6. **DXVK 3.x (metalsharp) requires `VK_KHR_load_store_op_none`.** MoltenVK added it in commit `baef12f`, first released in **v1.3.0 (2025-04-28)**. With an older MoltenVK, DXVK 3.x finds "No adapters" and aborts. I reproduced that exact abort here, with a driver lacking the extension.
7. **Async:** d9vk understands `dxvk.enableAsync`, which compiles new pipelines in the background. DXVK 3.x on MoltenVK has neither async nor graphics-pipeline-library, so first-time effects stutter more there.
8. **Sikarugir Configure** (from its FOSS source) has toggles for *DXMT*, *D3DMetal*, *DXVK* (D3D10/11), *MoltenVK - (CodeWeavers version)*, *MoltenVK FastMath*, *msync/esync*, *Performance HUD*, *Limit to 1 CPU core*, and a log option. It has **no D9VK toggle**: per the README, D9VK is the default D3D9 path on "Apple Silicon & macOS Tahoe". Retina mode is stored as the Wine registry value `Mac Driver\RetinaMode`, so the script can set it per game.
9. **Safety:** Sikarugir's README warns that **sikarugir.com is not theirs** and to scan for malware if you came from it. Install only from the Homebrew tap or GitHub.
10. **dgVoodoo2 2.87.5** crashed with an integer divide-by-zero inside its own `CreateDevice`, both over Wine's D3D11 and over DXVK's D3D11, on a headless Linux test box. That's inconclusive for the Mac, where it runs over DXMT. The probe will show `CRASH during CreateDevice` if it does the same there.

## 1. What we already know from testing

| Path tried | Result |
|---|---|
| WineD3D → OpenGL (the Wine default) | Runs and looks right, but lags in cutscenes and in big battles |
| D3DMetal / "DX3D" options | No improvement (D3DMetal handles 64-bit D3D11/12 only, so it never touches this game) |
| DXVK / D9VK → MoltenVK (Vulkan) | **Lag gone**, but either a fully black screen or black-shaded units and buildings |
| Steam overlay off + quiet/silent Steam launch | Saves some CPU, but doesn't fix the rendering |

The key result is that **Vulkan fixes the lag**, so the slowdown is in the graphics path, not the M1's speed. WineD3D turns every D3D call into OpenGL. On Apple Silicon, OpenGL is itself an old, slow layer built on Metal, and a game that sends many small draw calls (one per unit, shadows, team colours) chokes on it. The problem left to solve is the **black output from the Vulkan path**.

## 2. What the game actually renders with

- Update **1.58 (Dec 2022)** removed the old **Direct3D 7** renderer and replaced it with **Direct3D 9**. That fixed many glitches on Windows (minimap, shadows, artifacts). [gamingph][gamersglobal]
- The game is a **32-bit** executable. On an M1 it runs as x86-32 code through Wine's WoW64 layer and Rosetta 2.
- Zen Edition has a long-known "global material bug": units drawn with **black textures**, ground textures swapping, and wrong UI or cursor textures. Patch **1.60** made black or missing unit textures less likely, but even on Windows it was never fully fixed. [Steam guide][Steam texture thread]
- On Linux with Proton, the known black-screen fixes are: Wine virtual desktop, gamescope, `Fullscreen=1` in the game's `.ini`, and `HardwareTL=1` for "Display Initialize" errors. [Proton #3364][Steam Proton thread]

**This means:** the renderers that matter are **D3D9 translators that run in 32-bit code**. That rules out **D3DMetal** (64-bit D3D11/12 only) and **upstream DXMT on its own** (D3D10/11). That's why the "DX3D" options did nothing.

## 3. Why Vulkan gives a black screen or black units

There are two separate problems:

1. **Fully black screen.** This is a presentation/swapchain problem, not a shading one. Usually the cause is exclusive fullscreen, or a display-mode change the game asks for that MoltenVK/macOS refuses (Retina scaling makes it worse). The Proton reports show the same thing on Linux, fixed with a virtual desktop or gamescope.
2. **Black units and buildings while the terrain looks fine.** This is a texture/shading problem in **DXVK's D3D9 → Vulkan → MoltenVK** chain. Likely causes, most likely first:
   - **16-bit unit textures that fail in older D9VK builds (§0.3–0.4).** The texture isn't created, nothing gets bound, and the fixed-function stage reads black. Fixed upstream in June 2026 but not released yet; the bundled `dlls/d9vk-f229921` build contains the fix.
   - **Texture sampler aliasing.** DXVK's D3D9 code binds textures in a way Metal can't express, so samplers come back empty and the model renders black. The maintained macOS fork of DXVK adds a `d3d9.deAliasedSamplers` setting for exactly this on MoltenVK. [metalsharp/DXVK-MacOS]
   - **Lighting path.** `HardwareTL` most likely switches between the game lighting vertices itself on the CPU (`0`) and asking D3D's fixed-function lighting to do it on the GPU (`1`). The two paths use different D3D features, so one can render black while the other doesn't. (Upstream DXVK has had "black textures (incorrect lighting)" regressions.) [dxvk #3258] `1` also takes work off the CPU in big battles.
   - **Missing texture swizzles in MoltenVK (less likely).** Apple Silicon GPUs support texture swizzle natively and MoltenVK normally uses it. Forcing `MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE=1` is a cheap way to rule this out for old D3D9 formats (L8, A8L8).
   - **Older D3D9 code.** Sikarugir's "D9VK" toggle is its own MoltenVK branch of DXVK. The metalsharp fork rebases onto DXVK 3.1 and adds MoltenVK sampler work, so comparing the two isolates a D3D9-implementation bug.
   - **The game's own material bug** (section 2). Make sure the game is on the latest patch, so we don't chase a bug that also happens on Windows.

## 4. Options ranked for this machine

### Option A: Recommended first. The bundled D9VK with the 16-bit fix (`profile d9vk`), then metalsharp DXVK-MacOS, inside Sikarugir

> **Update (revision 3):** the first choice is now the bundled `dlls/d9vk-f229921/d3d9.dll`. It's the same D9VK Sikarugir ships, plus the unreleased June 2026 16-bit texture fix, and it keeps async compilation. metalsharp's DXVK 3.x is the second choice: it needs MoltenVK ≥ 1.3.0 and has no async. `bash brz-mac.sh probe` compares both on your Mac before you touch the game.

This keeps the Vulkan speed, which already solved the lag, and goes after the black shading directly. `brz-mac.sh` automates steps 2–5 (see `README.md`).

> **Correction to the first version of this note:** Gcenx's DXVK-macOS (last release 1.10.3, 2023) does **not** provide D3D9. Its final repack deliberately removed `d3d9.dll` and `dxgi.dll` as "shouldn't be used on macOS", so it can't be a fallback here. The only D3D9-on-Vulkan builds for macOS are Sikarugir's own **D9VK** (`Sikarugir-App/d9vk`, the `moltenvk-version` branch) and **metalsharp/DXVK-MacOS** (DXVK 3.1 base, i386 + x86_64 D3D8/9/10/11 DLLs, `d3d9.deAliasedSamplers`). metalsharp is very new: one release (Sept 2026) and one maintainer. Treat it as promising but unproven, and keep the D9VK toggle as the comparison.

1. In a **new** Sikarugir wrapper (don't reuse the broken one), use a recent WoW64-capable engine (see `WRAPPER-SETUP.md`). There is no D9VK toggle: the per-game DLL override from `brz-mac.sh profile …` decides which D3D9 runs. Keep *D3DMetal* off. Install Steam and the game, and launch once so `Battle_Realms.ini` exists.
2. **Baseline with the wrapper's own D9VK** (`./brz-mac.sh profile wrapper`). Record whether units are black. This tells us whether the newer DXVK is needed at all.
3. **Swap in metalsharp's i386 `d3d9.dll` for this game only:** `./brz-mac.sh profile dxvk ~/Downloads/DXVK-MacOS-v3.1`. The script copies the 32-bit `d3d9.dll` into the game folder and sets a **per-game** override (`HKCU\Software\Wine\AppDefaults\Battle_Realms_F.exe\DllOverrides`, `d3d9=native`). Steam and the rest of the wrapper aren't affected, and a Configure change can't overwrite it. Keep the wrapper's own MoltenVK at first. Only if that fails, try the MoltenVK dylib bundled in the release (back up `Contents/SharedSupport/wine/lib/libMoltenVK.dylib` first).
4. `dxvk.conf` next to `Battle_Realms_F.exe` (installed by the script from `templates/dxvk.conf`). DXVK reads it from the game's working directory, so it works whether you launch from Finder or the script:

   ```ini
   d3d9.deAliasedSamplers = True     # MoltenVK-safe sampler path (fork-only key, ignored elsewhere)
   d3d9.floatEmulation    = Strict   # 0*inf must be 0, not NaN -> black pixels
   # d3d9.forceSamplerTypeSpecConstants = True   # step 2 if still black
   # d3d9.shaderModel = 2                         # step 3 if still black
   d3d9.maxFrameRate      = 60       # stops the M1 from running hot and throttling
   d3d9.maxFrameLatency   = 1
   d3d9.presentInterval   = 1
   d3d9.deferSurfaceCreation = True
   ```

   On top of that, `brz-mac.sh launch` sets **`MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE=1`**. Apple Silicon normally swizzles natively, so this mainly rules out the case where it doesn't for old D3D9 formats (L8, A8L8). It also sets `MVK_CONFIG_FAST_MATH_ENABLED=0` while we look for black-pixel NaNs.
5. `Battle_Realms.ini` in the game folder: set **`D3D9On12=0`** and test **`HardwareTL=1`** first (`bash brz-mac.sh ini set HardwareTL 1`). That makes the GPU do the lighting through D3D's fixed function instead of the game doing it on the CPU. If one setting renders black and the other doesn't, we've isolated the lighting path. Note the trade-off: the Steam community advises `HardwareTL=0` for "Could not initialize display mode", so if `1` won't start, that tells us something too. Keep `Fullscreen=1`, as in the Proton fixes.
6. **Black-screen fix:** `bash brz-mac.sh retina off` (per game) and `ini set Fullscreen 0`. If the window is still black, set `Width`/`Height` to the display's scaled size (1440×900 on a 13-inch M1).
7. Diagnose with `./brz-mac.sh launch --hud`. A black screen with the HUD's FPS climbing means a presentation problem (step 6). No HUD at all means DXVK didn't load (check the override with `./brz-mac.sh doctor`). Black units with the HUD showing mean a shader/sampler problem (steps 4–5).

### Option B — dgVoodoo2 (D3D9 → D3D11) + DXMT (D3D11 → Metal)

This skips Vulkan and MoltenVK completely. DXMT is a Metal-native D3D10/11 layer and is now in Sikarugir and CrossOver. dgVoodoo2 turns the game's D3D9 calls into D3D11, and DXMT draws that through Metal.

- `./brz-mac.sh profile dgvoodoo ~/Downloads/dgVoodoo2_79_3`: copies dgVoodoo2's `MS/x86/D3D9.dll` and `templates/dgVoodoo.conf` (output API **D3D11 FL 11_0**, watermark off) next to the game exe, and sets a per-game `d3d9=native` override. The game only uses D3D9, so the DDraw/D3DImm DLLs aren't needed. Then in Configure: **DXMT on, DXVK/D9VK off**.
- dgVoodoo2's D3D9 support is **partial**, so test it. The Battle Realms community has recommended **dgVoodoo2 v2.54** in particular (newer versions caused problems on Windows). Users on macOS have reported dgVoodoo **2.79.3 + DXMT** working for other D3D9 games. Try 2.79.x first, then 2.54.
- Needs a wrapper engine whose DXMT build supports **32-bit (WoW64)**. Recent DXMT builds do, but check that yours does.
- Upside: no MoltenVK, so the MoltenVK sampler bug can't happen, and Metal shaders run natively. Downside: it's two translation steps, and dgVoodoo's D3D9 support isn't complete.

### Option C — Experimental: native D3D9 → Metal (d9mt, DXMT D3D9 frontend)

- **d9mt** uses DXVK's D3D9 front-end with a Metal back-end, supports 32-bit, and needs CrossOver 26+ or Wine with DXMT. It's only been tested on GTA IV ("expect unimplemented paths"). [d9mt]
- People are also adding a **D3D9 frontend + i386 build of DXMT** in DXMT forks. [willfaust/dxmt]
- In the long run this is the best fit for Battle Realms (D3D9 straight to Metal), but it's research-grade software right now. Try it only after A and B.

### Option D — Wait for or try KosmicKrisp (Mesa Vulkan-on-Metal)

LunarG's **KosmicKrisp** is a Vulkan 1.3-conformant driver that runs on Metal 4. It reached feature parity with MoltenVK in 2026, and upstream DXVK already carries compatibility tweaks for it. [LunarG Jan 2026][Phoronix] If a Sikarugir or CrossOver build lets you choose KosmicKrisp instead of MoltenVK, it's the cleanest fix for DXVK's black-sampler issues. Note that it needs **macOS with Metal 4 (macOS 26)**.

### Not recommended for this game

- **D3DMetal / GPTK**: 64-bit D3D11/12 only, so it won't affect a 32-bit D3D9 game.
- **WineD3D + Vulkan backend (`renderer=vulkan`)**: in theory it avoids OpenGL, but on macOS it still goes through MoltenVK and is usually slower than DXVK.
- **Staying on OpenGL** and only tweaking settings: you already found the ceiling.

## 5. CPU / GPU / memory notes for a base M1

- **The CPU is the real limit in big fights.** Battle Realms runs most of its simulation on one thread, and here that x86-32 code runs under Rosetta 2. 4v4 fights or large waves will dip on any renderer. Help it by:
  - plugging in the charger and turning **Low Power Mode off**,
  - capping at **60 FPS** (`d3d9.maxFrameRate`) so the GPU isn't fighting the CPU for power and heat,
  - closing browsers and Electron apps. 8 GB of unified memory is shared with the GPU, and swapping causes stutter.
- **GPU:** the 7/8-core M1 GPU is far more than this game needs once it's on DXVK or Metal. Run at the panel's scaled resolution with Retina mode off. Lower **shadows** and **anti-aliasing** in game first, since those are the biggest per-unit costs.
- **Cutscenes:** they're video files decoded on the CPU. If they still stutter after switching renderers, add `winetricks quartz lavfilters` (or `devenum quartz`) to the wrapper, or skip intros. Stutter that only happens in cutscenes is a codec problem, not a renderer one.
- **Steam:** keep what you already do: overlay off, start with `-silent` / `-no-browser` / `-noverify` (and `-cef-disable-gpu` if Steam's own window flickers). Steam still has to be running for the DRM check, but this keeps its CEF browser processes from using CPU. Another option is to let Steam start the game, then quit only the Steam UI windows.

## 6. Disk plan (17 GB free)

| Item | Approx. size |
|---|---|
| Sikarugir wrapper (engine + prefix) | 1.0–1.5 GB |
| Steam client inside the wrapper (after update) | 1–1.5 GB |
| Battle Realms: Zen Edition install | ~4 GB (Steam lists 4 GB) |
| DXVK / dgVoodoo / DXMT DLLs, shader cache | < 200 MB |
| **Total per wrapper** | **≈ 6.5–7.5 GB** |

- **One wrapper at a time.** Two full wrappers (Option A and Option B) would use ~14 GB and leave macOS without room to swap with 8 GB RAM. Instead, use **one** wrapper and switch renderers per game with `bash brz-mac.sh profile …`. It drops the DLL next to the game exe and sets a per-game override, never touching `syswow64`.
- Keep **at least 8–10 GB free** while playing. macOS swap and the Rosetta AOT cache both need space, and a full disk causes stutter that looks like lag.
- Remove old Porting Kit/Sikarugir wrappers and their `~/Library/Caches` entries before you start. Steam's `steamapps/downloading` and `shadercache` inside the wrapper can also be cleared.

## 7. Suggested test order (shortest path)

> Superseded by the automated `probe` + `triage` flow in `MORNING.md`. Kept for reference.

1. Fresh Sikarugir wrapper, Steam installed, game updated to the latest patch (1.60+).
2. **Option A** with metalsharp DXVK-macOS i386 DLLs, plus `dxvk.conf` with `deAliasedSamplers=True` and `floatEmulation=Strict`, plus `HardwareTL=1`, plus a virtual desktop.
3. Units still black → `forceSamplerTypeSpecConstants=True`, then `shaderModel=2`, then `HardwareTL=0`, then the release's bundled MoltenVK. (Full decision tree in `README.md`.)
4. Still black → **Option B** (dgVoodoo2 2.79.x → 2.54, output D3D11, DXMT on, DXVK off).
5. Still unsolved → Option C/D, or report it upstream with a `DXVK_LOG_LEVEL=debug` log and screenshots (DXVK-MacOS issues, Sikarugir issues).

For each test, write down: avg FPS in a fixed skirmish (same map, 4 AIs, 10 minutes), whether units render correctly, and whether cutscenes are smooth.

## Sources

- [Battle Realms now supports 4K and improved graphics via Direct3D 9 (gamingph)](https://gamingph.com/2022/12/battle-realms-now-supports-4k-resolution-and-improved-graphics-via-direct3d-9/)
- [Battle Realms Zen Edition: Umfangreiches Update (GamersGlobal)](https://www.gamersglobal.de/news/241216/battle-realms-zen-edition-umfangreiches-update-erschienen)
- [Steam guide: Battle Realms – Fixing Your Issues](https://steamcommunity.com/sharedfiles/filedetails/?id=2036927063)
- [Steam: Problem with texture](https://steamcommunity.com/app/1025600/discussions/0/3282569322818294673/)
- [Steam: How to run this game on Linux using Proton](https://steamcommunity.com/app/1025600/discussions/1/2576571891741571905/)
- [ValveSoftware/Proton #3364 – Battle Realms](https://github.com/ValveSoftware/Proton/issues/3364)
- [ProtonDB – Battle Realms: Zen Edition](https://www.protondb.com/app/1025600)
- [metalsharp/DXVK-MacOS](https://github.com/metalsharp/DXVK-MacOS) · [releases](https://github.com/metalsharp/DXVK-MacOS/releases)
- [Sikarugir-App/d9vk, branch moltenvk-version](https://github.com/Sikarugir-App/d9vk/tree/moltenvk-version): commits a9e0a68 + f229921 (16-bit software promotion) · [releases](https://github.com/Sikarugir-App/d9vk/releases)
- [Sikarugir README](https://github.com/Sikarugir-App/Sikarugir) (official install; sikarugir.com warning) · [Sikarugir-foss-sources (Configure)](https://github.com/Sikarugir-App/Sikarugir-foss-sources)
- [MoltenVK MVKPixelFormats.mm](https://github.com/KhronosGroup/MoltenVK/blob/main/MoltenVK/MoltenVK/GPUObjects/MVKPixelFormats.mm) · [MVKExtensions.def](https://github.com/KhronosGroup/MoltenVK/blob/main/MoltenVK/MoltenVK/Layers/MVKExtensions.def) (VK_KHR_load_store_op_none since v1.3.0)
- [DXVK d3d9_main.cpp](https://github.com/doitsujin/dxvk/blob/master/src/d3d9/d3d9_main.cpp) and [Wine d3d9_main.c](https://github.com/wine-mirror/wine/blob/master/dlls/d3d9/d3d9_main.c) (Direct3DCreate9On12 fallbacks)
- [dgVoodoo2 releases](https://github.com/dege-diosg/dgVoodoo2/releases)
- [Gcenx/DXVK-macOS releases (d3d9.dll removed in last repack)](https://github.com/Gcenx/DXVK-macOS/releases)
- [doitsujin/dxvk #3258 – Black textures (incorrect lighting)](https://github.com/doitsujin/dxvk/issues/3258)
- [DXVK 2.4 merges D8VK (GamingOnLinux)](https://www.gamingonlinux.com/2024/07/dxvk-24-brings-d8vk-for-direct3d-8-support-frame-rate-limiter-adjustments-lots-of-game-fixes/)
- [Sikarugir](https://github.com/Sikarugir-App/Sikarugir) · [Sikarugir d9vk](https://github.com/The-Wineskin-Project/d9vk)
- [3Shain/dxmt – 32-bit DX9 discussion](https://github.com/3Shain/dxmt/discussions/4) · [willfaust/dxmt D3D9 frontend PR](https://github.com/willfaust/dxmt/pull/2)
- [neo773/d9mt](https://github.com/neo773/d9mt)
- [dgVoodoo2 readme](https://www.dege.fw.hu/dgVoodoo2/ReadmeGeneral/)
- [LunarG – State of Vulkan on Apple, Jan 2026](https://www.lunarg.com/the-state-of-vulkan-on-apple-jan-2026/) · [Phoronix – KosmicKrisp 2026](https://www.phoronix.com/news/KosmicKrisp-2026)
