#!/usr/bin/env bash
# Extract and decompile the device tree from the Moto G06 (lagos) stock firmware.
#
# Reproduces the recon done on 2026-10-27. Output is written to device-tree/.
#
# The device tree the MediaTek bootloader hands to the kernel lives inside
# vendor_boot.img, wrapped in an Android DTB/DTBO table container (magic
# 0xd7b7ab1e). This script unpacks vendor_boot, parses that container, carves
# out the FDT blob(s), and decompiles them with dtc.
#
# Requirements: unpack_bootimg (android tools), dtc, python3, unzip.
#
# Usage:  ./tools/extract-device-tree.sh /path/to/stock_firmware.zip
#
# Default stock zip (Motorola RETBR lagos A15):
#   ../moto-g06-mod/tools/RETBR_XT2535-1_lagos_g_user_15_VVOBS35.78_158_1_6d855a_release_keys_CFC.zip

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/device-tree"
WORK="$OUT/work"

DEFAULT_ZIP="$REPO/../moto-g06-mod/tools/RETBR_XT2535-1_lagos_g_user_15_VVOBS35.78_158_1_6d855a_release_keys_CFC.zip"
ZIP="${1:-$DEFAULT_ZIP}"

for t in unpack_bootimg dtc python3 unzip; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 1; }
done
[ -f "$ZIP" ] || { echo "stock firmware zip not found: $ZIP" >&2; exit 1; }

echo "== stock zip: $ZIP"
mkdir -p "$WORK" "$OUT/dts" "$OUT/raw"

echo "== extracting vendor_boot.img, boot.img, dtbo.img, lk.img"
unzip -o -j "$ZIP" vendor_boot.img boot.img dtbo.img lk.img -d "$WORK" >/dev/null

echo "== unpacking vendor_boot.img"
rm -rf "$WORK/vendor_boot"
unpack_bootimg --boot_img "$WORK/vendor_boot.img" --out "$WORK/vendor_boot" \
    | tee "$OUT/vendor_boot-header.txt"

echo "== parsing DTBO-table container and carving FDT(s)"
python3 -I - "$WORK/vendor_boot/dtb" "$OUT/raw" <<'PY'
import struct, sys
dtb, outdir = sys.argv[1], sys.argv[2]
d = open(dtb, "rb").read()
magic = d[:4].hex()
if magic != "d7b7ab1e":
    # already a raw FDT?
    if magic == "d00dfeed":
        open(f"{outdir}/vendor_boot-fdt0.dtb", "wb").write(d)
        print("raw FDT, wrote fdt0"); sys.exit(0)
    sys.exit(f"unknown dtb container magic: {magic}")
_, total, hs, es, cnt, eoff, ps, ver = struct.unpack(">8I", d[:32])
print(f"DTBO table: entries={cnt} entry_size={es} entries_offset={eoff}")
for i in range(cnt):
    base = eoff + i*es
    sz, off = struct.unpack(">2I", d[base:base+8])
    blob = d[off:off+sz]
    open(f"{outdir}/vendor_boot-fdt{i}.dtb", "wb").write(blob)
    print(f"  fdt{i}: offset={off} size={sz}")
PY

echo "== decompiling FDT(s) with dtc"
for f in "$OUT"/raw/vendor_boot-fdt*.dtb; do
    name="$(basename "$f" .dtb)"
    dtc -I dtb -O dts -o "$OUT/dts/${name}.dts" "$f" 2>"$OUT/dts/${name}.dtc.log" || true
    lines=$(wc -l < "$OUT/dts/${name}.dts" 2>/dev/null || echo 0)
    echo "  $name -> dts/${name}.dts ($lines lines)"
done

echo
echo "== done. Device tree at: $OUT/dts/"
echo "   Model/SoC:"
grep -m2 -E '^\s*(model|compatible)' "$OUT/dts/vendor_boot-fdt0.dts" || true
