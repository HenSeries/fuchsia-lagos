# 08 — Flashing a Fuchsia boot image on lagos (ready-to-flash + the open risks)

Everything needed to attempt booting Zircon on the Moto G06 is built. This is the flash
plan, the recovery path, and the honest list of what still needs on-device iteration.

> **Hard prerequisite to *verify* any of this: physical UART access** to the console at
> `0x11002000`. Without it we can flash and observe gross behavior (bootloop / hang /
> auto-reboot to slot A) but cannot read Zircon's output. See "What you can/can't see".

## The artifacts

| File | Role |
|---|---|
| `out/bringup.arm64-balanced/kernel.phys_arm64/linux-arm64-boot-shim.bin` | the "kernel" the bootloader loads (boots like a Linux arm64 Image) |
| `out/bringup.arm64-balanced/obj/products/bringup/product_bundle.arm64/product_bundle/system_a/fuchsia.zbi` | Zircon bringup image (the "ramdisk"/initrd) |
| `fuchsia-lagos/device-tree/lagos/lagos-min.dtb` | our clean device tree (fallback DTB path) |

Driver changes compiled in: `dw8250` now binds `mediatek,mt6577-uart` and accepts it even
without `reg-io-width`/`reg-shift` (defaults 4/2). See [07](07-lagos-board-plan.md).

## How the boot works

The shim is loaded as the Android kernel; the bootloader passes a **DTB in x0** and the
**ZBI as the initrd**. The shim parses the DTB (finds memory + the `0x11002000` UART),
sets up a polled console, and boots Zircon — early `physboot`/kernel prints come out the
UART before interrupts/SMP, so a serial console is the first sign of life.

## The two open risks (why the first flash is an experiment)

### 1. GKI split ramdisk / DTB source
Stock `boot.img` is v4 **kernel-only** (ramdisk=0); on this GKI A/B device the real ramdisk
is assembled from `init_boot` + `vendor_boot`, and the **DTB comes from `vendor_boot`**
(MediaTek base DTB + `dtbo` overlays), not from `boot.img`. So:
- The bootloader hands the shim the concatenated vendor ramdisks, **not** a clean single
  ZBI, unless we make `boot`'s ramdisk the ZBI *and* keep the others out of the way.
- The DTB in x0 is MediaTek's, not ours.

**Mitigations, in order of preference:**
1. **Rely on the stock MediaTek DTB** (it *does* have a `mediatek,mt6577-uart` node; our
   relaxed `dw8250` accepts it). Flash only `boot_b` with kernel=shim, ramdisk=ZBI. Simplest;
   try first.
2. If the concatenated ramdisk corrupts the ZBI: also flash a **minimal `vendor_boot_b`**
   (empty vendor ramdisk) so the initrd is just our ZBI.
3. If the MediaTek DTB won't parse: **embed our `lagos-min.dtb`** in the shim (requires a
   small patch to the arm64 phys shim main to use an embedded blob instead of x0) — the
   fully self-contained path, documented for when UART access confirms we need it.

### 2. UART baud/divisor
`dw8250.Init()` may reprogram the divisor; MediaTek's base clock differs, so output could be
garbled even when the driver binds. Fix is the divisor, not the driver — a tuning step once
we can read the line.

## Flash procedure (slot B, slot A stays as TrebleDroid safety net)

```bash
# 0. device in fastboot (bootloader), slot A = working TrebleDroid
fastboot getvar current-slot          # expect: a

# 1. back up the current boot_b first
fastboot fetch boot_b boot_b.backup.img   # or dump via your existing tooling

# 2. flash the Fuchsia image to slot B only
fastboot flash boot_b   lagos-fuchsia-boot.img
# (mitigation 2, only if needed:) fastboot flash vendor_boot_b vendor_boot_b.empty.img

# 3. boot slot B
fastboot set_active b
fastboot reboot

# 4. observe UART (and gross behavior). To recover to TrebleDroid:
fastboot set_active a
```

`set_active a` is the one-command undo. Full stock restore is always available from
`moto-g06-mod/tools/RETBR_...CFC.zip` and `moto-g06-mod/backup/`.

### Flashing while the device is bootlooping (no fastboot reachable)

`fastboot` only appears if LK stops at its menu, which a tight bootloop never gives you.
Use the MediaTek preloader instead — it shows up (`0e8d:2000`) on every cycle and
**antumbra latches it**, so you can write the *next* image straight over the loop without
restoring Android in between:

```bash
cd moto-g06-mod/tools/tanuki-lagos/bin
sudo ./antumbra -v --disable-exploits carbonara download \
    --da lagos.bin boot_a /path/to/lagos-fuchsia-boot.img --pl preloader_lagos.bin
```

> **`download` does NOT reboot the device.** It leaves it parked in preloader/DA mode:
> `0e8d:2000` stays on the bus with no cycling, no adb, no fastboot, and no antumbra
> process. That is *not* a hang — it's waiting. Boot the new image with:
>
> ```bash
> sudo ./antumbra reboot --da lagos.bin --pl preloader_lagos.bin normal
> ```
>
> (or a long power-press). A USB observer running across an antumbra session shows a
> single transition into PRELOADER that then persists — that's the latch, not a boot
> result. The boot result only exists after the reboot.

## What you can / can't see without UART

- **Can see:** whether slot B bootloops, hangs on the Motorola logo, or the bootloader
  falls back to slot A after failed attempts (A/B retry counter). That alone distinguishes
  "shim rejected / didn't start" from "booted far enough to sit quietly".
- **Can't see:** Zircon's actual boot log, the "hello" from physboot, driver bind results.
  That needs the serial console.

## Physical UART on the G06 — research findings (2026-10-28)

**Which UART to target — confirmed twice.** The stock DTB's `/chosen` has
`console=tty0 ... 8250.nr_uarts=2`: Motorola's production kernel logs to the **screen
(tty0), not a serial port**, but the two AP UARTs exist and the 8250 driver enumerates
them — `apuart0 @ 0x11002000` and `apuart1 @ 0x11003000`. On MediaTek, **UART0 is the AP
debug console**, so our DTB/`dw8250` targeting `0x11002000` is correct. Independent
confirmation: `mtkclient`'s preloader handshake on lagos reports
`Preloader - Uart: 0x11002000` — so the **MediaTek preloader itself drives UART0 at that
address from the earliest boot stage**, i.e. the UART is muxed and live before our shim
runs. A reachable TX pad there shows the preloader *and* Zircon. Our shim writes
there in polled mode regardless of Motorola's `tty0` choice, so **if that TX pin is wired
out, Zircon's boot log appears even though stock Android never used it.** (If nothing shows,
try `0x11003000` as a fallback.)

**Two ways to physically reach it:**

1. **On-board TX/RX/GND pads.** MediaTek boards route UART0 to small pads, usually near the
   SoC under the shield. Their exact location is only in the **service schematic / boardview**
   — the G06 `XT2535` boardview is sold by phone-repair file vendors (e.g. W2R Solutions,
   Chimera test-point library). Open the boardview in **OpenBoardView**, find the UART0
   TX/RX/GND pads, wire to a 3.3 V USB-TTL adapter (device TX→adapter RX, device RX→adapter
   TX, GND→GND; do **not** connect VCC). Baud: MediaTek default is 921600 (also try 115200).

2. **UART-over-USB (no disassembly, but uncertain on USB-C).** Many MediaTek phones switch
   the USB **data lines to a 921600-baud TTL UART** when the preloader detects a special
   "MediaTek debug cable" at boot (the switch is decided by resistance/voltage on the
   cable). On old micro-USB devices this is well documented (D+=TX, D-=RX, ID→resistor→GND,
   resistor value selects mode). On **USB-C it is hit-or-miss** — the UART may be on the SBU
   pins and only activate under MTK tools; community attempts with 300k/523k/619k CC-to-GND
   resistors have largely failed. Worth trying but not reliable.

> Note: the on-screen `console=tty0` and `printk.disable_uart` settings are Android-kernel
> choices and do **not** affect our shim, which drives `0x11002000` itself. What they can't
> change is the **preloader's pinmux** — if MediaTek's preloader (which runs before our shim)
> doesn't route UART0 to a reachable pad/pin on this board, there's nothing to tap. The
> schematic/boardview is the way to settle that.

**BROM test point (different thing):** the widely-shared G06 "test point" (KCOL0/KPCOL0 +
GND) forces MediaTek BROM/preloader mode for `mtkclient` flashing — it is **not** a UART
console. Useful for recovery, not for reading Zircon.

Until a UART tap is wired, the flash is a behavior-only experiment.
