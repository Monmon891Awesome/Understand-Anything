# Battle Realms: Zen Edition on M1: consultant's plan & toolkit

> **Starting the debugging session? Go to [`MORNING.md`](MORNING.md).** This page is the overview.

| | |
|---|---|
| **Client setup** | MacBook M1 (base: 8 GB RAM, 7/8-core GPU), ~17 GB free, Sikarugir / Porting Kit, Steam build of Zen Edition |
| **Problem** | OpenGL path (WineD3D) lags in battles and cutscenes. The Vulkan path (D9VK) fixes the lag, but gives a black screen or black-shaded units and buildings. |
| **Goal** | Vulkan-level performance with correct rendering, in ~7 GB of disk |
| **Deliverables** | [`MORNING.md`](MORNING.md) runbook · [`brz-mac.sh`](brz-mac.sh) toolkit · [`bin/brz-probe.exe`](probe/) D3D9 probe · [`dlls/`](dlls/) patched D9VK builds · [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) · [`WRAPPER-SETUP.md`](WRAPPER-SETUP.md) · [`RESEARCH.md`](RESEARCH.md) (evidence + sources) · [`tests/`](tests/) |

---

## 1. Executive summary

1. **The lag is solved in principle.** Vulkan removed it in your own test. The OpenGL path is the bottleneck, not the M1. Don't go back to tuning OpenGL.
2. **The black units now have a concrete, source-level explanation** (see §2, H0):
   - Old D3D9 games keep unit textures in **16-bit formats** (A4R4G4B4, A1R5G5B5, R5G6B5).
   - Sikarugir's D9VK only gained a software path for those formats in **June 2026**, and **no D9VK release contains it yet**. The latest release is from May 2025.
   - In D9VK, a fixed-function stage that reads a texture which isn't bound returns **(0,0,0,1): black**. So a unit texture that fails to create renders as exactly what you saw: black units on correct terrain.
   - I built that D9VK fix as a 32-bit DLL (`dlls/d9vk-f229921/`), plus a diagnostic variant that logs every texture format and blend stage the game uses.
3. **The fully black screen is a different bug** (presentation), with different fixes: windowed mode, Retina off per game, `D3D9On12=0`.
4. **Tonight's new finding: `D3D9On12 = 1` in `Battle_Realms.ini`.** The game can ask for Microsoft's D3D9-on-D3D12 layer. No Mac layer implements it: DXVK and Wine log it as unimplemented and fall back to plain D3D9, and Wine 9.0 doesn't even export the function. Setting it to `0` removes an unknown, at no cost.
5. **The "lag when more units come in" has a likely mechanism.** New unit and effect types trigger pipeline compiles (SPIR-V → Metal). D9VK is the **async** DXVK 1.10.3 branch, so `dxvk.enableAsync = True` turns those hitches into pop-in. The DXVK 3.x fork (metalsharp) has no async on MoltenVK, so the *newer* build may stutter *more*.
6. **What can't help this game:**
   - **D3DMetal/GPTK** (64-bit DX11/12 only).
   - **DXVK 3.x on a MoltenVK older than 1.3.0**: it needs `VK_KHR_load_store_op_none` and refuses to start ("No adapters found"). I reproduced that refusal here.
7. **Expectation:** big 4v4 fights will still dip, because the simulation runs on one thread through Rosetta 2. Aim for a **stable 45–60 FPS cap**. `HardwareTL=1` moves vertex lighting to the GPU, which lowers that CPU load.

## 2. Diagnosis: hypotheses, evidence, and the test that decides each

| # | Hypothesis for black units | Confidence | Evidence so far | Decided by |
|---|---|---|---|---|
| **H0** | 16-bit texture formats fail in older D9VK under MoltenVK → texture never bound → FF stage reads black | **High** | d9vk commits a9e0a68/f229921 (June 2026) add software promotion for exactly A4R4G4B4/A1R5G5B5/R5G6B5. DXVK's FF code returns `(0,0,0,1)` for unbound textures. The latest d9vk release (2025-05) predates the fix. | `probe`: `BLACK` on 16-bit rows for `wrapper`, `ok` for `d9vk`. Triage round 2. |
| H1 | Texture/blend path the probe doesn't cover | Medium | — | Triage round `d9vk-diag` + `analyze` ("reads TEXTURE but no texture is bound", "cannot map (FMT)") |
| H2 | `D3D9On12=1` side effects | Low-medium | DXVK: "9On12 functionality is unimplemented" (falls back) | Triage round 3 (`D3D9On12=0`) |
| H3 | Lighting path difference (`HardwareTL` 0 = CPU T&L in game, 1 = D3D FF lighting) | Medium | The two paths use different D3D features | Triage round 4; probe `light:` rows |
| H4 | NaN from float rules in old shaders | Low-medium | — | `d3d9.floatEmulation = Strict` (in template) |
| H5 | MoltenVK image-view swizzle | Low (Apple Silicon swizzles natively) | MoltenVK maps A4R4G4B4 via swizzled ABGR4Unorm | `launch`/`probe` set `MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE=1` |
| H6 | CodeWeavers' MoltenVK behaves differently | Unknown | Configure offers *MoltenVK - (CodeWeavers version)* | `probe` once with each setting |
| H7 | Zen Edition's own material bug (also on Windows) | Low | Patch 1.60 reduced it | Same scene black in `wined3d` → game bug |

| # | Hypothesis for fully black screen | Confidence | Decided by |
|---|---|---|---|
| S1 | Exclusive fullscreen / mode switch / Retina scaling | High | HUD visible over black → presenting. Triage repeats the round with `Fullscreen=0` + `RetinaMode=N` |
| S2 | The D3D9 layer never loaded or aborted | Medium | `analyze`: "a DLL failed to load" / "aborted"; `identify` shows arch |
| S3 | `HardwareTL` display-init failure | Low | `ini set HardwareTL 0/1` (community fixes) |

## 3. Test plan

The test plan is **automated**. `MORNING.md` walks through it:

```
doctor ─► probe (all renderers, unattended, ~5–10 min) ─► triage (guided game rounds) ─► report
```

- **`probe`** runs `bin/brz-probe.exe`, a small D3D9 program I wrote. It goes into the wrapper under each renderer (wrapper default, WineD3D-GL, WineD3D-Vulkan, bundled D9VK, metalsharp DXVK, dgVoodoo) and draws 31 known patterns ×3 device modes:
  - 16-bit, L8/A8 and DXT textures
  - TFACTOR team colour
  - two-stage modulate
  - fixed-function lighting
  - alpha test/blend
  - render-to-texture

  It then reads the pixels back. Each result is `PASS`, `BLACK`, `NOT DRAWN`, `WRONG` or `SKIP`, plus a "many small units" draw-call benchmark. It prints `CRASH/ABORT/TIMEOUT during <step>` instead of hanging.
- **`triage`** goes one change per round in the real game, in order: baseline → D9VK 16-bit fix → `D3D9On12=0` → `HardwareTL` flip → diagnostic build → DXVK 3.x → dgVoodoo/DXMT → WineD3D-Vulkan → WineD3D-GL. You answer 5 questions per round, and each round's log is analyzed automatically.

**Acceptance criteria:**
- Units and buildings correctly shaded for a 20-minute skirmish.
- At least 45 FPS average and 25 FPS minimum in a 4-AI fight.
- Cutscenes without drift.
- Wrapper ≤ 8 GB.

## 4. Toolkit: `brz-mac.sh` v2

One bash file. It runs on macOS's own bash 3.2 and awk, with nothing to install. It only changes things **for this game**: per-app Wine keys, DLLs in the game folder (stashing any originals), and the game's ini (section-aware, keeping CRLF line endings). Everything is backed up to `~/.brz-mac/backups/`, and `restore` undoes it all.

| Command | What it does |
|---|---|
| `doctor` | Mac (macOS, RAM, Rosetta, Low Power Mode, battery, disk), wrapper (wine version, MoltenVK, DXMT/D3DMetal presence, what `syswow64/d3d9.dll` really is), game (exe arch, ini video keys incl. `D3D9On12`, DLLs, cutscene video files), per-game Wine keys |
| `probe [--quick] [profiles]` | Probe under each renderer → comparison table in `~/.brz-mac/logs/probe-*/matrix.txt` |
| `triage [--reset]` | Guided rounds as above; resumable; stops at the first correct round with ≥ 45 FPS |
| `analyze [files]` | Matches Wine/DXVK/MoltenVK/probe log lines against ~30 known signatures: unbound texture → black, unsupported format, MoltenVK shader-translation failure, device lost, no adapter + missing feature, MoltenVK < 1.3.0, D3D9On12, crashes, missing DLLs, display-mode errors. It also summarizes which texture formats and fixed-function setups the game uses. |
| `report` | One markdown file with doctor, ini, dxvk.conf, probe matrix, triage log, bench and analysis. **Send me this.** |
| `profile NAME [DIR]` | `wrapper`, `wined3d`, `wined3d-vk`, `d9vk`, `d9vk-diag`, `dxvk`, `dgvoodoo`. Picks i386 DLLs by PE header and refuses x64. |
| `fetch dxvk\|dgvoodoo [ver]` | Downloads the metalsharp DXVK-MacOS release / dgVoodoo2 (default 2.87.5) into `~/.brz-mac/downloads` |
| `identify [files]` | What a `d3d9.dll` really is (Wine builtin/placeholder, D9VK/DXVK + traits like `+16-bit-promotion`, `+diag-logging`, `+async`, dgVoodoo) |
| `ini …`, `conf dxvk\|dgvoodoo …`, `retina on\|off` | Edit `Battle_Realms.ini` (new keys go into the right `[section]`), `dxvk.conf`/`dgVoodoo.conf`, and per-game Retina mode |
| `launch [--hud] [--debug]` | Quiet Steam (`-silent -nofriendsui -nochatui -noverifyfiles -applaunch 1025600`) with the MoltenVK, MSync and DXVK log env. `DXVK_LOG_PATH` is set as a Windows `Z:` path, because Wine ignores Unix paths for it. |
| `bench`, `disk [--clean]`, `logs`, `kill`, `restore` | Benchmark log · space · zip of raw logs · stop Wine · undo everything |

**Important launch detail:** env vars reach the game only if **Steam isn't already running** (otherwise `-applaunch` hands off to the running Steam). The script warns about this. `dxvk.conf` lives in the game folder, so its settings apply however you launch.

## 5. What was verified, and where

| Item | Verified how | Result |
|---|---|---|
| `brz-mac.sh` (mock) | 88 tests against a mock wrapper (Python fake `wine` that stores registry keys in Wine's `user.reg` format and simulates probe runs, including one that dies mid-run). Run under **Apple's bash 3.2.57 source build + BWK awk** (macOS's own tools) and under GNU bash 5.2 + mawk. Shellcheck clean. | 88/88 on both |
| `brz-mac.sh` (real Wine) | End-to-end `probe` through a wrapper-shaped folder backed by **real Wine 9.0** + Xvfb: real per-app registry keys, `wineserver -w`, `Z:` log path, matrix, `analyze`, `report` | `wined3d` 62/62 (+1 skip) · `d9vk` 93/93 · `d9vk-diag` 93/93; earlier longer-benchmark runs found 3 real issues (deaths not reported, false positive on alpha-only reads, imprecise "where it died"), now fixed and covered by tests |
| `brz-probe.exe` | Wine 9.0 on Linux: WineD3D/llvmpipe-GL and bundled D9VK/lavapipe-Vulkan, HWVP + SWVP + On12 devices | 62/62 (+1 skip: Wine 9 lacks `Direct3DCreate9On12`) · 93/93 |
| `dlls/d9vk-f229921{,-diag}` | Probe on lavapipe (16-bit promotion path exercised: log shows *Software Promotion*). Rebuilt from scratch with `tools/build-d9vk.sh`: identical except the 6 bytes of PE/export timestamps and the checksum. | 93/93 both; diag overhead ≈2% |
| metalsharp DXVK 3.1 | Built from source (HEAD 8d34823, newer than the v3.1-macos1.0 release) and probed on lavapipe | Aborts: *"Skipping: Device does not support required feature 'khrLoadStoreOpNone'"*. That's the same failure an old MoltenVK will produce. |
| dgVoodoo2 2.87.5 | Probed over Wine's own D3D11 and over DXVK's D3D11 on lavapipe | `CRASH during CreateDevice` (integer divide by zero inside dgVoodoo) in this headless setup: **inconclusive**, the Mac + DXMT run decides |
| **Not verified** | A real Mac + Sikarugir + MoltenVK run | That's tomorrow's `probe` |

## 6. Resource plan (base M1, 17 GB free)

| Resource | Budget | Notes |
|---|---|---|
| Disk | ~7 GB for one wrapper | **One wrapper only**; profiles switch renderers inside it. Toolkit + downloads ≈ 30 MB. Keep 8–10 GB free for swap. |
| RAM | 8 GB shared CPU/GPU | Close browsers and Electron apps |
| CPU | One busy thread under Rosetta 2 | Charger in, Low Power Mode off, `HardwareTL=1`, 60 FPS cap (`d3d9.maxFrameRate`) |
| GPU | Plenty on D9VK/Metal | Lower shadows/AA in game first |
| Steam | Needed for DRM, should stay idle | Overlay off, web-view GPU acceleration off, `-silent -nofriendsui -nochatui` |

## 7. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Bundled D9VK is my build of an **unreleased** upstream commit | An unknown regression | Per-game only; probe-tested; `tools/build-d9vk.sh` reproduces it from public source + 2 small patches; `profile wrapper` switches back instantly |
| metalsharp DXVK-MacOS is brand new (1 release, 1 maintainer) and needs MoltenVK ≥ 1.3.0 | Won't start on older wrappers | `analyze` explains the abort; `BRZ_MVK_DIR` (experimental) uses the release's own MoltenVK |
| Sikarugir engine update resets the prefix | Profile silently lost | `doctor` shows the profile and keys; re-run `profile …` |
| Zen Edition's own black-texture bug | Some black units on any renderer | Compare with `wined3d` |
| Fake download sites | Malware | Install Sikarugir only from its Homebrew tap/GitHub. **sikarugir.com is not theirs** (their README says so). |

## 8. What I'd watch next

- **KosmicKrisp** (Mesa Vulkan-on-Metal, Vulkan 1.3 conformant, needs Metal 4 / macOS 26) as a selectable driver in Sikarugir or CrossOver.
- **A tagged D9VK release** containing the June 2026 16-bit fix. Once Sikarugir ships it, the bundled DLL is no longer needed.
- **DXMT's D3D9 frontend + i386** and **d9mt** (D3D9 straight to Metal), once they're past "tested on one title".

## 9. What I need from you

The `report-*.md` from `bash brz-mac.sh report`, and one screenshot of the black units (if any remain). See [`MORNING.md`](MORNING.md).
