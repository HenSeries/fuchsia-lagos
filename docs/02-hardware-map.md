# 02 — Hardware map (Moto G06 / `lagos` / MT6768)

All values extracted from the stock firmware's device tree
(`device-tree/dts/vendor_boot-fdt0.dts`) unless noted. This is the reference for writing
the Fuchsia board config and kernel drivers.

## SoC identity

```
model       = "MT6768";
compatible  = "mediatek,MT6768";
```

MT6768 is the silicon behind the marketing name "Helio G81". 12 nm. Well-covered by
mainline Linux / postmarketOS, which is useful for cross-referencing register details
that the device tree omits.

## CPU topology

8 cores, arm64, all brought up via **PSCI**:

| Node | Core | Cluster |
|---|---|---|
| cpu@000–003 | Cortex-A55 | little |
| cpu@100–101 | Cortex-A55 | little |
| cpu@102–103 | Cortex-A75 | big |

→ 6× Cortex-A55 + 2× Cortex-A75. `enable-method = "psci"` on every core, so SMP comes up
cleanly through PSCI `CPU_ON` — no custom spin-table or secure-world poke needed.

## Interrupt controller — GICv3

```
compatible = "arm,gic-v3";
#interrupt-cells = <4>;
#redistributor-regions = <1>;
reg = <0x0 0x0c000000 0x0 0x00040000    // GICD (distributor)
       0x0 0x0c040000 0x0 0x00200000    // GICR (redistributor)
       0x0 0x0c53a650 0x0 0x00000050>;  // (aux)
interrupts = <0x01 0x09 0x04 0x00>;      // maintenance IRQ (PPI 9)
```

Fuchsia's current tree has a GICv3 kernel driver. The addresses above feed the board's
kernel-driver config directly.

## Timer — ARM generic timer

```
compatible = "arm,armv8-timer";
clock-frequency = <0x00c65d40>;          // 13,000,000 Hz (13 MHz)
interrupts = PPI 13, 14, 11, 10 (secure/non-secure phys, virt, hyp)
```

Standard `arm,armv8-timer`; supported directly. 13 MHz is the usual MediaTek arch-timer rate.

## UART — serial console (the Hito 0 target)

```
apuart0: serial@11002000  { compatible = "mediatek,mt6577-uart"; }   // <-- console
apuart1: serial@11003000  { compatible = "mediatek,mt6577-uart"; }
```

- **Console base address: `0x11002000`** (`apuart0`).
- The `mediatek,mt6577-uart` IP is 8250-derived. **Zircon shipped a driver for this exact
  IP** on the MT8167S reference board in 2018 (`zircon/kernel/dev/uart/mt8167/uart.cpp`).
  That driver is the starting point for our kernel serial driver.
- Access to the physical UART pins requires a hardware path (test points / USB-serial via
  the Type-C analog lines, or an existing debug UART route). TBD during Hito 0.

## Power

```
psci { compatible = "arm,psci-1.0"; method = "smc"; };
```

PSCI 1.0 over SMC — supported. Used for CPU_ON (SMP) and system reset/off.

## Memory & boot parameters

From `vendor_boot.img` header (v4) and the `/memory` node:

| Parameter | Value | Use |
|---|---|---|
| **Kernel load address** | `0x40080000` | physical load address for Zircon |
| RAM base | `0x40000000` | low bank; `reg = <0x40000000 0x3e605000>` (~1 GB static) |
| kernel tags / dtb addr | `0x4bc80000` | where bootloader places the DTB |
| ramdisk load addr | `0x47c80000` | |
| page size | `0x1000` | |
| vendor cmdline | `bootopt=64S3,32N2,64N2` | MediaTek DRAM config hint |

> The `/memory` reg only describes the low ~1 GB bank; the MT6768 bootloader passes the
> rest of the 4 GB dynamically. For early boot (Hito 0) the kernel load region at
> `0x40080000` is what matters and is already validated by the bootloader.

## Secure world / coprocessors (carveouts to respect)

Firmware images present in the stock package:
`tee.img` (TrustZone), `gz.img` (hypervisor), `sspm.img`, `scp.img`, `spmfw.img`, `sspm`.

The device tree's `reserved-memory` children are allocated **dynamically** (no fixed
`reg`): `sspm_share`, `scp_share`, `ion-carveout-heap`, `consys-reserve-memory`,
`shared-dma-pool`. For a serial console we don't need to map these precisely; they become
relevant once we bring up SMP + real drivers and must avoid clobbering EL3/EL2 regions.

## GPU (for later — Hito 1)

**Mali-G52 MC2** — same family as the Khadas VIM3 (the only officially supported ARM
board). The VIM3's `magma` Mali backend is the reference for an eventual display/GPU
driver. Not needed for Hito 0.

## Fastboot / device state (live, 2026-10-27)

| var | value | meaning |
|---|---|---|
| `product` | `lagos` | |
| `unlocked` | `yes` | bootloader unlocked ✅ |
| `secure` | `yes` | verified boot still enforced |
| `is-userspace` | `no` | real LK bootloader fastboot (not fastbootd) |
| `current-slot` | `a` | TrebleDroid lives on slot A |
| `slot-count` | `2` | A/B — slot B is our test/safety sandbox |
| `max-download-size` | `0x8000000` (128 MB) | fits a ZBI comfortably |
| serial | `ZY32M9R2JH` | |

**`fastboot boot` is DISABLED** in this bootloader — see [03-recon-log.md](03-recon-log.md).
That decides the boot method: **flash to `boot_b`, keep `boot_a` as the recovery slot.**
