# Bundled D9VK builds (32-bit `d3d9.dll`)

| Folder | What it is | Reports itself as |
|---|---|---|
| `d9vk-f229921/` | [Sikarugir-App/d9vk](https://github.com/Sikarugir-App/d9vk) branch `moltenvk-version` at commit `f229921c1b7f14edeadeccff04a9e65d0a016148`. That's the D9VK Sikarugir uses (DXVK 1.10.3-async + `[MTLHACK]` Metal fixes) **plus the June 2026 16-bit texture promotion (`a9e0a68`, `f229921`) that no d9vk release contains yet** | `DXVK: v1.10.3-brz-f229921 (macOS)` |
| `d9vk-f229921-diag/` | The same code plus [`patches/d9vk/0002-d3d9-diag-logging.patch`](../patches/d9vk/0002-d3d9-diag-logging.patch): logs (once each) every texture format the game creates, every format it probes, the device flags, the draw paths, and each fixed-function vertex/pixel setup (blend ops and whether a texture is bound) | `DXVK: v1.10.3-brz-f229921-diag (macOS)` |

Both were built with [`patches/d9vk/0001-mingw11-resourcemanager-compat.patch`](../patches/d9vk/0001-mingw11-resourcemanager-compat.patch). That patch only re-adds a struct typedef for MinGW-w64 < 12 and is guarded by a version check. Only the `d3d9` target is built (no dxgi/d3d10/d3d11).

- **Toolchain:** Ubuntu 24.04, mingw-w64 11.0.1 / GCC 13.2 (win32 threads), meson 1.3.2, ninja 1.11.1, glslang. Release build, stripped.
- **Reproduce:** `tools/build-d9vk.sh` (Linux or macOS + Homebrew). A from-scratch rebuild matched these files **except 6 bytes**: the PE header timestamp, the PE checksum, and the export-directory timestamp.
- **Checksums:** see [`SHA256SUMS`](SHA256SUMS).
- **Tested:** `bin/brz-probe.exe --full` under Wine 9.0 + Mesa lavapipe (software Vulkan): 93/93 checks, including the A4R4G4B4 promotion path (`Software Promotion` in the log). **Not yet tested on MoltenVK**: that's what `bash brz-mac.sh probe` does on the Mac.
- **Known issue on the Linux test box:** with a longer benchmark (60 frames × 1000 draws), *after* all 93 checks had passed, Wine 9.0's 32-bit Vulkan bridge asserted in `vkAllocateDescriptorSets` and the process died. That's an interaction of old Wine + lavapipe under load, not a rendering error. If the Mac shows `DIED after: the benchmark`, it's the same class of problem (the bridge, not the DLL's rendering), and `analyze` names the failing call.
- **License:** DXVK/D9VK is zlib-licensed (see the upstream `LICENSE`). These are unmodified upstream sources apart from the patches listed here.

You never need to copy these by hand: `bash brz-mac.sh profile d9vk` (or `d9vk-diag`) installs them next to the game exe and sets a per-game override. `profile wrapper` removes them again.

## What the diagnostic log looks like

The log goes to Wine's output, which `brz-mac.sh launch --debug` captures, or to `~/.brz-mac/logs` via `DXVK_LOG_PATH`. Sample from the probe (`../reference-results/linux-d9vk-diag-sample-log.txt`):

```
D3D9-DIAG: device created, BehaviorFlags=0x42 HARDWARE_VP FPU_PRESERVE robustness2=yes nullDescriptor=yes
D3D9-DIAG: texture fmt=D3D9Format::A4R4G4B4 type=TEXTURE pool=MANAGED usage=0x0 size=16x16 levels=1 -> vk=VK_FORMAT_B8G8R8A8_UNORM conversion=9
D3D9-DIAG: CheckDeviceFormat fmt=D3D9Format::A1R5G5B5 rtype=TEXTURE usage=0x0 -> OK
D3D9-DIAG: FF PS FF_FS_321d… | s0 C=BLENDTEXTUREALPHA(TEXTURE,TFACTOR) A=SELECTARG1(TEXTURE,DIFFUSE) tex=1 type=0
D3D9-DIAG: draw path VS=fixed-function PS=fixed-function (first seen at primitive type 5)
```

`bash brz-mac.sh analyze` turns these lines into findings. The most important one is *"a fixed-function stage reads TEXTURE but no texture is bound → returns black"*.
