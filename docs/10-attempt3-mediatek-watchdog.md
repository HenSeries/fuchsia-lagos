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

## Attempt 3 RESULT (2026-10-28): still bootloops

Flashed the watchdog-aware build → **still cycling** (8 preloader↔quiet transitions in
60 s, same ~15–20 s period). So the ZBI-item path alone did not help. That is itself
informative: that path only works if **Zircon's kernel gets far enough to run its
generic32 watchdog driver and pet the WDT**. Identical looping means either the shim /
physboot dies or hangs *before* the kernel handoff (so nobody ever pets it), or the ~20 s
reset isn't the TOPRGU at all.

## Attempt 4: disable the WDT as the very first instruction

To separate those two, the shim now disables the watchdog **unconditionally, first thing
in `PhysMain`, before constructing the shim or parsing the DTB** — a raw physical write of
`0x22000000` (key | EN=0) to `WDT_MODE` at the known base `0x10007000`. Safe because the
MMU is off at phys entry (`arch/arm64/phys/start.S`: "The caches and MMU are disabled").
Uses the same `MmioWrite32` primitive as `WatchdogMmioHelper`.

Outcomes this discriminates:

| observed | meaning |
|---|---|
| loop **stops**, device stays quiet (black) | the TOPRGU WDT was the reset source and the kernel just never reached the pet; the shim is at least running. Quiet = Fuchsia running **or** shim hung — UART tells which |
| still loops at ~20 s | the reset is **not** the TOPRGU (preloader timeout / other reset source) **or** the shim faults instantly before this write even matters → points at DTB parse / LK handoff |
| loop period **changes** | a different reset path took over — also informative |

## Attempt 4 RESULT (2026-10-28): still loops, black → reboot

Identical to attempts 2 and 3. **This is the most important data point so far:** three
radically different images (embedded ZBI; + watchdog ZBI item; + unconditional
first-instruction WDT disable) produced **exactly the same** ~20 s black→reboot. If our
code ran, attempt 4 alone should have changed *something*. So either **our code never
executes** (LK jumps — the logo goes black — but something fails before `PhysMain`), or
it runs, dies almost immediately, and a reset source **other than the TOPRGU** fires at
~20 s.

### Ruled out this round

| hypothesis | check | result |
|---|---|---|
| LK doesn't recognize the image as a kernel | Linux arm64 `Image` header of the packed shim | **valid**: magic `ARM\x64` @56, `text_offset=0`, `image_size=0x1c03e48`, MZ `code0` → LK accepts it |
| AVB rejects the unsigned boot.img | flags of every vbmeta we flash (`images/vbmeta*-noverity.img`, header offset 120) | **flags = 0x3** = `HASHTREE_DISABLED \| VERIFICATION_DISABLED` → boot is **not** verified; AVB is not the blocker |
| another AP watchdog besides TOPRGU | stock DTB scan | **none** — only `mediatek,sspm` @0x10400000 (coprocessor; can reset the AP but isn't a standard WDT) and PMIC `mt6358` (no system-WDT subnode) |

## Attempt 5: a diagnostic that needs no UART

To separate "our code never runs" from "it runs and something else resets", the shim now
**deliberately hangs forever** right after the TOPRGU disable — `for (;;) wfi;` as the
first real thing in `PhysMain` (marked *REVERT AFTER* in `linux-arm64-boot-shim.cc`).

| observed | meaning |
|---|---|
| black and **never reboots** | our code runs **and** the TOPRGU disable works → the bug is later in the shim (DTB parse / `InitMemory` / `Boot`). Big step: we have a foothold to bisect |
| still reboots every ~20 s | we never execute, **or** a non-TOPRGU reset source (SSPM / preloader-level) fires → next look at the LK handoff (load address / `text_offset` vs LK's `0x40080000`) and the SSPM |

### The diagnostic binary, verified

Dead-code elimination collapsed the shim to **696 bytes** (everything after the infinite
loop is unreachable) — expected and harmless. `linuxboot-embed` still appends the ZBI
(packed image 29 047 352 bytes, header `image_size` patched to cover it), the Linux arm64
header is intact (`ARM\x64` @56, `text_offset=0`, flags `0x4`), and `llvm-objdump -d` of
the ELF shows `PhysMain` is exactly the six instructions we want, with the volatile store
**before** the hang:

```
000000000000014c <PhysMain>:
     14c: mov  w8, #0x7000
     150: mov  w9, #0x22000000
     154: movk w8, #0x1000, lsl #16     ; x8 = 0x10007000  (TOPRGU WDT_MODE)
     158: str  w9, [x8]                 ; WDT_MODE = key | EN=0  -> watchdog off
     15c: wfi
     160: b    0x15c                    ; hang forever
```

`_start` is the normal phys entry (saves the DTB `x0→x9`, picks `VBAR_ELx` by `CurrentEL`
so no illegal `msr`, cache-maintains `[__data_start,_end)`, then calls `PhysMain`). So if
this image executes at all, the device sits black and never reboots.

> Gotcha for anyone re-checking the header: the magic reads back as the bytes `ARMd`
> because `0x64` **is** `'d'` — that's the correct `ARM\x64`. A first validation script
> here flagged it "BAD" only because of a mis-escaped literal.
