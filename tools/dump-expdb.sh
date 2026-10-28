#!/usr/bin/env bash
# Dump the MediaTek `expdb` partition (preloader + LK logs + reset records of the last
# ~9 boots) from a booted, rooted lagos, and print the lines that matter for a Fuchsia
# boot attempt: how LK handled the kernel (gunzip / decompress / jump) and why the
# previous boot reset (watchdog, stage, reason).
#
# Why exec-out: `dd ... of=/sdcard/expdb.bin` returned 0 bytes for this partition on
# lagos; streaming the block device over adb works.
#
# Requires: adb, device booted into Android with root (KernelSU), python3.
# Usage:  ./tools/dump-expdb.sh [OUT_DIR]      (default: dist/expdb-<timestamp>)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB="${ADB:-adb}"
OUT="${1:-$REPO/dist/expdb-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

"$ADB" devices | grep -qw device || { echo "no adb device (boot into Android first)"; exit 1; }
"$ADB" shell 'su -c id' | grep -q 'uid=0' || { echo "no root over adb"; exit 1; }

size=$("$ADB" shell 'su -c "blockdev --getsize64 /dev/block/by-name/expdb"' | tr -d '\r')
echo "expdb: $size bytes -> $OUT/expdb.bin"
"$ADB" exec-out 'su -c "dd if=/dev/block/by-name/expdb bs=1M 2>/dev/null"' > "$OUT/expdb.bin"
echo "dumped: $(stat -c%s "$OUT/expdb.bin") bytes"

python3 -I - "$OUT/expdb.bin" <<'PY' | tee "$OUT/summary.txt"
import sys, re
text = open(sys.argv[1], 'rb').read().decode('latin-1')
L = [l.rstrip() for l in re.split(r'[\r\n]+', text)]

def section(title, pat, maxhits=40, before=1, after=3, exclude=None, dedupe=True):
    print(f'\n######## {title} ########')
    rx = re.compile(pat, re.I); shown = set(); n = 0
    for i, l in enumerate(L):
        if rx.search(l) and not (exclude and re.search(exclude, l, re.I)):
            # Dedupe masks digits, which would hide e.g. kernel_sz=0x01c03e38 vs
            # 0x01c03e48 or "takes 0 ms" vs "takes 1234 ms" — never dedupe the
            # kernel-handling section.
            k = re.sub(r'\d', '#', l)[:90] if dedupe else f'{i}'
            if k in shown: continue
            shown.add(k); n += 1
            print(f'  --- @{i} ---')
            for j in range(max(0, i-before), min(len(L), i+after+1)):
                s = L[j].strip()
                if s: print(('  > ' if j == i else '    ') + s[:170])
            if n >= maxhits: print('  ...(truncated)'); break

# How LK handled the boot-image kernel on each boot (the Fuchsia fingerprint is a
# non-14MB kernel_sz; a gzip error means our raw Image; a nonzero decompress time
# plus the later steps means LK handed off).
section('LK: kernel size / gunzip / decompress / handoff',
        r'(kernel real kernel_sz|gzip header|decompress_kernel|Met bootstrap2|load boot image takes|img_auth_required|boot state:|jump|Switch to kernel|boot_time|kernel_start|start_kernel)',
        40, before=1, after=2)
# Why the previous boot reset.
section('RESET attribution (stage / watchdog / reason)',
        r'(\[RGU\] rst from|WDT_PRE|boot_reason\(|WDT get boot reason|AP Watchdog|bit10=1|wdt_status|\[RGU\] MODE:|LENGTH:)',
        20, before=1, after=2)
print('\n(records = distinct "[NNNN] [FAC]" counters: '
      + str(sorted(set(int(m) for m in re.findall(r'\[(\d{3,5})\] \[FAC\]', text)))) + ')')
print('NOTE: "[FAC] read: id=29 ... Linux version" is a factory string, NOT proof a kernel ran.')
PY
echo
echo "summary: $OUT/summary.txt"
