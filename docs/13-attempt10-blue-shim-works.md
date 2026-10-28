# 13 — Attempt 10: BLUE. The whole boot shim runs on the Moto G06

## The bug that kept attempts 8 and 9 on GREEN

`InitMemory()` registers a few "special" memory ranges before building the allocator pool:

| range | type |
|---|---|
| `[PHYS_LOAD_ADDRESS, +image_size)` — the whole loaded shim+ZBI image | `kPhysKernel` |
| the devicetree blob | `kDevicetreeBlob` |

Both are *allocated* types, and memalloc forbids two different allocated types from
overlapping:

```
ZX_ASSERT_MSG(memalloc::FindNormalizedRanges(...).is_ok(),
              "Pool::Init(): bad input: the provided ranges feature overlap among different "
              "allocated types, or an allocated type with one of kReserved or kPeripheral");
```

Attempt 8 embedded `lagos-min.dtb` with `.incbin` into the shim's `.rodata`, i.e. **inside
the loaded image**. The built image proves it: the image spans `0x40080000 .. 0x41c84558`
(`image_size = 0x1c04558`) and the FDT sits at offset `291168` inside it. The assert fires,
`abort()` has no PSCI or UART yet, and the CPU spins: GREEN forever. Attempt 9 (MMU off)
could not change that, because the assert comes before any MMU work.

## Attempt 10: two changes

1. **Copy the DTB out of the image** before handing it to the shim
   (`LagosCopyDtbOutOfImage()` in `linux-arm64-boot-shim.cc`): byte-copy to `0x4bb80000`,
   near the top of LK's staging window, inside `/memory` bank 1 and far from the image
   and from LK's initrd.
2. **No `stdout-path`** in `lagos-min.dts` (`chosen {}` is empty). With it, the shim would
   pick the dw8250 driver and spin in `while (!TxReady())` on MediaTek register offsets
   (CPR `0xf4`, USR `0x7c`) never validated on this SoC, with no tap to see it. Null console
   until the shim is proven.

MMU stays off in the shim (`enable_mmu = false`).

## Result (verified flash 10:43:24): **BLUE**

The user reported **blue**. On this build that means, in order:

- the TOPRGU watchdog disable and GREEN paint ran,
- the `BootShimHelper` constructor completed: devicetree parsed, memory pool built (YELLOW),
- `InitItems()` matched everything: GIC v3, armv8 timer, PSCI, 8-CPU topology, memory,
- `Boot()` was entered.

**First complete run of a Fuchsia component on the Moto G06.**

What we don't know: which of the two changes did it. The overlap assert is certain on
inspection; the UART spin is plausible. Restoring `stdout-path` later is its own bisect step,
and it matters only once there is a physical UART tap.

## Attempt 11: paint the rest of the boot chain

Zircon removed its in-kernel graphics console; `ZBI_TYPE_FRAMEBUFFER` is only consumed by
userspace display drivers (Intel, PCI). So paints stay our only output, extended past the
shim:

| stage | colour | where |
|---|---|---|
| shim, about to jump into physboot | **MAGENTA** `0xFFFF00FF` | `ShimOptions::boot_progress(0)` right before `boot.Boot()` |
| shim `Boot()` failed (bad ZBI / load / append) | **RED** `0xFFFF0000` | `boot_progress(1)` right before `abort()` |
| physboot entered | **CYAN** `0xFF00FFFF` | top of `ZbiMain` (MMU off) |
| physboot memory + its own MMU up | **ORANGE** `0xFFFF8000` | after `InitMemory` (identity-mapped RAM) |
| vmzircon loaded/relocated, handing off | **WHITE** `0xFFFFFFFF` | before `prep.DoHandoff` |
| **Zircon kernel running** | **GRAY** `0xFF808080` | `lk_main`, right after `PostHandoffBootstrap`, via the physmap + cache clean |

Why the framebuffer stays safe to paint after physboot's MMU comes up: the framebuffer bank
is RAM in `lagos-min.dts`, so physboot identity-maps it and the kernel physmap covers it.
memalloc allocates first-fit from the lowest address, so nothing lands at `0x781b0000`
before the 188 MB first bank fills up. The kernel paint runs before the PMM hands out pages.

Expected reading: the last colour on screen is the last stage reached. Physboot
decompresses the kernel package, so a few seconds between colours is normal.

Changed files (Fuchsia checkout, local patches):

- `zircon/kernel/phys/boot-shim/include/phys/boot-shim/devicetree.h` — `boot_progress` hook
- `zircon/kernel/arch/arm64/phys/boot-shim/linux-arm64-boot-shim.cc` — MAGENTA/RED
- `zircon/kernel/phys/physboot.cc` — CYAN/ORANGE/WHITE (arm64 only)
- `zircon/kernel/top/main.cc` — GRAY (arm64 only)

## Attempt 11 RESULT (verified flash 10:51:59): **RED**

The shim reached `Boot()` and took the failure path. The cause was in the packaging, not
the code. `set_zbi_boot("embed:zbi")` makes `GetDevicetreeBootZbi()` search the embedded
data for a **file named `zbi`**, in a newc cpio or in `BOOTLOADER_FILE` ZBI items. We had
embedded the raw `fuchsia.zbi`, so the lookup found nothing and returned an empty ZBI, and
`boot.Init()` rejected it. (Docs [09](09-attempt2-embedded-zbi.md) wrongly claimed a raw ZBI
is used directly; corrected there.) No USB reset followed: `abort()` just spins.

## Attempt 12: embed the ZBI inside a cpio

`tools/build-boot-img.sh` now writes `dist/lagos-zbi.cpio`, a newc archive with one member
`zbi` (the whole `fuchsia.zbi`) plus `TRAILER!!!`, and embeds that instead. Verified in the
decompressed kernel: the archive is 4-byte aligned, the payload is byte-identical to
`fuchsia.zbi`. No Fuchsia rebuild was needed; the shim, physboot and kernel are attempt 11's
binaries, so the same colour legend applies (MAGENTA → CYAN → ORANGE → WHITE → GRAY).

## Attempt 12 RESULT (verified flash 10:54:53): **GRAY — the Zircon kernel runs on lagos** 🎉

Every stage of the chain executed: shim → physboot (entry, memory + MMU, kernel load and
relocation) → handoff → `lk_main` past `PostHandoffBootstrap`. The USB observer stayed
quiet for the full 3 minutes after the jump: no panic-reboot. Continued in
[14](14-zircon-kernel-runs.md).
