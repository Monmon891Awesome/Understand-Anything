# Evidence: why the stack behaves the way it does

These findings come from reading and building the actual code: Sikarugir's d9vk, DXVK, metalsharp DXVK-MacOS, MoltenVK, Wine, and Sikarugir's Configure. They were checked again in October 2026. Re-verify the version-specific ones (releases, commit status) before relying on them months later.

## Which D3D layer can run a 32-bit D3D8/9 game

| Layer | API in → out | Runs 32-bit games | Notes |
|---|---|---|---|
| WineD3D (Wine builtin) | D3D1-11 → OpenGL (or Vulkan) | yes | OpenGL on macOS is a deprecated layer on Metal: correct but slow with many small draw calls (RTS units). Its Vulkan renderer had no fixed-function support in Wine 9.0 ("0 texture stages"). |
| D9VK (Sikarugir) | D3D9 → Vulkan → MoltenVK | yes | DXVK **1.10.3-async** fork, branch `moltenvk-version`, with `[MTLHACK]` commits. **No D3D8.** |
| DXVK ≥ 2.4 forks (metalsharp DXVK-MacOS, DXVK 3.1) | D3D8-11 → Vulkan → MoltenVK | yes (i386 DLLs) | Needs MoltenVK ≥ 1.3.0; no async |
| dgVoodoo2 | Glide, DDraw/D3D1-7, D3D8, D3D9 (partial) → D3D11/12 | yes (`MS/x86`) | Pair it with DXMT (D3D11 → Metal) to avoid Vulkan entirely |
| DXMT | D3D10/11 → Metal | via WoW64 | Only useful behind dgVoodoo2 for D3D9 games |
| D3DMetal / GPTK | D3D11/12 → Metal | **no** (64-bit only) | Never involved for DX8/9 games |

## Facts with sources

1. **16-bit texture fix, unreleased.** [Sikarugir-App/d9vk](https://github.com/Sikarugir-App/d9vk/tree/moltenvk-version), commits `a9e0a68` ("Implement software texture promotion for A4R4G4B4, A1R5G5B5, and R5G6B5 formats") and `f229921` (the readback/demotion path), authored June 2026. The newest [release tag](https://github.com/Sikarugir-App/d9vk/releases) is `v1.10.3-20250511`. With the fix, the DXVK log prints `D3D9: VK_FORMAT_A4R4G4B4_UNORM_PACK16_EXT -> VK_FORMAT_B8G8R8A8_UNORM (Software Promotion)`; `A4R4G4B4` is always promoted, and the other two only when the Vulkan driver lacks them.
2. **Version string is hardcoded.** d9vk's `version.h.in` is `#define DXVK_VERSION "v1.10.3-20230507-async (macOS)"`, so every build reports it. Identify builds by strings in the DLL instead: `Software Prom` = 16-bit fix, `D3D9-DIAG` = diagnostic build, `deAliasedSamplers` = DXVK 3.x fork, `dgVoodoo`, `Wine builtin DLL` / `Wine placeholder DLL`.
3. **Unbound texture = black.** In `src/d3d9/d3d9_fixed_function.cpp`, a stage whose argument is `D3DTA_TEXTURE` with no texture bound uses `constvec4f32(0, 0, 0, 1)`. When colour comes from it, the object is black but correctly lit and shaped. (Alpha becomes 1, opaque, which is harmless.) This turns "texture failed to create" into the classic black-units symptom.
4. **MoltenVK can represent the 16-bit formats** on Apple GPUs ([`MVKPixelFormats.mm`](https://github.com/KhronosGroup/MoltenVK/blob/main/MoltenVK/MoltenVK/GPUObjects/MVKPixelFormats.mm): `A4R4G4B4` → `ABGR4Unorm` swizzled, `R5G6B5` → `B5G6R5Unorm`, `A1R5G5B5` → `BGR5A1Unorm`). The breakage was in D9VK's older format path on Metal in practice. That's why the software promotion fixed it, and why the probe (not theory) decides on a given Mac.
5. **DXVK 3.x needs MoltenVK ≥ 1.3.0.** It requires `VK_KHR_load_store_op_none`. MoltenVK added it in commit `baef12f` (2025-04-25), first released in **v1.3.0 (2025-04-28)** ([`MVKExtensions.def`](https://github.com/KhronosGroup/MoltenVK/blob/main/MoltenVK/MoltenVK/Layers/MVKExtensions.def)). Older drivers produce `Skipping: Device does not support required feature 'khrLoadStoreOpNone'`, then `No adapters found` and an abort.
6. **No async on DXVK 3.x + MoltenVK.** Async pipeline compiling was never part of upstream DXVK. It's a third-party patch that Sikarugir's 1.10.3 fork carries (`dxvk.enableAsync`). Upstream DXVK 2.x+ avoids compile stutter with `VK_EXT_graphics_pipeline_library` instead, which MoltenVK doesn't implement (nor shader objects), and metalsharp's 3.1 fork has no async option. On a Mac it therefore compiles each pipeline on first use.
7. **`Direct3DCreate9On12`.** [DXVK](https://github.com/doitsujin/dxvk/blob/master/src/d3d9/d3d9_main.cpp) logs `9On12 functionality is unimplemented` and creates a normal D3D9 device; [Wine master](https://github.com/wine-mirror/wine/blob/master/dlls/d3d9/d3d9_main.c) also falls back; Wine 9.0 doesn't export the function at all. A game switch that requests it (Battle Realms: `D3D9On12=1`) only adds an unknown on a Mac.
8. **DXVK logs under Wine.** d9vk writes a log *file* only when `DXVK_LOG_PATH` is set. Under Wine it must be a Windows path (`Z:\Users\…`); otherwise the lines go to Wine's stderr. The toolkit's `launch --debug` and `probe` capture both.
9. **Sikarugir.**
   - Configure option names come from [Sikarugir-foss-sources](https://github.com/Sikarugir-App/Sikarugir-foss-sources) (`Configure/…/*.xib`).
   - Retina mode is the Wine registry value `HKCU\Software\Wine\Mac Driver\RetinaMode` (`"Y"`/`"N"`), plus `HKCU\Control Panel\Desktop\LogPixels` (192 on / 96 off), exactly as Configure writes them. It is **wrapper-wide only**: [`macdrv_main.c`](https://github.com/wine-mirror/wine/blob/master/dlls/winemac.drv/macdrv_main.c) reads it with `get_config_key(hkey, NULL, "RetinaMode", …)`, with no app key, unlike most Mac Driver options.
   - The [README](https://github.com/Sikarugir-App/Sikarugir) gives the Homebrew install, lists D9VK as the default D3D9 path for "Apple Silicon & macOS Tahoe", and warns that sikarugir.com is not affiliated.
10. **Wine 9.0's 32-bit `winevulkan` bridge** asserts (`loader_thunks.c`, e.g. `vkAllocateDescriptorSets`, `vkCreateGraphicsPipelines`) when a driver call fails. The probe can't catch that from inside, so the toolkit reports `DIED after: <step>` with the failing call. Seen on Linux + lavapipe under heavy load; watch for it on Macs with old engines.

## Battle Realms: Zen Edition specifics

- **Renderer:** Update 1.58 (Dec 2022) replaced the D3D7 renderer with **D3D9**. Patch 1.60 reduced the game's own "global material bug" (black textures that also appear on Windows). 32-bit exe `Battle_Realms_F.exe`, Steam app `1025600`.
- **`Battle_Realms.ini`:** `[VideoState]` has `Width`, `Height`, `Depth`, `Fullscreen`, `HardwareTL`, `D3D9On12`, `Monitor`, `Adapter`; `[Sound]` has `Enabled`, `NumSFXChannels`, `SoundTimerPeriod`, `SoundTimerResolution`.
- **Community fixes:** `HardwareTL=1` for "Display Initialize" errors; `HardwareTL=0` for "Could not find supported display mode"; virtual desktop or gamescope for black screens on Linux/Proton.

## What was verified before the user's successful run

The toolkit's verification:
- 99 mock-wrapper tests, under Apple's bash 3.2.57 source build + BWK awk, and under GNU bash + mawk.
- An end-to-end `probe` through real Wine 9.0.

The probe's results:
- WineD3D-GL 62/62 (+1 skip)
- bundled D9VK 93/93, diagnostic D9VK 93/93
- metalsharp DXVK 3.1: aborts without `VK_KHR_load_store_op_none`
- dgVoodoo2 2.87.5: crashes in `CreateDevice` on a headless Linux box (inconclusive there)

The bundled DLLs rebuild from source identically except for 6 timestamp/checksum bytes.
