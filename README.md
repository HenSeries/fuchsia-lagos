# fuchsia-lagos

**Porting Google Fuchsia (Zircon) to the Motorola Moto G06 (`lagos`, MediaTek MT6768).**

This is a from-scratch *board bring-up* effort, not a flash-a-prebuilt-image project.
Fuchsia has no support for arbitrary Android phones; getting it to run means writing
the board support ourselves, following the official bring-up documentation and the
community/history of the Fuchsia tree.

> ⚠️ This is a research/hobby project on a **secondary device**. Expect it to be slow,
> to hit hard walls (MediaTek secure world, no datasheets, proprietary radio), and to
> possibly never reach a usable UI. The realistic, worthwhile goal is a **serial console**.

---

## Status

| | |
|---|---|
| **Phase** | Hito 0 bring-up — **Fuchsia boots to `Bootup completed` on all 8 CPUs with working timer interrupts** ✅ (attempt 24; [docs/16](docs/16-userspace-reached.md)) |
| **Target SoC** | MediaTek **MT6768** (basis of "Helio G81") |
| **Device** | Motorola Moto G06 `lagos` (XT2535-1), bootloader unlocked, A/B slots |
| **Next milestone** | storage (eMMC/UFS) or display; the board is now a real devicetree board (`lagos-devicetree`, [docs/19](docs/19-lagos-devicetree-board.md)), so new drivers just need a DTB node |
| **Output channel** | **USB**: the phone enumerates as a CDC-Ethernet device (own MUSB driver, attempt 27) and the host streams logs with `loglistener` ([docs/17](docs/17-usb-peripheral.md)). Framebuffer text console as fallback ([docs/15](docs/15-framebuffer-console.md)) |

## The milestone ladder

| Hito | Goal | Realism |
|---|---|---|
| **0** | Zircon boots the `bringup` product → **serial console / shell over UART** | 🟡 Achievable (weeks). *The real "we did it".* |
| **1** | Display + touch → minimal graphical UI | 🟠 Very hard (months). Mali-G52 helps (see below). |
| **2** | Storage / USB / WiFi | 🔴 Unlikely |
| **3** | Modem / calls / radio | ⛔ Effectively never (proprietary baseband) |

## Why Hito 0 is feasible

Every kernel driver needed for a serial console either exists in the current Fuchsia
tree or has direct precedent in its git history:

| Block | Device value | Fuchsia support |
|---|---|---|
| Interrupt controller | `arm,gic-v3` @ `0x0c000000` | ✅ current tree |
| Timer | `arm,armv8-timer`, 13 MHz | ✅ standard |
| **UART console** | `mediatek,mt6577-uart` @ **`0x11002000`** | 🟡 existed in Zircon (MT8167S, *same IP*) — resurrect |
| Power / SMP | PSCI 1.0 `smc` | ✅ |
| CPUs | 2×Cortex-A75 + 6×Cortex-A55 | ✅ arm64 |

The MediaTek MT6768 also has solid mainline Linux / postmarketOS documentation to
cross-reference, and its **Mali-G52 MC2 GPU is the same family as the Khadas VIM3**
(the only officially supported ARM board for Fuchsia), which gives Hito 1 a starting point.

## Repository layout

```
docs/
  01-background.md        Fuchsia vs Android, the "runs Android apps" myth, scope
  02-hardware-map.md      Full SoC hardware map (addresses, IRQs, boot params)
  03-recon-log.md         Exactly how the device tree was extracted (reproducible)
  04-feasibility.md       Milestone ladder, blockers, risk, decisions
  05-next-steps.md        Concrete roadmap from here
  06-build-notes.md       Building Fuchsia on this host (Bazel OOM fix)
  07-lagos-board-plan.md  Board plan; MediaTek UART == dw8250
  08-flashing-lagos.md    Flash / recovery procedure, UART test-point research
  09..11                  Attempts 2-6; ROOT CAUSE: LK gunzips the kernel (expdb log)
  12-attempt7-framebuffer-printf.md  Colour paints as a UART-free printf (attempts 7-9)
  13-attempt10-blue-shim-works.md    DTB-overlap bug; shim runs; embed:zbi needs a cpio; GRAY
  14-zircon-kernel-runs.md           Zircon kernel runs; kernel progress bands + heartbeat
patches/                  Local patches to the Fuchsia checkout (git apply)
device-tree/
  dts/vendor_boot-fdt0.dts   Decompiled device tree (6277 lines) — the main artifact
  raw/vendor_boot-fdt0.dtb   Carved FDT blob
  vendor_boot-header.txt     vendor_boot.img header (load addresses etc.)
tools/
  extract-device-tree.sh     Regenerate the device tree from stock firmware
research/                     Notes / links from Fuchsia docs & source
```

Large firmware images are **not** committed (see `.gitignore`); regenerate them from the
Motorola stock firmware zip with `tools/extract-device-tree.sh`.

## Quick start (reproduce the recon)

```bash
./tools/extract-device-tree.sh /path/to/RETBR_..._lagos_..._CFC.zip
# -> device-tree/dts/vendor_boot-fdt0.dts
```

## Sources

- [Fuchsia — Install on a device (supported hardware)](https://fuchsia.dev/fuchsia-src/development/hardware)
- [Fuchsia — Adding support for new boards (bring-up)](https://fuchsia.dev/docs/development/boards/bringup)
- [Zircon ZBI boot shim](https://fuchsia.googlesource.com/fuchsia/+/HEAD/zircon/kernel/phys/boot-shim/zbi-boot-shim.cc)
- [Zircon — initial MT8167S board support (2018, MediaTek UART driver)](https://fuchsia.googlesource.com/fuchsia/+/291c26919aa033c472717699cc957b5c8c138bca%5E%21)
