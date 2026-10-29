# 20 — Storage bring-up: MediaTek MSDC eMMC controller (MSDC0)

With the devicetree board driver (`lagos-devicetree`, [docs/19](19-lagos-devicetree-board.md))
and the USB remote shell (`mt-musb` + `lagos-sh`, [docs/17](17-usb-peripheral.md),
[docs/18](18-remote-shell.md)) confirmed working on hardware, we tackle **persistent storage**.

The Moto G06 (`lagos`, MT6768) uses an internal **eMMC 5.1** chip connected to the
MediaTek MSDC0 host controller. Bringing up storage allows Fuchsia to read partition
tables (GPT), access partitions (including `userdata` and `system`), and eventually move
beyond the standalone minimal ramdisk/ZBI build.

---

## 1. Hardware Architecture & Map

Extracted from stock firmware devicetree (`device-tree/dts/vendor_boot-fdt0.dts:4069`):

| Property | Value | Description |
|---|---|---|
| **Compatible** | `mediatek,mt6768-mmc` | MT6768 MSDC controller |
| **MMIO 0 (core)** | `0x11230000` (64 KB) | MSDC0 controller registers (`MSDC_CFG`, `SDC_CMD`, FIFOs) |
| **MMIO 1 (top)** | `0x11cd0000` (4 KB) | `msdc0_top` pad / delay tuning registers |
| **Interrupt** | SPI 100 (`<0 0x64 4>`) | GICv3 interrupt 132 (100 + 32 SPI offset), level-high |
| **Bus width** | 8-bit (`bus-width = <8>`) | Standard eMMC bus width |
| **Max frequency** | 200 MHz (`0xbebc200`) | Source clock |
| **Card type** | eMMC (`non-removable`) | Internal flash storage |

### Bootloader State Advantage
Because Motorola's LittleKernel (LK) loads the boot image directly from eMMC partition
`boot_b`, **clocks, power, and pinmux for MSDC0 are already configured and active** at
kernel handoff. This enables early bring-up without having to implement MediaTek's full
clock tree and pinctrl frameworks from scratch.

---

## 2. Fuchsia Storage Architecture

Fuchsia decomposes SD/MMC storage into two distinct layers:

1. **Host Controller Driver (`mtk-sdmmc`):**
   - Binds to the platform device (`mediatek,mt6768-mmc`).
   - Handles low-level hardware register I/O, clock dividers, command/argument dispatch, and FIFO buffer reads/writes.
   - Implements and serves the driver-transport protocol `fuchsia.hardware.sdmmc.Sdmmc` (`fuchsia.hardware.sdmmc.SdmmcService`).
   - Publishes a child node offering `SdmmcService`.

2. **Core SD/MMC Protocol Driver (`sdmmc`):**
   - Binds to any child node providing `fuchsia.Service == "fuchsia.hardware.sdmmc.SdmmcService"`.
   - Executes standard JEDEC eMMC card initialization:
     - `CMD0` (GO_IDLE_STATE)
     - `CMD1` (SEND_OP_COND)
     - `CMD2` (ALL_SEND_CID)
     - `CMD3` (SET_RELATIVE_ADDR)
     - `CMD9` (SEND_CSD)
     - `CMD7` (SELECT_CARD)
     - `CMD8` (SEND_EXT_CSD)
   - Exposes block devices (`fuchsia.hardware.block`) for user partitions, boot partitions, and RPMB.
   - Core Fuchsia services (`fshost`, `gpt`, `block-watcher`) automatically detect GPT partitions on these block devices.

---

## 3. Implementation: PIO-First Strategy

Following the proven bring-up pattern from `mt-musb` (which started PIO-only to eliminate
DMA/BTI/MMU complexity), `mtk-sdmmc` implements Programmed I/O:

* **Commands:**
  * Poll `SDC_STS` (bit 1, `CMDBUSY`) to ensure the command engine is ready.
  * Write `SDC_BLK_NUM` (block count).
  * Write `SDC_ARG` (command argument).
  * Write `SDC_CMD` (command index, response type, block length, direction bit).
  * Poll `MSDC_INT` for `CMDRDY` (command ready), `CMDTMO` (timeout), or `RSPCRCERR`.
  * Read response registers:
    * 48-bit (R1, R1b, R3, R6, R7): `SDC_RESP0`
    * 136-bit (R2): `SDC_RESP3..0` (big-endian order from MediaTek hardware)

* **Data Transfers (FIFO):**
  * RX Data FIFO register: `MSDC_RXDATA` @ offset `0x1c`.
  * TX Data FIFO register: `MSDC_TXDATA` @ offset `0x18`.
  * FIFO status: `MSDC_FIFOCS` @ offset `0x14` (`RXCNT` bits 7:0, `CLR` bit 31).
  * Block data is transferred directly to/from client-registered VMO buffers mapped into the driver's address space.

---

## 4. Repository Changes (Attempt 32)

1. **Devicetree (`lagos-min.dts` & `lagos-min-v9.dtb`):**
   Added `mmc0: mmc@11230000` with registers, interrupts, and `compatible = "mediatek,mt6768-mmc"`.
   Compiled with `dtc` and bumped shim embed to `lagos-min-v9.dtb`.

2. **Driver (`src/devices/block/drivers/mtk-sdmmc`):**
   * `meta/mtk-sdmmc.dml`: Driver meta specification declaring `SdmmcService` capability and `pdev` composite requirement.
   * `meta/mtk-sdmmc.bind`: Binds primary parent on `fuchsia.COMPATIBLE == "mediatek,mt6768-mmc"`.
   * `meta/mtk-sdmmc.cml`: Driver component manifest.
   * `BUILD.gn`: GN driver package exporting to Bazel assembly.
   * `mtk-sdmmc.h` / `mtk-sdmmc.cc`: DFv2 driver implementing `fdf::WireServer<fuchsia_hardware_sdmmc::Sdmmc>`.

3. **Board Configuration:**
   * `boards/arm64/BUILD.gn`: Added `//src/devices/block/drivers/mtk-sdmmc:package` to `main_bundle` `bootfs`.
   * `build/drivers/all_drivers_list.txt`: Added `mtk-sdmmc-driver`.

4. **Reference Material:**
   * Saved `reference/uboot-mtk-sd.c` (U-Boot's MediaTek MSDC implementation) for hardware register reference.

---

## 5. Verification & Testing Workflow

To build and test:

```bash
# 1. Build the bringup image
cd ../fuchsia
fx build

# 2. Package the boot image
cd ../fuchsia-lagos
./tools/build-boot-img.sh

# 3. Flash to slot B and boot
./tools/flash-lagos-fuchsia.sh

# 4. Verify over USB remote shell (once booted)
./tools/lagos-sh "driver dump" | grep sdmmc
./tools/lagos-sh "ls /dev/class/block"
```

Expected driver topology:
```
  [lagos-devicetree]
       └── [mmc-11230000] (composite node spec)
             └── [mtk-sdmmc]
                   └── [mtk-sdmmc-sdmmc]
                         └── [sdmmc] (core Fuchsia eMMC driver)
                               ├── [user] (/dev/class/block/...)
                               ├── [boot0]
                               └── [boot1]
```
