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

## Attempt 18 RESULT (verified flash 11:48:07): **the console works, and shows the panic**

![attempt 18: boot log on the phone](img/attempt18-console-boot.jpg)
![attempt 18: kernel panic on the phone](img/attempt18-console-panic.jpg)

The halt-on-panic option kept the message on screen, and USB stayed quiet: no more reboot
loop. Highlights from the log:

```
Trying to start cpu 1, mpid 0x100 returned: 0     ... through cpu 7, mpid 0x700: 0
arm64_perfmon_init_once:165: Unexpected/unsupported PMU idcode: 0x45
No EFI available on system.
invalid kernel.smp.maxcpus value, defaulting to 8
...
ZIRCON KERNEL PANIC
UPTIME: 368ms, CPU: 0
*** KERNEL PANIC (caller pc: 0xffffffff003b0b00, stack frame: 0xffffff000079312c0):
*** ASSERT FAILED at (../../zircon/kernel/platform/debug.cc:631): irq_register_result == ZX_OK
kernel_debug_level: 2
CRASH: starting debug shell... (reason = 4)
entering panic shell loop
```

- **All 7 secondary CPUs start** through PSCI with the corrected DynamIQ MPIDRs.
- The panic is in `UartDriverHandoffLate` (upstream `debug.cc:631`): registering the UART
  interrupt handler fails. Even without `stdout-path`, the shim hands the kernel the real
  dw8250 UART at `0x11002000`; it is not the null driver. Our minimal UART node had **no
  `interrupts` property**, so the IRQ number was invalid and
  `register_permanent_int_handler()` failed.
- This also means the kernel has been writing its console to the real UART all along.
  It works fine for TX (no hangs), so a physical tap at `0x11002000` would show the log.

## Attempt 19: UART interrupt + polling

- `lagos-min.dts` UART node: `interrupts = <0 0x70 4>`, copied from the stock `apuart0`
  (SPI 0x70, level-high).
- `bootargs += kernel.debug_uart_poll=true` (note the underscores). The kernel polls the
  UART from a timer instead of registering the IRQ. That sidesteps an untested question:
  MediaTek routes SPI polarity through its `sysirq`/intpol block, which nothing here
  programs.
- DTB file `lagos-min-v5.dtb`; verified in the shim (2459-byte FDT, poll option present).
