# 05 — Next steps / roadmap

Ordered plan from "recon done" to "serial console". Each step lists the concrete action
and what "done" looks like.

## A. Environment (no device risk)

1. **Get the GPL kernel source for `lagos`** from Motorola's opensource release portal.
   - *Done when:* we have the `lagos` `.dts`/`dtsi` and MT6768 drivers for cross-reference
     (clocks, pinctrl, UART register details the stock blob omits).
2. **Clone the Fuchsia tree** (`jiri`/`fx`; tens of GB) and build + run **femu** first.
   - *Done when:* `ffx emu start` shows Fuchsia running in the emulator — validates the
     toolchain and workflow before touching board code.
3. **Mine Fuchsia git history** for the MT8167S board + `mt8167` UART driver.
   - *Done when:* we have the old `kernel/dev/uart/mt8167/uart.cpp` and
     `board/drivers/mt8167s_ref` sources checked out for reference.

## B. Hito 0 — serial console

4. **Physical UART access.** Find `lagos` debug UART test points (or Type-C analog route).
   - *Done when:* we can read the stock kernel's boot log over a USB-serial adapter — this
     also proves the console baud/pinout before we trust Fuchsia's output.
5. **Write the board config** `bringup.lagos` (GN) + kernel-driver config:
   - GICv3 `0x0c000000`/`0x0c040000`, arm timer 13 MHz, PSCI, UART `0x11002000`.
   - *Done when:* `fx set bringup.lagos && fx build` produces a ZBI.
6. **Port the MediaTek UART kernel driver** (`mt6577-uart` @ `0x11002000`) into the current
   kernel, from the 2018 MT8167S driver.
   - *Done when:* it compiles against today's Zircon `dev/uart` interface.
7. **Wrap the ZBI with the ARM `devicetree-boot-shim`** (feed it a minimal DTB: CPUs, GIC,
   timer, UART, memory, PSCI — a trimmed version of the stock tree).
   - *Done when:* we have a shim+ZBI image sized under 128 MB.
8. **Flash and boot on slot B:**
   ```bash
   fastboot flash boot_b fuchsia-shim.zbi
   fastboot set_active b
   fastboot reboot
   # watch UART; recover with: fastboot set_active a
   ```
   - *Done when:* **Zircon prints to the serial console** — Hito 0 achieved.

## C. Iterate

9. Debug early-boot hangs via UART (the classic bring-up loop: no output → wrong UART
   base/clock; hang after GIC → interrupt config; etc.).
10. Bring up SMP (PSCI CPU_ON), then the `core` product if a usable console shell works.

## Later (Hito 1+, out of immediate scope)

- Display: MediaTek DSI controller + panel driver.
- GPU: adapt the VIM3 Mali-G52 `magma` backend.
- Touch: I2C controller + touch panel.

## Parking lot / open questions

- `boot_b` partition size vs ZBI size (`getvar partition-size:boot_b`).
- Does `secure: yes` (vbmeta/AVB) reject an unsigned image on `boot_b`? May need
  `vbmeta` with verification disabled on slot B (we already have noverity vbmeta images
  in `moto-g06-mod/images/`).
- Whether MediaTek's `gz.img` hypervisor interferes with Zircon taking EL2.
