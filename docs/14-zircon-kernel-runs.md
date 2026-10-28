# 14 — The Zircon kernel runs on the Moto G06; kernel progress bar

## Where we are (attempt 12, 2026-10-28 10:54)

The screen turned **GRAY**: the Zircon kernel proper is executing on the MT6768, painted from
`lk_main` through the kernel physmap. The full chain that got us here:

| fix | doc |
|---|---|
| LK gunzips the boot kernel, so ship it gzipped | [11](11-root-cause-lk-gunzip.md) |
| disable the TOPRGU watchdog as the shim's first instruction | [10](10-attempt3-mediatek-watchdog.md) |
| feed the shim a clean minimal DTB, copied **out of** the image | [13](13-attempt10-blue-shim-works.md) |
| no `stdout-path` (null console) until we have a UART tap | [13](13-attempt10-blue-shim-works.md) |
| embed the ZBI as a cpio member named `zbi` | [13](13-attempt10-blue-shim-works.md) |

No panic-reboot followed in 3 minutes, but GRAY alone can't tell "kernel healthy" from
"kernel hung after `lk_main`'s first lines".

## Attempt 13: a progress bar inside the kernel

Painting late in boot needs the framebuffer pages to stay ours. Physboot now retypes the
framebuffer bank as `kTestRamReserve` right after `InitMemory`. The kernel PMM puts that
type on its permanently-reserved list, but it is still RAM, so the physmap keeps covering it.

Kernel stages paint horizontal **bands** from the top, 160 rows each, on top of the GRAY
background. Count the bands:

| band | colour | where in `zircon/kernel/top/main.cc` | proves |
|---|---|---|---|
| (background) | GRAY | `lk_main` after `PostHandoffBootstrap` | kernel entered |
| 1 | GREEN | top of `bootstrap2` | threads + scheduler run |
| 2 | BLUE | after `platform_init` / `LK_INIT_LEVEL_ARCH_LATE-1` | arch + platform init (GIC, timer, PSCI from the ZBI driver items) |
| 3 | YELLOW | before `userboot_init` | late per-CPU init done; starting userspace |
| 4 | MAGENTA | after `userboot_init` | userboot launched: **Zircon reached userspace** |
| bottom strip | blinks WHITE/BLACK every 500 ms | `lagos-heartbeat` thread, started after band 2 | scheduler + arch timer + GIC interrupts work |

A blinking strip is the strongest single signal: it needs timer interrupts delivered
through the GIC and the scheduler waking a sleeping thread.
