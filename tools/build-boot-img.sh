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

# Attempt 2: embed the ZBI into the shim so it does not depend on the bootloader
# initrd (the GKI ramdisk concatenation corrupts it). The shim is built with
# set_zbi_boot("embed:zbi"). See docs/09.
PACKED="$REPO/dist/lagos-shim-embedded.bin"
python3 "$FUCHSIA/zircon/kernel/phys/linuxboot-embed.py" \
    --output "$PACKED" --shim "$SHIM" "$ZBI"
echo "packed shim+zbi: $(du -h "$PACKED" | cut -f1)"

# GZIP the kernel. The lagos expdb LK log proved Motorola/MediaTek LK gunzips the
# boot kernel unconditionally (stock kernel is Image.gz, magic 1f 8b): a raw Image
# fails with "gzip header is not correct. Error!", LK jumps to an empty kernel
# buffer, and the 21 s TOPRGU watchdog resets the SoC — our code never ran in
# attempts 1-5. See docs/11.
PACKED_GZ="$PACKED.gz"
gzip -9 -n -c "$PACKED" > "$PACKED_GZ"
echo "gzipped kernel: $(du -h "$PACKED_GZ" | cut -f1)  (magic: $(head -c 2 "$PACKED_GZ" | xxd -p))"

# Wrap the gzipped self-contained image as the boot kernel (ramdisk irrelevant: the
# ZBI is embedded inside the shim).
mkbootimg --header_version 4 --kernel "$PACKED_GZ" --out "$OUT"
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
