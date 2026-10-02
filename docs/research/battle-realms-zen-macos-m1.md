# Battle Realms: Zen Edition on a base M1 MacBook — renderer research

_Research notes, October 2026. Target: MacBook (M1, 8-core CPU, 7/8-core GPU, 8 GB unified memory), ~17 GB free disk, Steam version of Battle Realms: Zen Edition (app 1025600), running through Wine (Sikarugir wrapper / Porting Kit)._

---

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
2. **Black units and buildings while the terrain looks fine.** This is a shading/sampling problem in **DXVK's D3D9 → Vulkan → MoltenVK** chain. Likely causes, most likely first:
   - **Texture sampler aliasing.** DXVK's D3D9 code binds textures in a way Metal can't express, so samplers come back empty and the model renders black. The maintained macOS fork of DXVK adds a `d3d9.deAliasedSamplers` setting for exactly this on MoltenVK. [metalsharp/DXVK-MacOS]
   - **Fixed-function lighting / vertex processing.** Battle Realms has a `HardwareTL` switch. With software T&L, DXVK has to emulate the vertex pipeline, and if lighting goes wrong you get lit-black models. (Upstream DXVK has had "black textures (incorrect lighting)" regressions of this kind.) [dxvk #3258]
   - **An old D9VK build.** Sikarugir's "D9VK" toggle is an old fork (Gcenx/Wineskin d9vk). Newer DXVK-macOS builds include years of D3D9 fixes it doesn't have.
   - **The game's own material bug** (section 2). Make sure the game is on the latest patch, so we don't chase a bug that also happens on Windows.

## 4. Options ranked for this machine

### Option A — Recommended first: DXVK-macOS (current fork) + `dxvk.conf` fixes, inside Sikarugir

This keeps the Vulkan speed, which already solved the lag, and goes after the black shading directly.

1. In a **new** Sikarugir wrapper (don't reuse the broken one), use a recent WoW64-capable engine. In *Configure → Tools/Options*, turn **D9VK/DXVK on** and **DXMT and D3DMetal off**.
2. Replace the wrapper's `d3d9.dll` (and `d3d8.dll`, `dxgi.dll`) in `drive_c/windows/syswow64/` with the **i386** DLLs from **metalsharp/DXVK-MacOS** releases (based on DXVK 3.1, has x86_64 + i386 D3D8/9/10/11/DXGI DLLs; needs macOS 15+). On macOS 14, use the Gcenx DXVK-macOS 1.10.x i386 DLLs instead.
3. Set the DLL override `d3d9=n,b` (Configure → Advanced → Winetricks/Custom EXE flags, or `WINEDLLOVERRIDES="d3d9=n,b"`).
4. Put a `dxvk.conf` next to `Battle_Realms_F.exe` (or point `DXVK_CONFIG_FILE` at it):

   ```ini
   # --- black-unit fixes, try in this order ---
   d3d9.deAliasedSamplers = True     # MoltenVK-safe sampler path (fork option)
   d3d9.floatEmulation    = Strict   # stops 0*inf = NaN -> black pixels in old shaders
   # d3d9.forceSamplerTypeSpecConstants = True   # try if units are still black

   # --- performance / stability ---
   dxgi.maxFrameLatency    = 1
   d3d9.maxFrameRate       = 60      # stops the M1 from running hot and throttling
   d3d9.presentInterval    = 1
   d3d9.deferSurfaceCreation = True
   ```

   (If you're on the older 1.10.x fork, also set `dxvk.enableAsync = True` to avoid shader-compile stutter in the first big battle. Newer builds use graphics-pipeline-library or the shader cache instead.)
5. In the game's `.ini` (in the install folder / `%APPDATA%` copy), test **`HardwareTL=1`** first. That keeps vertex processing on the GPU and avoids DXVK's SWVP emulation, which is the likely cause of black lighting. Also set `Fullscreen=1`, as the Proton fixes do.
6. **Black-screen fix:** in Sikarugir Configure → enable **"Windows virtual desktop"** at the native game resolution (e.g. 1440×900 or 1280×800), and turn **off** "Retina mode". Run the game at that same resolution. Plain fullscreen through MoltenVK is the usual cause of an all-black window.
7. Optional check: add `DXVK_HUD=fps,drawcalls` (and `MVK_CONFIG_LOG_LEVEL=2`) to see whether frames are actually being drawn. A black screen with FPS climbing is a presentation problem (fix step 6). Black units are a shader/sampler problem (fix step 4).

### Option B — dgVoodoo2 (D3D9 → D3D11) + DXMT (D3D11 → Metal)

This skips Vulkan and MoltenVK completely. DXMT is a Metal-native D3D10/11 layer and is now in Sikarugir and CrossOver. dgVoodoo2 turns the game's D3D9 calls into D3D11, and DXMT draws that through Metal.

- Copy dgVoodoo2's `MS/x86/D3D9.dll` + `D3DImm.dll` + `DDraw.dll` and `dgVoodoo.conf` next to the game exe. Override `d3d9=n,b`. Set the output API to **Direct3D 11 (feature level 10.1/11)**. Untick "dgVoodoo watermark".
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

- **One wrapper at a time.** Two full wrappers (Option A and Option B) would use ~14 GB and leave macOS without room to swap with 8 GB RAM. Instead, use **one** wrapper and switch DLLs. Keep `syswow64/d3d9.dll` backups named `d3d9.dll.dxvk`, `d3d9.dll.dgv`, etc., and swap them by hand.
- Keep **at least 8–10 GB free** while playing. macOS swap and the Rosetta AOT cache both need space, and a full disk causes stutter that looks like lag.
- Remove old Porting Kit/Sikarugir wrappers and their `~/Library/Caches` entries before you start. Steam's `steamapps/downloading` and `shadercache` inside the wrapper can also be cleared.

## 7. Suggested test order (shortest path)

1. Fresh Sikarugir wrapper, Steam installed, game updated to the latest patch (1.60+).
2. **Option A** with metalsharp DXVK-macOS i386 DLLs, plus `dxvk.conf` with `deAliasedSamplers=True` and `floatEmulation=Strict`, plus `HardwareTL=1`, plus a virtual desktop.
3. Units still black → add `forceSamplerTypeSpecConstants=True`, then try `HardwareTL=0`, then the Gcenx 1.10.3 DLLs.
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
- [metalsharp/DXVK-MacOS](https://github.com/metalsharp/DXVK-MacOS)
- [doitsujin/dxvk #3258 – Black textures (incorrect lighting)](https://github.com/doitsujin/dxvk/issues/3258)
- [DXVK 2.4 merges D8VK (GamingOnLinux)](https://www.gamingonlinux.com/2024/07/dxvk-24-brings-d8vk-for-direct3d-8-support-frame-rate-limiter-adjustments-lots-of-game-fixes/)
- [Sikarugir](https://github.com/Sikarugir-App/Sikarugir) · [Sikarugir d9vk](https://github.com/The-Wineskin-Project/d9vk)
- [3Shain/dxmt – 32-bit DX9 discussion](https://github.com/3Shain/dxmt/discussions/4) · [willfaust/dxmt D3D9 frontend PR](https://github.com/willfaust/dxmt/pull/2)
- [neo773/d9mt](https://github.com/neo773/d9mt)
- [dgVoodoo2 readme](https://www.dege.fw.hu/dgVoodoo2/ReadmeGeneral/)
- [LunarG – State of Vulkan on Apple, Jan 2026](https://www.lunarg.com/the-state-of-vulkan-on-apple-jan-2026/) · [Phoronix – KosmicKrisp 2026](https://www.phoronix.com/news/KosmicKrisp-2026)
