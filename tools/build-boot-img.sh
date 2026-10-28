#!/usr/bin/env bash
# Repackage the lagos Fuchsia boot image from a built Fuchsia arm64 tree.
# The .img is a build artifact (gitignored); regenerate it with this script.
#
# Requires: a completed `fx set bringup.arm64 && fx build` (with the fuchsia-lagos
# dw8250 mt6577-uart patch + the --jobs/sandbox build fixes), and mkbootimg on PATH.
#
# Usage:  ./tools/build-boot-img.sh [FUCHSIA_DIR]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUCHSIA="${1:-$REPO/../fuchsia}"
BD="$FUCHSIA/out/bringup.arm64-balanced"

SHIM="$BD/kernel.phys_arm64/linux-arm64-boot-shim.bin"
ZBI="$BD/obj/products/bringup/product_bundle.arm64/product_bundle/system_a/fuchsia.zbi"
OUT="$REPO/dist/lagos-fuchsia-boot.img"

command -v mkbootimg >/dev/null || { echo "mkbootimg not on PATH (try $FUCHSIA/zircon/third_party/tools/android/)"; exit 1; }
for f in "$SHIM" "$ZBI"; do [ -f "$f" ] || { echo "missing build artifact: $f"; echo "run: cd $FUCHSIA && fx set bringup.arm64 && fx build"; exit 1; }; done

mkdir -p "$REPO/dist"
echo "shim: $(du -h "$SHIM" | cut -f1)   zbi: $(du -h "$ZBI" | cut -f1)"
mkbootimg --header_version 4 --kernel "$SHIM" --ramdisk "$ZBI" --out "$OUT"
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
