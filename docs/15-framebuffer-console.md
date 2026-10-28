# 15 — A framebuffer text console for Zircon

With the kernel running through `bootstrap2` and panicking somewhere after the secondary
CPUs start, colour bands have reached their limit. We need the panic message, and we still
have no UART tap. So attempt 18 draws the kernel's console output **as text** into LK's
framebuffer.

## How it works

- **Hook:** `zircon/kernel/platform/debug.cc`. `platform_dputs_thread`,
  `platform_dputs_irq` and `platform_pputc` (all serial-console output, including panics)
  first call `LagosConsoleWrite()`. This runs before the null-UART early return, so it
  works with no serial driver.
- **Getting `printf` there:** with the null UART the debuglog's dumper thread is never
  started, so normal `printf` output would only land in the in-memory log. The DTB now sets
  `chosen/bootargs = "kernel.bypass-debuglog=true kernel.halt-on-panic=true"`.
  `bypass-debuglog` sends every line synchronously through `serial_write` →
  `platform_dputs_irq`. `halt-on-panic` keeps the panic on screen instead of rebooting.
- **Font:** `zircon/kernel/platform/lagos_font8x16.h`, printable ASCII generated from
  the host's `Lat2-Terminus16.psfu.gz` (Terminus, SIL OFL 1.1), using the PSF2 Unicode
  table to map code points to glyphs.
- **Region:** rows 496–1632, 71 lines × 90 columns, light gray on black, drawn into all
  three frame slots and cleaned from the cache per line. It **wraps** instead of
  scrolling, which is cheap and safe in panic context. A **red bar** marks the line after
  the newest one, so the text just above the red bar is the most recent.
- **Exclusion:** a best-effort atomic flag between CPUs, bounded so a panic never deadlocks
  on it.

## Screen layout (attempt 18)

| area | content |
|---|---|
| rows 0–480, cols 0–680 | progress bands, now 12 rows each on a 16-row stride (same step numbers and colours) |
| rows 0–480, cols 688–720 | heartbeat strip, blinks white/black every 500 ms after step 28 |
| rows 496–1632 | **text console** |

## Two latent bugs fixed on the way

- `gPhysHandoff` is set to `nullptr` by `EndHandoff()` (`top/handoff.cc`), so the old band
  helper would silently have stopped painting before steps 29–30. All kernel-side painting
  now uses `gPhysmapBase`/`gPhysmapSize` from `vm/physmap.h`, which persist.
- Device-tree revisions must change file name: `lagos-min-v4.dtb` (see the cache gotcha in
  [14](14-zircon-kernel-runs.md)). Verified in the built shim: 2407-byte FDT with the
  `bootargs` and `cpu@700`.

## What to send back

A **photo of the whole screen** after it stops changing. The text near the red bar is what
we need; a panic will show `ZIRCON KERNEL PANIC` and a backtrace.
