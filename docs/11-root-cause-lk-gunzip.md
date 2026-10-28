# 11 — ROOT CAUSE: LK gunzips the kernel; our raw Image never ran

After five attempts that bootlooped identically regardless of what was inside the image,
the answer came from the one place on this phone that keeps a boot log without a UART:
MediaTek's **`expdb`** partition.

## Reading the bootloader's own log (no UART needed)

MediaTek's preloader and LK append their console output and reset records to the
`expdb` partition (`/dev/block/by-name/expdb`, `mmcblk0p3`, 20 MB on lagos). It survives
reboots and holds the last ~9 boots. With the phone booted into TrebleDroid (root via
KernelSU):

```bash
# NOTE: `dd ... of=/sdcard/expdb.bin` returned 0 bytes for this partition; stream it instead.
adb exec-out 'su -c "dd if=/dev/block/by-name/expdb bs=1M 2>/dev/null"' > expdb.bin
strings -n 24 expdb.bin | grep -nE 'kernel_sz|gzip|decompress|rst from|WDT_PRE|boot_reason'
```

## What the log says about our boots

The records from the Fuchsia attempts contain, in order:

```
[3533] [avb] img_auth_required = 0
[3533] boot state: orange
[3533] [PROFILE] ::: lvl(1) load boot image takes 1810 ms      ← boot.img loaded fine
...
[3772] kernel real kernel_sz=0x01c03e38                         ← 29 375 032 B = OUR image, not the 14 MB stock
[3772] gzip header is not correct. Error!                       ← LK tries to GUNZIP the kernel and fails
[3772] [PROFILE] ::: lvl(1) decompress_kernel takes 0 ms
[3772] Wait for iothread... Met bootstrap2.                     ← LK carries on regardless
      ... loads spmfw / scp / modem ...                         ← then jumps to an invalid kernel buffer
```

…and the *next* boot's preloader records why the previous one died:

```
<40> [RGU] rst from: lk               ← the stage marker was still "lk": no kernel ever ran
<41> [RGU] MODE: 0x1A5                ← TOPRGU enabled (EN=1) when it fired
<42> [RGU] LENGTH: 0xFFE0
<61> #T#WDT_PRE=21                    ← 21 s preset = exactly our loop period
<112>  bit10=1: AP WDT
<115> [pmic_check_rst] AP Watchdog    ← PMIC: last reset was the AP watchdog
kedump: boot_reason(4)                ← 4 = watchdog
kedump: invalid header[0x0000]        ← no kernel left a dump header
```

## The explanation, end to end

1. **LK decompresses the kernel unconditionally.** The stock `boot.img` kernel is an
   `Image.gz` — its first bytes are `1f 8b`. Every `boot.img` we built carried a **raw**
   arm64 `Image` (`4d 5a …`, the `MZ`/`ARM\x64` header).
2. LK's gunzip fails (`gzip header is not correct`), writes nothing useful into the
   kernel buffer at `0x40080000`, logs the error — and **continues the boot sequence
   anyway**, finally jumping to that buffer.
3. The CPU runs garbage/zeros, hangs. Nothing services the TOPRGU watchdog LK armed with a
   **21 s** preset (`#T#WDT_PRE=21`).
4. The watchdog resets the SoC; the preloader records *AP Watchdog*, stage *lk*; the loop
   repeats every ~20 s.

So **our code never executed, in any attempt** — which is exactly why embedding the ZBI
(attempt 2), adding the watchdog ZBI item (3), disabling the WDT first-thing (4) and the
deliberate hang (5) all produced the same bootloop: nothing after the jump ever ran.

### Things this definitively clears

| earlier hypothesis | verdict |
|---|---|
| GKI ramdisk concatenation corrupts the ZBI | never reached; irrelevant to the loop (the embedded ZBI is still the right design) |
| AVB rejects the unsigned boot.img | **no** — `[avb] img_auth_required = 0`, `boot state: orange`; the `vbmeta_a HASH_MISMATCH` line also appears in working TrebleDroid boots |
| LK doesn't recognize the kernel header | no — it loaded the boot image fine (1810 ms) and read our kernel size |
| the ~20 s reset is some other timer | **no** — it is the TOPRGU, 21 s preset, confirmed by preloader + PMIC |

> Gotcha: `[FAC] read: id=29 … Linux version 6.6.66-android15…` appears in **every**
> record. It's a factory-info string read from a partition, **not** evidence that a Linux
> kernel ran. Don't use it as a "kernel booted" heuristic (we briefly did).

## The fix: ship the kernel gzipped

`tools/build-boot-img.sh` now does, after packing shim+ZBI with `linuxboot-embed`:

```bash
gzip -9 -n -c lagos-shim-embedded.bin > lagos-shim-embedded.bin.gz
mkbootimg --header_version 4 --kernel lagos-shim-embedded.bin.gz --out lagos-fuchsia-boot.img
```

LK gunzips it into `kernel_addr_mb` (`0x40080000`, 124 MB buffer — plenty for 29 MB) and
jumps to the decompressed `Image`. The embedded ZBI is simply part of the decompressed
bytes, so it stays contiguous after the shim exactly as `linuxboot-embed` laid it out.

The attempt-5 diagnostic hang was removed from the shim; the early first-instruction
TOPRGU disable (attempt 4) stays — it's harmless and protects the shim/physboot window.

## What to expect from attempt 6 (gzipped real shim)

| observed | meaning |
|---|---|
| still loops at ~21 s | our code *still* isn't running → the gzip theory is incomplete (check LK's log again) |
| **fast** loop (a few seconds) | our code ran and the shim `abort()`ed → PSCI reset (now the shim is in play: bisect with the expdb/UART) |
| black and **never reboots** | our code ran, the TOPRGU disable took, and Zircon is up *or* the shim hung — the long-awaited foothold; UART tells which |
