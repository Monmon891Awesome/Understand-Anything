# A clean Sikarugir wrapper for Battle Realms: Zen Edition

Use this when you start over, or when you want a second wrapper for comparison. The option names below are copied from the Configure app's own source (`Sikarugir-App/Sikarugir-foss-sources`), so they match what you'll see.

> ⚠️ **Only install Sikarugir from its GitHub/Homebrew tap.** The project's README says *"If you came here from https://sikarugir.com scan your system for malware, that site is not affiliated, owned nor ran by the Sikarugir team!"* That site ranks high in search results. If you ever downloaded anything from it, scan your Mac and reinstall from the official source.

## 1. Install (official)

```bash
/usr/sbin/softwareupdate --install-rosetta --agree-to-license      # Apple Silicon needs Rosetta 2
brew upgrade
brew trust Sikarugir-App/sikarugir
brew install --cask Sikarugir-App/sikarugir/sikarugir
```

Sikarugir supports macOS 14.6 or later. According to its README, **D9VK (DirectX 9 via Vulkan) is the default D3D9 path on "Apple Silicon & macOS Tahoe"**. On older macOS versions, D3D9 games run on WineD3D/OpenGL, which is the slow path you saw. `bash brz-mac.sh doctor` shows your macOS version and which `d3d9.dll` the wrapper actually loads.

## 2. Create the wrapper

1. Open **Sikarugir Creator** and pick the newest engine it offers. Battle Realms is **32-bit**, so the engine needs 32-bit support (WoW64). Current engines have it.
2. Name it, for example, `Battle Realms`. It is created under `~/Applications/Sikarugir/`.
3. Optional space saver: Configure has *"Skip Gecko Installation"* and *"Skip Mono Installation"* (both need *"Rebuild Wrapper"*). Steam doesn't need them, and skipping them saves ~200 MB.

## 3. Configure (the wrapper's **Configure** app)

| Option (exact name) | Set to | Why |
|---|---|---|
| *DirectX to Metal translation layer - (DXMT)* | **on** | Needed only for the `dgvoodoo` route (D3D9 → D3D11 → Metal). It's harmless for D9VK. |
| *Direct3D to Metal translation layer - (D3DMetal)* | **off** | 64-bit D3D11/12 only, so it never helps this game |
| *DirectX to Vulkan translation layer - (DXVK)* | off | That toggle is D3D10/11 only. The D3D9 path is D9VK or our per-game DLL. |
| *MoltenVK - (CodeWeavers version)* | try **both** | CrossOver's MoltenVK fork is a cheap extra variable against black textures: run `bash brz-mac.sh probe` once with each setting |
| *MoltenVK FastMath* | off while debugging | Black pixels can come from NaNs. Turn it back on later if it makes no visual difference. |
| *mach semaphore-based synchronization (msync)* | **on** | Lower CPU overhead under Wine on macOS |
| *eventfd-based synchronization (esync)* | off when msync is on | Use one or the other |
| *Limit to 1 CPU core* | **off** | It would cripple big battles |
| *Performance HUD - (DXVK/Metal)* | on while testing | FPS overlay even when you start from Finder |
| *Always make Log file, not only when doing a Test Run* | **on** | Gives `bash brz-mac.sh analyze` the wrapper's log too |
| *Disable winedbg dialog* | on | A crash then shows up in the log instead of hanging a window |
| *Map Command key to Ctrl* | your choice | For hotkeys |

Retina mode: `bash brz-mac.sh retina off` writes the same two wrapper-wide values as Configure's Retina option (`RetinaMode` and `LogPixels`). Wine reads Retina mode only wrapper-wide, never per game. The change is backed up first, and `restore` undoes it.

## 4. Steam inside the wrapper

1. Configure → **Install Software** → *Choose Setup Executable* → `SteamSetup.exe` from steampowered.com. Always install to `C:`.
2. Start Steam once from the wrapper and let it update completely. Log in, and tick "remember me".
3. In Steam settings:
   - **In Game** → untick *Enable the Steam Overlay while in-game*
   - **Interface** → untick *Enable GPU accelerated rendering in web views* (Steam's built-in browser is heavy under Wine)
   - **Downloads** → untick *Enable Shader Pre-caching* (Windows/Vulkan shaders are useless on a Mac and take disk space)
4. Install Battle Realms: Zen Edition, then start it **once** normally so it creates `Battle_Realms.ini`. Quit it.
5. Point Configure's *Windows EXE* at Steam (`C:\Program Files (x86)\Steam\steam.exe`) with the flags `-silent -nofriendsui -nochatui -applaunch 1025600`, so double-clicking the wrapper starts the game directly with a quiet Steam.

## 5. Game settings worth checking first

`bash brz-mac.sh ini show`, then:

| Key (`[VideoState]`) | Start with | Notes |
|---|---|---|
| `Width` / `Height` | `1440` / `900` | The default scaled size of the 13-inch M1 Air/Pro panel; lower (`1280`/`800`) if FPS is tight |
| `Fullscreen` | `1`, or `0` if the screen is black | Windowed mode avoids mode switches that MoltenVK can refuse |
| `HardwareTL` | `1` | GPU lighting, less CPU in big fights. Use `0` only if `1` renders wrong or won't start. |
| `D3D9On12` | `0` | No Mac layer implements D3D9-on-12; `1` only adds an unknown |

## 6. Disk (17 GB free)

One wrapper uses about 7 GB (engine 1–1.5 GB, Steam 1–1.5 GB, game ~4 GB). `bash brz-mac.sh disk` shows the breakdown, and `disk --clean` drops Steam's caches. Keep 8–10 GB free while playing: with 8 GB of RAM, macOS swaps, and a full disk turns into stutter.
