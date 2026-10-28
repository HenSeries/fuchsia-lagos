# 10 — Attempt 3: the MediaTek boot watchdog

Attempts 1 and 2 ([08](08-flashing-lagos.md), [09](09-attempt2-embedded-zbi.md)) both
bootlooped with a **~20 s period**. Attempt 2 (ZBI embedded in the shim) ruled out the GKI
ramdisk, pinning the failure to early boot. The ~20 s fingerprint pointed at a hardware
watchdog — and the tree confirms it.

## The evidence

**1. The device has a bootloader-armed watchdog.** Stock DTB
(`device-tree/dts/vendor_boot-fdt0.dts`):

```
toprgu: toprgu@10007000 {
    compatible = "mediatek,mt6768-wdt", "mediatek,mt6589-wdt", "mediatek,toprgu", "syscon", "simple-mfd";
    reg = <0x00 0x10007000 0x00 0x1000>;
```

MediaTek's preloader/LK arm this WDT before jumping to the kernel; Linux's `mtk_wdt`
driver takes it over. If nothing services it, **it resets the SoC ~20 s later.**

**2. Fuchsia's shim only knows Qualcomm's watchdog.** The generic watchdog machinery
(`zircon/kernel/phys/lib/boot-shim/include/lib/boot-shim/watchdog.h`,
`GenericWatchdogItemBase` in `devicetree.h`) matches DTB nodes against a list of
`Watchdog` structs — and that list was exactly one entry:

```cpp
using WithAllWatchdogs = Template<MmioHelper, QualcomMsmWatchdog>;   // before
```

So on lagos the shim never recognizes `toprgu`, never emits the
`ZBI_KERNEL_DRIVER_GENERIC32_WATCHDOG` item, Zircon never pets the WDT, and the SoC
resets on schedule. **This explains both bootloops end to end** — and why they looked
identical regardless of how the ZBI was delivered.

## The fix

Added `MediatekToprguWatchdog` to `watchdog.h` and registered it:

```cpp
using WithAllWatchdogs = Template<MmioHelper, QualcomMsmWatchdog, MediatekToprguWatchdog>;
```

Register map (from Linux `drivers/watchdog/mtk_wdt.c`):

| reg | offset | meaning |
|---|---|---|
| `WDT_MODE` | `+0x00` | bit0 `EN`; writes need key `0x22` in bits[31:24] (**key is write-only**) |
| `WDT_RST` | `+0x08` | write `0x1971` to reload (pet) |

Actions handed to Zircon's generic32 watchdog driver:

| action | addr | clr_mask | set_mask | effect |
|---|---|---|---|---|
| pet | `+0x08` | `0xffffffff` | `0x1971` | reload counter |
| enable *(detection)* | `+0x00` | `0x1` | `0x1` | see note |
| disable | `+0x00` | `0xffffffff` | `0x22000000` | key + EN cleared |

`watchdog_period_nsec = 5 s` (well inside the ~20 s timeout).

> **The write-only key trap.** `GenericWatchdogItemBase::OnNode` decides the WDT is enabled
> by testing `(Read(enable.addr) & enable.set_mask) == enable.set_mask`. Had `set_mask`
> included the key (`0x22000001`), the read would never match (the key doesn't read back),
> the `ENABLED` flag would never be set, Zircon would assume it's off and not pet it — and
> we'd bootloop again. So `enable_action` tests only the `EN` bit. A write through it would
> lack the key and be ignored by hardware, which is fine: we never want to re-enable it.

## How it plays out at boot

The shim itself does **not** touch the WDT (it only emits the ZBI item, same as the proven
Qualcomm path). Zircon's kernel generic32 watchdog driver then pets/disables it during
kernel init — ~1 s after handoff on femu, far inside the ~20 s window. If it still loops,
the next lever is to also force an early `MmioHelper::Write(0x22000000, base)` in phys
right after the node matches (the MMIO is already readable there), but that's the
belt-and-suspenders step, not the first move.

## Build / flash

Same pipeline as attempt 2: `fx build` → `tools/build-boot-img.sh` (packs the embedded
shim+ZBI) → flash `boot_a` → observe. Success = **the bootloop stops**: the device sits
(black screen — bringup has no display driver) instead of cycling through the preloader.
Recovery unchanged (`dist/boot_a.trebledroid.backup.img` via antumbra).
