#!/bin/bash
# Builds bin/brz-probe.exe (32-bit Windows console program) with mingw-w64.
#   Ubuntu/Debian: sudo apt install gcc-mingw-w64-i686     macOS: brew install mingw-w64
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
i686-w64-mingw32-gcc -O2 -std=c11 -Wall -Wextra -o "$HERE/../bin/brz-probe.exe" "$HERE/brz-probe.c" -ld3d9 -static
echo "built $HERE/../bin/brz-probe.exe"
