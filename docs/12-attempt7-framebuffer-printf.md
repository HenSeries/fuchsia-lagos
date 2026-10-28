# 12 — Attempt 7: the framebuffer as a UART-free "printf"

Attempt 6 proved our code runs (no watchdog reset in 4 minutes) but left the device sitting
on the Moto logo, indistinguishable between "Zircon is up" and "the shim hung". `expdb` can't
help: it only records *abnormal* boots ([11](11-root-cause-lk-gunzip.md)). We still have no
UART. So we make the boot **paint the screen**.

## Why it works

Motorola's LK configures the display and never turns it off at the kernel jump — the logo
persisting after handoff proves the panel keeps scanning the framebuffer. The LK log in
`expdb` gives the exact geometry:

```
mblock_resize-debug-R[17].start: 0x781b0000, sz: 0x1050000 map: 1 name: framebuffer
[LK_DDP/OVL]ovl0, layer=0, ... dst(0, 0, 720, 1640), pitch=2944, fmt=eBGRA8888, addr=781b0000
[LK_DDP/OVL]ovl0, layer=3, ... dst(0, 0, 720, 1640), pitch=2880, fmt=eBGRA8888, addr=7865c000
[LK_DDP/OVL]ovl0, layer=0, ... pitch=2944, fmt=eBGRA8888, addr=78b08000
[lk logo: mt_disp_config_fb_layer, addr = 0x781b0000
[DISPCHECK][LCM] resolution: 720 x 1640
```

So: a dedicated 17 MB framebuffer region at `0x781b0000`, BGRA8888, 720×1640, three frame
slots (`+0`, `+0x4ac000`, `+0x958000`) referenced by different overlay layers. Painting
**all three** slots (14.7 MB, inside the region) guarantees the visible layer changes
whichever one is on top. It's plain RAM: a `volatile uint32_t*` fill, no MMIO magic.

## What the shim does now (`linux-arm64-boot-shim.cc`)

| point in `PhysMain` | paint | what it proves |
|---|---|---|
| right after the TOPRGU disable (first instructions) | **GREEN** `0xFF00FF00` | the shim's first instructions executed |
| right after `ZX_ASSERT(shim_helper.InitItems())` | **BLUE** `0xFF0000FF` | the devicetree parsed; memory, UART, GIC, timer, watchdog items matched; `Boot()` is next |

(`Boot()` loads the embedded ZBI, appends the items and jumps into physboot → Zircon.)

## Reading the screen

| screen ends as | meaning |
|---|---|
| Moto logo, untouched | our code did **not** run (would contradict attempt 6) — or the panel isn't scanning this buffer |
| solid **GREEN** | shim entry reached, then it died/hung inside `BootShimHelper` construction or `InitItems()` → **DTB parsing is the bug** (the huge MediaTek DTB, 4-cell interrupts…). Next: embed our clean `lagos-min.dtb` |
| solid **BLUE** | the shim got all the way through the devicetree and called `Boot()` → the remaining unknown is physboot/Zircon. Next: a third colour from inside physboot, or the UART |
| BLUE then **changes / garbage / goes dark** | something after `Boot()` is writing memory or driving the display → physboot/Zircon activity |

Colour bytes are **B,G,R,A** in memory (little-endian `uint32`): green = `00 FF 00 FF`,
blue = `FF 00 00 FF`. If the panel's byte order differs you'd see magenta/cyan instead —
still unmistakable versus the logo.

Same pipeline as attempt 6: `fx build` → `tools/build-boot-img.sh` (embed + gzip) → flash
`boot_a` → look at the screen. Recovery unchanged.

## Attempt 7 RESULT (2026-10-28, flashed 10:10:40): **solid GREEN**, nothing else

The framebuffer printf works, and it answers two questions at once:

1. **Our code runs on the Moto G06** — now a visual fact, not an inference from a silent
   watchdog. The shim's first instructions (TOPRGU disable, paint) executed.
2. **It never reached BLUE.** The shim dies somewhere between the GREEN paint and
   `InitItems()` returning — i.e. inside `BootShimHelper`'s constructor (`InitMemory`, then
   enabling the MMU) or inside the item matchers. Every one of those consumes **Motorola's
   MediaTek DTB** handed over in `x0`: hundreds of nodes, 4-cell GIC/timer interrupt
   specifiers, `reserved-memory` children allocated dynamically (no `reg`), and enough
   LK-injected reservations to plausibly overflow the shim's 512-range table
   (`ZX_ASSERT_MSG(recorded, "Insufficient space to record devicetree memory reservations")`).
   With the watchdog off, an assert/fault just hangs — green forever.

## Attempt 8: feed the shim our own device tree

The shim is handed `lagos-min.dtb` (embedded with `.incbin`, 8-byte aligned) instead of
`x0`. It is small and standards-clean — 8 CPUs via PSCI, `arm,gic-v3` with 3-cell
interrupts, `arm,armv8-timer`, the `mediatek,mt6577-uart` node with `reg-shift`/`reg-io-width`
for `dw8250`, a `chosen/stdout-path` — and, deliberately, a **conservative `/memory`**:

```
memory@40000000 {
    reg = <0x0 0x40000000 0x0 0x0bc80000>,   /* LK's kernel+ramdisk window, 188 MB */
          <0x0 0x781b0000 0x0 0x01050000>;   /* LK's framebuffer, so paints stay mapped */
};
```

The first bank is exactly LK's `kernel_addr_mb` + `ramdisk_addr_mb` staging window; nothing
else lives there (ATF sits at `0x4ce00000`, TEE/GenieZone/modem/SCP higher), so the shim's
allocator can never clobber secure firmware. The second bank keeps the framebuffer mapped
once the MMU is on; if the allocator uses it you'll see garbage — harmless and itself a
sign of life. No `toprgu` node: the WDT is already disabled first-thing.

A third paint, **YELLOW** (`0xFFFFFF00`), goes right after the constructor:

| screen ends as | meaning |
|---|---|
| GREEN | even the clean DTB dies in the constructor → `InitMemory` / MMU enable on this SoC |
| **YELLOW** | memory parsed and MMU up; died in `InitItems()` (GIC / timer / UART / CPU matchers) |
| **BLUE** | the whole devicetree path works → `Boot()` → physboot/Zircon is the next frontier |

## Attempt 8 RESULT (verified flash, 2026-10-28 10:21): still **GREEN**

(If the colour were going to change it would do so well under a second after green — the
constructor runs immediately after the paint — so a minute of green is final.)

The clean embedded DTB **did not change the outcome**: the shim still dies inside
`BootShimHelper`'s constructor. That rules out the MediaTek DTB's content as the cause.
What the constructor does regardless of which DTB it gets: builds the memory pool from
`/memory` (plus the DTB/ramdisk/image "special ranges") and then **enables the MMU**
(`enable_mmu = true`). And there is a confound in our own instrumentation: the YELLOW
paint sits *after* the MMU comes up — if the framebuffer bank didn't get mapped, the paint
itself faults, and that also leaves the screen green.

Two suspects remain, and one experiment separates them.

## Attempt 9: run the shim with the MMU off

`kOptions.enable_mmu = false` — a supported mode (physboot sets up its own MMU afterwards).
With the MMU off every paint is a physical write that cannot fault on mapping, so the
colours become an unambiguous progress bar through the shim:

| screen ends as | meaning |
|---|---|
| GREEN | the constructor dies for a non-MMU reason (devicetree match assert, memalloc pool, special ranges) |
| **YELLOW** | constructor fine; `InitItems()` dies (GIC / timer / UART / CPU matchers) |
| **BLUE** | the whole shim works MMU-off → **the MMU enable (or the post-MMU FB mapping) was the bug** → `Boot()` → physboot |

### Operational lesson from the first attempt-8 flash (2026-10-28 10:18)

`fastboot flash boot_a` reported `Sending OKAY` and then
**`Writing 'boot_a' FAILED (usb_read failed: No such device)`** — this phone's flaky USB
enumeration dropped the link mid-write. The partition's state after that is unknown
(old image intact / new image complete / partial). Rules going forward:

- **Never interpret a boot until the flash printed `Writing 'boot_a' OKAY`.** A failed
  write followed by a reboot can show a *previous* attempt's colour and mislead the bisect.
- A USB observer showing *no* preloader cycling after the reboot rules out a corrupt
  (bootlooping) partition but **not** "old image still there".
- Mitigations: reseat the cable / use another (USB 2.0) port, or flash via antumbra
  through the preloader — its DA writes have never failed on this device.

## Attempt 9 RESULT (verified flash, 2026-10-28 10:32): still **GREEN**

With the MMU off the paints cannot fault, so GREEN is now unambiguous: the shim dies inside
`BootShimHelper`'s constructor **before** any MMU work. The MMU was never the problem.
Reading the constructor (`InitMemory` in `zircon/kernel/phys/boot-shim/devicetree.cc`)
found the bug, and it was ours. See [13](13-attempt10-blue-shim-works.md).
