#!/usr/bin/env bash
# Flash the Fuchsia bringup image to the Moto G06 (lagos) SLOT B only.
# Slot A (your working TrebleDroid) is never touched and is the recovery path.
#
# This is an EXPERIMENT: without physical UART access you will only see gross boot
# behavior (bootloop / hang / fallback to slot A), not Zircon's console. See docs/08.
#
# Requires: device in fastboot (bootloader) mode, bootloader unlocked.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="$REPO/dist/lagos-fuchsia-boot.img"
FB="${FASTBOOT:-fastboot}"

[ -f "$IMG" ] || { echo "missing $IMG — run ./tools/build-boot-img.sh first"; exit 1; }
command -v "$FB" >/dev/null || { echo "fastboot not found (set FASTBOOT=...)"; exit 1; }

echo "== device check =="
"$FB" getvar product 2>&1 | grep -q 'product: *lagos' || { echo "not a lagos device / not in fastboot"; exit 1; }
slot=$("$FB" getvar current-slot 2>&1 | sed -n 's/current-slot: *//p' | head -1)
unlocked=$("$FB" getvar unlocked 2>&1 | sed -n 's/unlocked: *//p' | head -1)
echo "current-slot=$slot  unlocked=$unlocked"
[ "$unlocked" = "yes" ] || { echo "bootloader is locked — aborting"; exit 1; }

echo
echo "This will:"
echo "  1. back up boot_b -> $REPO/dist/boot_b.backup.img"
echo "  2. flash $IMG -> boot_b"
echo "  3. set active slot to B and reboot"
echo "Recovery at any time:  $FB set_active a   (TrebleDroid on slot A)"
read -rp "Proceed? [type: yes] " ans
[ "$ans" = "yes" ] || { echo "aborted"; exit 0; }

echo "== 1. backing up boot_b =="
"$FB" fetch boot_b "$REPO/dist/boot_b.backup.img" 2>/dev/null \
  && echo "   saved dist/boot_b.backup.img" \
  || echo "   (fetch unsupported on this bootloader; rely on stock zip / backup/ for recovery)"

echo "== 2. flashing boot_b =="
"$FB" flash boot_b "$IMG"

echo "== 3. activating slot B and rebooting =="
"$FB" set_active b
"$FB" reboot

echo
echo "Booting slot B. Watch the device (and UART if wired)."
echo "To return to TrebleDroid:  $FB set_active a   (then reboot)"
