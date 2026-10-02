#!/usr/bin/env python3
"""Minimal stand-in for a wrapper's `wine` binary, for brz-mac.sh tests.

Implements just what the script uses:
  wine --version
  wine reg add|delete KEY /v NAME [/t REG_SZ /d DATA] /f   (stored in $WINEPREFIX/user.reg, Wine's format)
  wine steam.exe ...                                       (logged only)
  wine brz-probe.exe ... --label L                         (writes a plausible brz-probe-L.txt in cwd)
Every call is appended to $WINEPREFIX/wine-calls.log.
"""
import os
import re
import sys

prefix = os.environ["WINEPREFIX"]
args = sys.argv[1:]
with open(os.path.join(prefix, "wine-calls.log"), "a") as log:
    log.write("wine " + " ".join(args) + "\n")


def reg_path():
    return os.path.join(prefix, "user.reg")


def load():
    """Returns (header_lines, [(section_name, [value lines])]) from user.reg."""
    if not os.path.exists(reg_path()):
        return ["WINE REGISTRY Version 2"], []
    header, sections, cur = [], [], None
    for raw in open(reg_path(), newline=""):
        line = raw.rstrip("\r\n")
        m = re.match(r"^\[(.*)\](.*)$", line)
        if m:
            cur = [m.group(1), []]
            sections.append(cur)
        elif cur is None:
            header.append(line)
        elif line.strip():
            cur[1].append(line)
    return header, sections


def save(header, sections):
    with open(reg_path(), "w", newline="") as f:
        f.write("\n".join(header) + "\n")
        for name, values in sections:
            f.write("\n[%s] 1700000000\n" % name)
            for v in values:
                f.write(v + "\n")


def wine_key(key):
    key = re.sub(r"^HKCU\\", "", key)
    return key.replace("\\", "\\\\")


if args[:1] == ["--version"]:
    print("wine-9.0 (fake)")
    sys.exit(0)

if args[:1] == ["reg"]:
    op, key = args[1], wine_key(args[2])
    name = args[args.index("/v") + 1]
    header, sections = load()
    sec = next((s for s in sections if s[0].lower() == key.lower()), None)
    if op == "add":
        data = args[args.index("/d") + 1]
        if sec is None:
            sec = [key, []]
            sections.append(sec)
        sec[1] = [v for v in sec[1] if not v.lower().startswith('"%s"=' % name.lower())]
        sec[1].append('"%s"="%s"' % (name, data))
    elif op == "delete" and sec is not None:
        sec[1] = [v for v in sec[1] if not v.lower().startswith('"%s"=' % name.lower())]
    save(header, sections)
    sys.exit(0)

if args[:1] == ["brz-probe.exe"]:
    label = args[args.index("--label") + 1] if "--label" in args else "run"
    dll = os.path.join(os.getcwd(), "d3d9.dll")
    blob = open(dll, "rb").read() if os.path.exists(dll) else b""
    fixed = b"Software Prom" in blob
    if label == "dxvk":
        # simulate dying inside Wine's Vulkan bridge after two checks (no summary line)
        with open("brz-probe-%s.txt" % label, "w") as f:
            f.write("brz-probe 1.0.0 (label: dxvk)\n\n== HWVP device (like HardwareTL=1) ==\n"
                    "  PASS      ff: vertex colour, no texture      want ff8000 got ff8000\n"
                    "  PASS      tex A8R8G8B8 managed               want 00ff00 got 00ff00\n"
                    "phase      benchmark (1000 draws/frame)\n")
        print('0110:err:msvcrt:_wassert (L"!status && \\"vkCreateGraphicsPipelines\\"",L"dlls/winevulkan/loader_thunks.c",2909)')
        sys.stdout.flush()
        os._exit(134)
    renderer_vk = False
    _, sections = load()
    for name, values in sections:
        if "brz-probe.exe" in name and name.lower().endswith("direct3d"):
            renderer_vk = any('"renderer"="vulkan"' in v for v in values)
    tests = ["ff: vertex colour, no texture", "tex A8R8G8B8 managed", "tex R5G6B5 managed",
             "tex A4R4G4B4 managed", "team colour A4R4G4B4 alpha=0", "light: directional, material red"]
    lines = ["brz-probe 1.0.0 (label: %s)" % label, "", "== HWVP device (like HardwareTL=1) =="]
    lines.append("d3d9.dll   C:\\fake\\d3d9.dll")
    bad = 0
    for t in tests:
        status = "PASS"
        if not blob and label == "wrapper" and "A4R4G4B4" in t:
            status = "BLACK"          # the old wrapper D9VK: 16-bit textures come out black
        if renderer_vk and t.startswith("light"):
            status = "NOT DRAWN"
        if status != "PASS":
            bad += 1
            lines.append("  %-9s %-34s want 00ff00 got 000000" % (status, t))
        else:
            lines.append("  %-9s %-34s want 00ff00 got 00ff00" % (status, t))
    fps = {"wined3d": 25, "wrapper": 90, "d9vk": 88}.get(label, 60)
    lines.append("bench      1500 draws/frame x 90 frames: avg %.2f ms (%d fps), best 1.00 ms, 1 draws/s" % (1000.0 / fps, fps))
    lines.append("")
    lines.append("summary    %d passed, %d failed, 0 skipped  -> brz-probe-%s.txt" % (len(tests) - bad, bad, label))
    with open("brz-probe-%s.txt" % label, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    if fixed:
        print("warn:  D3D9: VK_FORMAT_A4R4G4B4_UNORM_PACK16_EXT -> VK_FORMAT_B8G8R8A8_UNORM (Software Promotion)")
    sys.exit(bad)

# steam.exe and anything else: just succeed
sys.exit(0)
