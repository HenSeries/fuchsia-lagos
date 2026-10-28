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

## What you can / can't see without UART

- **Can see:** whether slot B bootloops, hangs on the Motorola logo, or the bootloader
  falls back to slot A after failed attempts (A/B retry counter). That alone distinguishes
  "shim rejected / didn't start" from "booted far enough to sit quietly".
- **Can't see:** Zircon's actual boot log, the "hello" from physboot, driver bind results.
  That needs the serial console.

## Physical UART on the G06 — to investigate

MediaTek debug UART is usually exposed on test points on the board, sometimes multiplexed
onto the USB-C sideband (CC/SBU) lines via a special cable/resistor combo. Finding lagos's
specific route is the remaining hardware task. Until then, the flash is a behavior-only
experiment.
