# brz-probe: a D3D9 feature probe

`../bin/brz-probe.exe` is a small 32-bit Windows program (source: `brz-probe.c`, build: `build.sh`). It draws known patterns with the Direct3D 9 features an early-2000s RTS engine relies on, reads the pixels back, and says which ones come out wrong, and *how*:

| Result | Meaning |
|---|---|
| `PASS` | Pixel matches the expected colour |
| `BLACK` | Something was drawn, but black. This is the in-game symptom. |
| `NOT DRAWN` | The clear colour is still there: the draw or its shader was dropped |
| `WRONG` | Drawn, in a different colour |
| `SKIP` | The D3D9 layer refuses that format or feature (reported, not counted as a failure) |
| `CRASH` / `ABORT` / `TIMEOUT during <step>` | The layer crashed, aborted (e.g. DXVK found no usable Vulkan device) or hung |

There are 31 checks, run on a hardware-vertex-processing device, a software one (`HardwareTL=0`-like) and a `Direct3DCreate9On12` device (`D3D9On12=1`-like):
- fixed-function vertex colour and TFACTOR
- textures: A8R8G8B8, X8R8G8B8, R5G6B5, X1R5G5B5, A1R5G5B5, A4R4G4B4, X4R4G4B4 (managed, mipmapped, sysmem→default, dynamic), L8, A8L8, A8, DXT1/3/5
- TFACTOR team colour via texture alpha (A8R8G8B8 / A4R4G4B4 / A1R5G5B5)
- two-stage modulate
- directional/vertex-colour/ambient lighting
- alpha test keep/discard, alpha blend
- render-to-texture

It also prints which `d3d9.dll` actually loaded (Wine builtin / D9VK-DXVK / dgVoodoo) and the adapter, and `--bench` measures a "many small team-coloured units" draw pattern.

You normally run it through `bash brz-mac.sh probe`. That runs it inside your wrapper under every renderer, without touching the game, and prints a comparison table. By hand:

```bash
wine brz-probe.exe --full --bench --label test     # writes brz-probe-test.txt next to the exe
```

Options: `--swvp`, `--on12`, `--full` (all three device modes), `--bench`, `--frames N`, `--draws N`, `--label NAME`, `--timeout SEC` (default 60, 0 = off).

Reference results from a Linux/Wine 9.0 test machine are in `../reference-results/`. Use them for what *should* pass; the benchmark numbers there are from software rendering and mean nothing on a Mac.
