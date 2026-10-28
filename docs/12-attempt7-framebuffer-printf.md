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
