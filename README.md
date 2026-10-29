# fuchsia-lagos

**Porting Google Fuchsia (Zircon) to the Motorola Moto G06 (`lagos`, MediaTek MT6768).**

This is a from-scratch *board bring-up* effort, not a generic GSI or prebuilt image.
Fuchsia has no official support for arbitrary Android smartphones; getting it to boot
requires authoring board support, kernel boot shims, and device drivers directly in
the Fuchsia source tree.

> ⚠️ This is a research project on a **secondary device**. It tackles real SoC walls:
> MediaTek secure world (ATF/GenieZone/LK quirks), undocumented registers, and lack of UART.
> The primary goals are reliable diagnostics, interactive userspace control, and peripheral bring-up.

---

## Current Status Dashboard

| Item | Status | Details |
|---|---|---|
| **Phase** | **Hito 0: COMPLETE** ✅<br>**Hito 2: IN PROGRESS** 🟡 | Full userspace reached, `Bootup completed` at 3.2 s, all 8 CPUs online, timer ticks firing, interactive shell running over USB CDC-Ethernet. |
| **Target SoC** | MediaTek **MT6768** ("Helio G81") | 2× Cortex-A75 + 6× Cortex-A55 (DynamIQ), Mali-G52 MC2, GICv3, MT6577 UART. |
| **Device** | Motorola Moto G06 `lagos` (XT2535-1) | Unlocked bootloader, A/B slots (`boot_a` = recovery/TrebleDroid, `boot_b` = Fuchsia). |
| **Board Driver** | `lagos-devicetree` ([docs/19](docs/19-lagos-devicetree-board.md)) | Native DFv2 board driver walks `lagos-min.dtb` with `ArmGicVisitor` and publishes composite devices. QEMU drivers completely eliminated. |
| **I/O & Remote Shell** | **USB CDC-Ethernet** ([docs/17](docs/17-usb-peripheral.md), [docs/18](docs/18-remote-shell.md)) | Custom `mt-musb` driver (PIO). Phone enumerates as `18d1:a020 Google CDC Ethernet`. Host tool [`tools/lagos-sh`](tools/lagos-sh) provides interactive remote shell. USB logs stream via `loglistener`. |
| **Screen Fallback** | Framebuffer Console ([docs/15](docs/15-framebuffer-console.md)) | 8×16 bitmap text console painted directly into LK's bootloader framebuffer (`0x781b0000`). |
| **Current Milestone** | **eMMC 5.1 Storage** ([docs/20](docs/20-storage-msdc-bringup.md)) | DTB v9 node `mmc0@11230000` added; pure DFv2 `mtk-sdmmc` driver scaffolded to serve `fuchsia.hardware.sdmmc.SdmmcService`. |

---

## The Milestone Ladder

| Hito | Goal | Status | Notes |
|---|---|---|---|
| **0** | Zircon boots `bringup` → **interactive shell & serial/USB logs** | **ACHIEVED** ✅ | Bootup completed at 3.2s; all 8 CPUs online; remote shell (`tools/lagos-sh ps`) working over USB. |
| **1** | Display + touch → minimal graphical UI | 🟠 In progress | Text console on screen works; native display controller / DRM stack next. |
| **2** | Storage / USB / Peripherals | 🟡 In progress | USB CDC-Ethernet verified; eMMC 5.1 MSDC0 driver scaffolded (Attempt 32). |
| **3** | Modem / calls / radio | ⛔ Not planned | Proprietary cellular baseband stack. |

---

## What We Have Built

Across 32 iterations, we designed and built the complete bring-up stack:

```
                  ┌──────────────────────────────────────────────┐
                  │          Host PC (Linux / Arch)              │
                  │   fx build  │  tools/build-boot-img.sh       │
                  │   tools/flash-lagos-fuchsia.sh               │
                  │   tools/lagos-sh ("ps", "ls", logs)          │
                  └──────────────────────┬───────────────────────┘
                                         │ USB High-Speed (CDC-Ethernet)
  ┌──────────────────────────────────────┴──────────────────────────────────────┐
  │ Motorola Moto G06 (`lagos`, MT6768)                                        │
  │                                                                            │
  │  [LK Bootloader] ──> Unzips Image.gz ──> [linux-arm64-boot-shim]           │
  │                                                │ Embedded lagos-min.dtb    │
  │                                                │ Embedded cpio ZBI         │
  │                                                ▼                           │
  │  [Zircon Kernel]                                                           │
  │   ├── All 8 CPUs Online (gLagosSecondaryContext fallback table)            │
  │   ├── Timer Interrupts Active (EOImode=1 fix in early GICv3)               │
  │   ├── Framebuffer Console (8x16 font painted directly to screen)           │
  │   │                                                                        │
  │  [Fuchsia Userspace] (component_manager, driver_manager)                   │
  │   ├── [lagos-devicetree] (DFv2 Board Driver, walks DTB v9)                 │
  │   ├── [mt-musb] (USB DCI controller -> CDC-Ethernet -> netsvc remote sh)   │
  │   └── [mtk-sdmmc] (MSDC0 eMMC controller -> SdmmcService -> core sdmmc)    │
  └────────────────────────────────────────────────────────────────────────────┘
```

1. **Embedded Linux Boot Shim (`linux-arm64-boot-shim`):**
   * Prepend shim to Zircon so Motorola's stock LK bootloader can load it via fastboot.
   * Disables the MediaTek TOPRGU hardware watchdog before it can trip.
   * Embeds a clean, minimal devicetree (`lagos-min-v9.dtb`) and a CPIO archive wrapping `fuchsia.zbi`.
   * Gzipped as `Image.gz` to satisfy LK's mandatory decompression header check.

2. **SMP & Interrupt Engine:**
   * Boots all 8 cores (2× A75 big cores + 6× A55 LITTLE cores) in under 75 ms.
   * Custom fallback table (`gLagosSecondaryContext`) keyed by MPIDR Aff1 to bypass MTK ATF's refusal to pass `context_id`.
   * Hardware timer enabled on all cores by overriding LK's inherited GIC `EOImode=1`.

3. **In-Kernel Framebuffer Text Console (`zircon/kernel/platform/debug.cc`):**
   * Complete 8×16 bitmap text console drawing directly into LK's leftover framebuffer (`0x781b0000`).
   * Color-coded progress bands and live heartbeat counter for visual diagnostics without physical UART.

4. **USB High-Speed Device Mode (`src/devices/usb/drivers/mt-musb`):**
   * Written from scratch as a pure DFv2 Programmed I/O (PIO) controller driver for MediaTek MUSB (`0x11200000`).
   * Binds to `usb-peripheral` to publish a CDC-Ethernet interface (`18d1:a020 Google CDC Ethernet`).
   * Remote log streaming (`loglistener`) and host CLI tool [`tools/lagos-sh`](tools/lagos-sh).

5. **Devicetree Board Driver (`src/devices/board/drivers/lagos-devicetree`):**
   * Replaced QEMU emulator board driver with a native devicetree board driver.
   * Walks the embedded DTB using `ArmGicVisitor` and publishes composite devices directly into DFv2.
   * Identifies board as `board: "lagos"`, MediaTek MT6768 (`fuchsia.mediatek.platform` VID 7 / PID 1).

6. **MediaTek Storage Controller (`src/devices/block/drivers/mtk-sdmmc`):**
   * Pure DFv2 driver for the internal eMMC 5.1 MSDC0 controller (`0x11230000`, SPI 100).
   * Programmed I/O command and FIFO buffer transfer engine.
   * Publishes `fuchsia.hardware.sdmmc.SdmmcService` so Fuchsia's core `sdmmc` driver discovers GPT partition tables.

---

## Walls Hit & Root Causes Solved (War Stories)

Porting Fuchsia to a modern MediaTek smartphone without schematics or hardware serial required solving several non-obvious failure modes:

### 1. The LK Gunzip Trap (Attempts 1–6)
* **Symptom:** Flashed Zircon images caused immediate reboot loops; screen stayed completely blank; TOPRGU watchdog triggered after 21 seconds.
* **Root Cause:** Analysis of the phone's `expdb` partition log revealed that Motorola/MediaTek LK unconditionally executes `gunzip` on the boot image:
  ```
  gzip header is not correct. Error!
  ```
  When passed an uncompressed kernel, LK quietly jumped into an empty memory buffer.
* **Fix:** Compress the packed shim+ZBI with `gzip -9` so it presents valid gzip magic (`1f 8b`) to LK ([docs/11](docs/11-root-cause-lk-gunzip.md)).

### 2. The Devicetree Shim CPIO Requirement (Attempt 12)
* **Symptom:** ZBI boot shim hung or painted red screen upon boot; ZBI could not be located.
* **Root Cause:** In `devicetree-boot-shim`, `set_zbi_boot("embed:zbi")` does *not* accept a raw embedded ZBI file. It searches for a CPIO archive containing an entry named `"zbi"`.
* **Fix:** Added a Python packaging step in [`tools/build-boot-img.sh`](tools/build-boot-img.sh) that wraps `fuchsia.zbi` in a standard Linux `newc` cpio archive before embedding ([docs/13](docs/13-attempt10-blue-shim-works.md)).

### 3. MTK ATF Dropping PSCI `context_id` (Attempt 21)
* **Symptom:** Primary core booted, but secondary CPUs hung during PSCI wakeup; userspace stalled.
* **Root Cause:** MediaTek's proprietary Arm Trusted Firmware (ATF) BL31 implementation ignores or zeroes register `x0` (`context_id`) when waking secondary cores via `PSCI_CPU_ON`. Zircon expected `x0` to contain the pointer to the core's per-cpu context.
* **Fix:** Implemented a CPU lookup table `gLagosSecondaryContext[8]` in Zircon kernel platform code that looks up per-cpu context by hardware `MPIDR_EL1` affinity instead of relying on ATF's `x0` ([docs/16](docs/16-userspace-reached.md)).

### 4. DynamIQ MPIDR Affinity Layout (Attempt 17)
* **Symptom:** PSCI calls returned errors for cores 4–7.
* **Root Cause:** Unlike older ARM clusters (where Aff0 = core index), MT6768 DynamIQ assigns `Aff1` as the core index and `Aff0 = 0`:
  `0x000, 0x100, 0x200, 0x300, 0x400, 0x500` (A55) and `0x600, 0x700` (A75). Early attempts targeted non-existent Aff0 IDs.
* **Fix:** Corrected CPU registers in [`device-tree/lagos/lagos-min.dts`](device-tree/lagos/lagos-min.dts).

### 5. The Inherited LK `EOImode=1` Interrupt Trap (Attempt 23–24)
* **Symptom:** Userspace launched, but the timer interrupt (PPI 27) never fired more than once. The system froze after 15 seconds waiting for time to advance.
* **Root Cause:** MediaTek LK boots with GICv3 CPU interface register `ICC_CTLR_EL1 = 0x8402` (`EOImode = 1`), which separates interrupt priority drop from interrupt deactivation. Zircon standard code assumes `EOImode = 0` (where writing `EOIR` drops priority *and* deactivates). Because Zircon never wrote `DIR`, the first timer tick stayed active in `ISACTIVER0` forever, blocking all subsequent ticks.
* **Fix:** Added `regs::clear_eoimode()` in Zircon's early per-CPU GIC initialization, plus cleared active interrupts on boot ([docs/16](docs/16-userspace-reached.md)). Timer started ticking immediately.

### 6. Devicetree Composite Spec Binding (Attempt 30–31)
* **Symptom:** The new devicetree board driver started, but the USB driver never matched or loaded.
* **Root Cause:** Fuchsia's devicetree library (`fdf_devicetree`) publishes every node as a *composite node spec* with a primary parent `"pdev"`. Standard, non-composite bind rules will never match nodes published this way.
* **Fix:** Converted `mt-musb` (and `mtk-sdmmc`) into composite drivers matching `compatible` under primary parent `"pdev"` ([docs/19](docs/19-lagos-devicetree-board.md)).

### 7. Host Bazel Concurrency OOM & `.incbin` Cache
* **Symptom:** Host build failed with `OOM killed (exit 137)`; changes to devicetree DTS were ignored by the build.
* **Root Cause:** 22 GB RAM host with no swap was overwhelmed by Bazel's default worker concurrency; Ninja/Bazel compile caches did not recognize updates inside assembly `.incbin` directives.
* **Fix:** Tuned `build/bazel/templates/template.bazelrc` with `build --jobs=4 --noreuse_sandbox_directories`, and established the rule to bump DTB file names per revision (`v8` -> `v9`) ([docs/06](docs/06-build-notes.md)).

---

## Hardware Reference Map (MT6768 / `lagos`)

| Subsystem | Base Address | Size | IRQ | Driver / Status |
|---|---|---|---|---|
| **GICD (Distributor)** | `0x0c000000` | 256 KB | — | `arm,gic-v3` ✅ |
| **GICR (Redistributors)** | `0x0c040000` | 2 MB | — | 8 cores mapped ✅ |
| **Timer** | Architecture PPI | — | PPI 13,14,11,10 | 13 MHz standard ✅ |
| **UART0 Console** | `0x11002000` | 4 KB | SPI 112 | `dw8250` / `mt6577-uart` (polling) ✅ |
| **MUSB USB Controller** | `0x11200000` | 64 KB | SPI 97 | `mt-musb` (DFv2 PIO, CDC-Eth) ✅ |
| **U2 USB PHY** | `0x11cc0000` | 4 KB | — | Port 0 tuned in `mt-musb` ✅ |
| **MSDC0 (eMMC 5.1)** | `0x11230000` | 64 KB | SPI 100 | `mtk-sdmmc` (DFv2 PIO, Attempt 32) 🟡 |
| **MSDC0 TOP (Pad tune)** | `0x11cd0000` | 4 KB | — | Mapped in `mtk-sdmmc` 🟡 |
| **Framebuffer** | `0x781b0000` | 16.3 MB | — | Kernel 8×16 text console ✅ |
| **TOPRGU Watchdog** | `0x10007000` | 4 KB | — | Disabled in boot shim ✅ |

---

## Quickstart: Build, Flash & Remote Shell

### Prerequisites
* Bootloader unlocked on slot B (`fastboot getvar unlocked` -> `yes`).
* Fuchsia build configured for balanced bringup:
  ```bash
  cd ../fuchsia
  fx set bringup.arm64 --with-base //bundles/assembly:bootstrap
  ```

### 1. Build Fuchsia
```bash
cd ../fuchsia
fx build
```

### 2. Package & Flash Boot Image
```bash
cd ../fuchsia-lagos

# Package kernel, embedded DTB, and cpio ZBI
./tools/build-boot-img.sh

# Flash to Slot B (slot A is preserved for recovery)
./tools/flash-lagos-fuchsia.sh
```

### 3. Connect via USB Remote Shell
Once the phone boots, it connects over USB as CDC-Ethernet:

```bash
# Check running processes
./tools/lagos-sh "ps"

# Inspect active driver tree
./tools/lagos-sh "driver dump"

# Stream live kernel and driver logs
./tools/lagos-sh --log
```

---

## Post-Quickstart: Workflow & Development Indications

Once you have verified the basic build, flash, and remote shell flow, follow these procedures to inspect the system, develop new drivers, diagnose crashes, and keep the source repositories synchronized.

### 1. System Inspection & Health Verification

Use [`tools/lagos-sh`](tools/lagos-sh) to interact with the running Fuchsia instance over USB:

```bash
# Verify process tree and running tasks (component_manager, driver_manager, netsvc)
./tools/lagos-sh "ps"

# Monitor real-time memory and CPU utilization
./tools/lagos-sh "top -n 1"

# Inspect published device nodes in /dev/class
./tools/lagos-sh "ls /dev/class"

# Inspect driver topology and composite node matching
./tools/lagos-sh "driver dump"

# Stream live system logs (Zircon kernel + userspace syslog)
./tools/lagos-sh --log
```

---

### 2. The Driver Development Lifecycle (Adding New Peripherals)

Every peripheral driver (such as `mt-musb` or `mtk-sdmmc`) follows this 4-step integration process:

#### Step A: Devicetree Definition
1. Inspect the stock decompiled devicetree [`device-tree/dts/vendor_boot-fdt0.dts`](device-tree/dts/vendor_boot-fdt0.dts) to find the peripheral's base MMIO addresses, register window sizes, and GIC interrupts.
2. Add the peripheral node to [`device-tree/lagos/lagos-min.dts`](device-tree/lagos/lagos-min.dts) (e.g. `usb@11200000`, `mmc0@11230000`).
3. Compile the DTS into a binary DTB:
   ```bash
   dtc -I dts -O dtb -o device-tree/lagos/lagos-min.dtb device-tree/lagos/lagos-min.dts
   ```
4. **Important (Cache Invalidation):** Because Ninja/Bazel do not detect changes inside assembly `.incbin` statements, bump the revision suffix whenever updating the DTB:
   ```bash
   # Example: copy to next revision
   cp device-tree/lagos/lagos-min.dtb ../fuchsia/zircon/kernel/arch/arm64/phys/boot-shim/lagos-min-v10.dtb
   ```
   Then update line 68 in `../fuchsia/zircon/kernel/arch/arm64/phys/boot-shim/linux-arm64-boot-shim.cc` to match the new file name.

#### Step B: Authoring the DFv2 Driver
Under `../fuchsia/src/devices/<subsystem>/drivers/<driver_name>/`:
1. **DML specification (`meta/<driver>.dml`):**
   Fuchsia's devicetree manager publishes every DTB node as a composite node spec. Declare the driver as a composite driver requiring a primary `"pdev"` parent with `compat: "<vendor>,<compatible-string>"`.
2. **Component Manifest (`meta/<driver>.cml`) & Bind Rules (`meta/<driver>.bind`):**
   Define component runner, binary path, and exposed driver services (e.g., `fuchsia.hardware.sdmmc.SdmmcService`).
3. **Driver Package (`BUILD.gn`):**
   Configure `fuchsia_driver_dml`, `driver_bind_rules`, and `fuchsia_cc_driver`.
4. **C++ Implementation (`<driver>.h` / `<driver>.cc`):**
   Extend `fdf::DriverBase2` and the subsystem protocol server (e.g. `fdf::WireServer<fuchsia_hardware_sdmmc::Sdmmc>`). Connect to `pdev`, map MMIOs via `client.MapMmio()`, and serve the FIDL service on a child node.

#### Step C: Board Bundle Registration
Register the driver so it is packaged into the bootfs image:
1. In `../fuchsia/boards/arm64/BUILD.gn`, add the driver package target to `main_bundle.drivers`:
   ```gn
   {
     package_target = "//src/devices/<subsystem>/drivers/<driver_name>:package"
     package_set = "bootfs"
     driver_components = [ "meta/<driver_name>.cm" ]
   },
   ```
2. In `../fuchsia/build/drivers/all_drivers_list.txt`, add the driver target:
   ```
   //src/devices/<subsystem>/drivers/<driver_name>:<driver_name>-driver
   ```

#### Step D: Build, Deploy & Verify
```bash
# 1. Rebuild Fuchsia
cd ../fuchsia && fx build

# 2. Package boot image and flash slot B
cd ../fuchsia-lagos
./tools/build-boot-img.sh
./tools/flash-lagos-fuchsia.sh

# 3. Verify driver binding in remote shell
./tools/lagos-sh "driver dump" | grep <driver_name>
```

---

### 3. Triage & Crash Recovery (When Boot Fails)

If a change causes the kernel to panic or hang:

1. **Immediate Safe Recovery:**
   Bootloader slot A is kept pristine with TrebleDroid / Android. Switch back immediately via fastboot:
   ```bash
   fastboot set_active a && fastboot reboot
   ```
2. **Extracting Panic Dumps (`dump-expdb.sh`):**
   MediaTek's bootloader stores the panic records, registers, and kernel handling logs of recent boots in the `expdb` partition. Once booted into Android (with root):
   ```bash
   ./tools/dump-expdb.sh
   ```
   This will parse the crash logs, revealing whether the bootloader panicked, if LittleKernel failed decompression, or if the hardware watchdog fired.

---

### 4. Repository Synchronization & Versioning

The project is maintained across two interconnected git repositories:

* **`fuchsia-lagos` (`/home/hen/Documentos/code/android/fuchsia-lagos`):**
  Houses the device trees, host tools, flashing scripts, reference documents, and architecture documentation.
* **`fuchsia` (`/home/hen/Documentos/code/android/fuchsia`):**
  The modified Fuchsia source tree with our custom drivers and kernel patches on branch `lagos`.

When committing changes:
```bash
# In the Fuchsia source fork:
cd ../fuchsia
git add -A
git commit -m "Your descriptive commit message"

# In fuchsia-lagos:
cd ../fuchsia-lagos
# 1. Update the portable patch against base commit
cd ../fuchsia && git diff cdb2ac2b653 > ../fuchsia-lagos/patches/fuchsia-lagos.patch
cd ../fuchsia-lagos
# 2. Document changes in docs/XX-<topic>.md and README.md
git add -A
git commit -m "docs/patch: update with latest changes"
```

---

## Documentation Index

Detailed engineering logs and findings for every phase of the project:

```
docs/
  01-background.md                    Fuchsia vs Android architecture, myths, and project scope
  02-hardware-map.md                  Full MT6768 SoC memory map, register addresses, and IRQs
  03-recon-log.md                     How stock firmware devicetree was extracted and analyzed
  04-feasibility.md                   Milestone ladder, technical blockers, risk analysis
  05-next-steps.md                    Roadmap and component prioritization
  06-build-notes.md                   Building Fuchsia on Linux host (Bazel OOM workarounds)
  07-lagos-board-plan.md              Board bringup plan (MediaTek UART == dw8250)
  08-flashing-lagos.md                Fastboot procedure, A/B isolation, recovery paths
  09-attempt2-embedded-zbi.md         Isolating boot from GKI split ramdisk corruption
  10-attempt3-mediatek-watchdog.md    TOPRGU hardware watchdog discovery
  11-root-cause-lk-gunzip.md          ROOT CAUSE: LittleKernel mandatory gzip decompression
  12-attempt7-framebuffer-printf.md   Color bands on screen as an early visual debugger
  13-attempt10-blue-shim-works.md     DTB alignment and the CPIO format requirement for embed:zbi
  14-zircon-kernel-runs.md            First kernel execution, heartbeat counter, band progress
  15-framebuffer-console.md           Implementing the 8x16 bitmap text console on screen
  16-userspace-reached.md             MILESTONE: All 8 CPUs online, timer fix, userspace shell prompt
  17-usb-peripheral.md                MILESTONE: Custom mt-musb driver, CDC-Ethernet enumeration
  18-remote-shell.md                  MILESTONE: Interactive remote shell over USB (`tools/lagos-sh`)
  19-lagos-devicetree-board.md        MILESTONE: Real devicetree board driver (`lagos-devicetree`)
  20-storage-msdc-bringup.md          MILESTONE: MediaTek MSDC0 eMMC storage controller bringup
```

---

## Sources & Precedents

* [Fuchsia — Adding support for new boards (bring-up)](https://fuchsia.dev/docs/development/boards/bringup)
* [Zircon ZBI boot shim](https://fuchsia.googlesource.com/fuchsia/+/HEAD/zircon/kernel/phys/boot-shim/zbi-boot-shim.cc)
* [Zircon — MT8167S initial board support (2018, MediaTek UART driver)](https://fuchsia.googlesource.com/fuchsia/+/291c26919aa033c472717699cc957b5c8c138bca%5E%21)
* [Linux Kernel MediaTek SD/MMC Host Driver (`mtk-sd.c`)](https://github.com/torvalds/linux/blob/master/drivers/mmc/host/mtk-sd.c)
* [U-Boot MediaTek SD/MMC Driver (`mtk-sd.c`)](https://github.com/u-boot/u-boot/blob/master/drivers/mmc/mtk-sd.c)
