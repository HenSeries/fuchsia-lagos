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

## Attempt 13 RESULT (verified flash 11:00:27): GRAY, **no bands**

The screen went through the shim/physboot colours to GRAY and stayed there; no band, no
blinking strip. USB stayed quiet for 3 minutes (no panic-reboot). So the kernel enters
`lk_main` but never reaches the top of `bootstrap2`: it hangs somewhere inside `lk_main`'s
early init.

## Attempt 14: bisect `lk_main` with 20 numbered steps

`LagosStep(k)` paints a 60-row band at row `(k-1)*64` (4-row black gap between bands).
Colours cycle **green, blue, yellow, red, cyan, magenta, white, orange**, so the band count
plus the last colour identifies the step.

| step | after… |
|---|---|
| 1 | `thread_init_early`, `dlog_init_early`, `CallConstructors` |
| 2 | init level EARLIEST → ARCH_EARLY-1 |
| 3 | `arch_early_init` |
| 4 | init level ARCH_EARLY → PLATFORM_EARLY-1 |
| 5 | `platform_early_init` (ZBI driver items: GIC, timer, PSCI, UART…) |
| 6 | `DriverHandoffEarly` |
| 7 | init level PLATFORM_EARLY → ARCH_PREVM-1 |
| 8 | `arch_prevm_init` + its init level |
| 9 | `platform_prevm_init` + its init level |
| 10 | `vm_init_preheap` + level |
| 11 | `heap_init` + level |
| 12 | `vm_init` + level |
| 13 | `DriverHandoffPostVm` + INTC level |
| 14 | lockup detector, sampler, `topology_init` + level |
| 15 | `kernel_init` + level |
| 16 | `bootstrap2` thread created and resumed (next: `BecomeIdle`) |
| 17 | top of `bootstrap2` (scheduler switched threads) |
| 18 | `arch_init` + `platform_init` + `DriverHandoffLate` done; heartbeat starts |
| 19 | late per-CPU init done, starting userboot |
| 20 | `userboot_init` returned: userspace launched |

Bottom strip (rows 1440–1640) blinks white/black every 500 ms once step 18 is reached.
