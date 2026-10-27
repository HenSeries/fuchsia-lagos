# Research notes & sources

Key facts gathered from Fuchsia docs and the Fuchsia/Zircon source tree during recon.

## Supported hardware (official)

Fuchsia officially supports exactly two hardware targets plus the emulator:
- **Intel NUC** (x86-64, Broadwell+)
- **Khadas VIM3** (arm64)
- **femu/QEMU** emulator

No phone / MediaTek / arbitrary-ARM support. `arm64` is listed as an *architecture*, which
is not device support.
→ https://fuchsia.dev/fuchsia-src/development/hardware

## Bring-up requirements (official)

Minimal `bringup` product needs: supported arch; bootloader+kernel support (early serial,
interrupt controller, timers as kernel drivers); GN board config (`fx set bringup.<board>`);
a board driver (configures non-probeable HW); non-kernel drivers (gpio/clocks/power/...).
If the bootloader can't boot Fuchsia, a **boot shim** is prepended to the kernel so it
works via the bootloader's facilities (e.g. fastboot).
→ https://fuchsia.dev/docs/development/boards/bringup

## Boot shim / ZBI

- ZBI boot shim concatenated in front of the Zircon image; the no-op ZBI→ZBI shim treats
  its input as a complete bootable ZBI.
  → https://fuchsia.googlesource.com/fuchsia/+/HEAD/zircon/kernel/phys/boot-shim/zbi-boot-shim.cc
- A newer **`devicetree-boot-shim` for ARM** lets Zircon consume a device tree — lowers the
  bring-up barrier (we can feed it a trimmed stock DTB).
- Android **GBL (Generic Bootloader)** has code to load/verify/boot Zircon ZBIs (not needed
  for our fastboot-flash path).

## MediaTek precedent in Zircon

- 2018: initial **MT8167S** reference-board support added to Zircon, including a UART driver
  at `kernel/dev/uart/mt8167/uart.cpp` ("Zircon boots into serial console shell on MT8167S").
  The MT8167 UART is the same `mediatek,mt6577-uart` IP as our MT6768.
  → https://fuchsia.googlesource.com/fuchsia/+/291c26919aa033c472717699cc957b5c8c138bca%5E%21
- Board driver later lived at `src/devices/board/drivers/mt8167s_ref` before being removed.
- There was also WIP Zircon support for `msm8053` (a Qualcomm phone SoC) — evidence that
  phone-class bring-up has been attempted in the tree.
  → https://fuchsia.googlesource.com/zircon//+/a6d76cedc3d5586ceae5bbed648076e34076fa84

## Linux reference (hardware, not Fuchsia)

- Linux MediaTek 8250 UART driver (`8250_mtk.c`, 2014) binds `mediatek,mt6577-uart` — useful
  as a register-level reference for the Zircon driver port.
- MT6768 is well-covered by mainline Linux / postmarketOS device trees.

## Device facts (Moto G06 / lagos)

- SoC: MediaTek MT6768 ("Helio G81"), 2×Cortex-A75 + 6×Cortex-A55, Mali-G52 MC2.
- Mali-G52 = same family as Khadas VIM3 → reference for a future graphics driver.
  → https://m.gsmarena.com/motorola_moto_g06-14115.php
