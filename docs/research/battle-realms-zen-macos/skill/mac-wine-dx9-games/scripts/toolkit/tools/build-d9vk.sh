#!/bin/bash
# Rebuilds the two bundled D9VK DLLs (dlls/d9vk-f229921{,-diag}/d3d9.dll) from source.
#
# Needs: git, meson >= 0.49, ninja, glslangValidator, mingw-w64 (i686-w64-mingw32-gcc/g++).
#   Ubuntu/Debian: sudo apt install mingw-w64 meson ninja-build glslang-tools
#   macOS (Homebrew): brew install mingw-w64 meson ninja glslang
#
# Usage: tools/build-d9vk.sh [WORKDIR]     (default: ./d9vk-build)
# Output: WORKDIR/out/d9vk-f229921/d3d9.dll and WORKDIR/out/d9vk-f229921-diag/d3d9.dll
#
# Builds are functionally identical to the bundled ones; byte-for-byte equality is not
# guaranteed across compiler versions (the bundled ones used mingw-w64 GCC 13.2 on Ubuntu 24.04).

set -eu

COMMIT=f229921c1b7f14edeadeccff04a9e65d0a016148     # Sikarugir-App/d9vk, branch moltenvk-version
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$PWD/d9vk-build}"
SRC="$WORK/src"
OUT="$WORK/out"

for tool in git meson ninja glslangValidator i686-w64-mingw32-g++; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool" >&2; exit 1; }
done

mkdir -p "$WORK" "$OUT"
if [ ! -d "$SRC/.git" ]; then
  git clone --branch moltenvk-version https://github.com/Sikarugir-App/d9vk.git "$SRC"
fi
cd "$SRC"
git checkout -q -f "$COMMIT"
git clean -qfdx
git submodule update --init --depth 1

# 1) mingw-w64 < 12 compatibility (guarded by a version check; a no-op on newer MinGW)
git apply "$HERE/patches/d9vk/0001-mingw11-resourcemanager-compat.patch"

build() { # name version-string
  sed -i.bak "s/#define DXVK_VERSION .*/#define DXVK_VERSION \"$2 (macOS)\"/" version.h.in && rm -f version.h.in.bak
  rm -rf "build.$1"
  meson setup --cross-file build-win32.txt --buildtype release \
    -Denable_dxgi=false -Denable_d3d10=false -Denable_d3d11=false "build.$1" >/dev/null
  ninja -C "build.$1"
  mkdir -p "$OUT/$1"
  i686-w64-mingw32-strip -o "$OUT/$1/d3d9.dll" "build.$1/src/d3d9/d3d9.dll"
}

# 2) plain build: upstream d9vk HEAD (incl. the June 2026 16-bit texture promotion) + version stamp
build d9vk-f229921 "v1.10.3-brz-f229921"

# 3) diagnostic build: + D3D9-DIAG logging (texture formats, format checks, FF shader keys, draw paths)
git apply "$HERE/patches/d9vk/0002-d3d9-diag-logging.patch"
build d9vk-f229921-diag "v1.10.3-brz-f229921-diag"

echo
echo "Built:"
for f in "$OUT"/*/d3d9.dll; do
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f"; else shasum -a 256 "$f"; fi
done
