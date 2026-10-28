# 07 — lagos board bring-up plan (arm64 / MT6768)

How we actually get Zircon to a serial console on the Moto G06, given what the current
Fuchsia tree provides. This supersedes the generic plan in [05-next-steps.md](05-next-steps.md)
with concrete file-level findings.

## Key discovery: the modern tree does most of the work for us

Two things in the current Fuchsia tree change the plan from "write a board + drivers from
scratch" to "add one UART binding + provide a devicetree":

### 1. There is a devicetree boot shim

`zircon/kernel/phys/boot-shim/devicetree.cc` + `zircon/kernel/lib/devicetree`. The ARM
boot path parses a **DTB** and configures the kernel's early hardware (interrupt
controller, timer, UART, memory) from it. We don't hand-write a board driver for the
early-boot essentials — we feed it a device tree. Our hardware is standard here:

- Interrupt controller `arm,gic-v3` — supported.
- Timer `arm,armv8-timer` — supported.
- `arm,psci-1.0` / SMP — supported.

### 2. The UART we need is almost already supported

UART drivers live in `zircon/system/ulib/uart/include/lib/uart/` (pl011, ns8250, **dw8250**,
pxa, amlogic, qcom-geni). The devicetree shim matches these `compatible` strings:
`arm,pl011`, `snps,dw-apb-uart`, `goog,goog-dw-apb-uart`, `amlogic,*`, `qcom,geni-debug-uart`,
`spacemit,pxa-uart`. **`mediatek,mt6577-uart` is not listed.**

But the MT6577 UART is a 16550 with 32-bit registers — exactly what **`dw8250`** drives.
From `dw8250.h`:

```cpp
static constexpr std::string_view kConfigName = "dw8250";
static constexpr auto kDevicetreeBindings =
    cpp20::to_array<std::string_view>({"snps,dw-apb-uart", "goog,goog-dw-apb-uart"});
static bool TrySelect(const devicetree::PropertyDecoder& decoder) {
    ...
    // Must provide io-width and reg-shift of 32 bits.
    return io_width == 4 && reg_shift == 2;
}
```

So the plan for the console is **not a new driver** — it's:
1. Add `"mediatek,mt6577-uart"` to `dw8250`'s `kDevicetreeBindings`.
2. Ensure our UART node advertises `reg-io-width = <4>` and `reg-shift = <2>` (MediaTek DTs
   usually omit these because the downstream `8250_mtk` driver hardcodes them).

> Caveat: MediaTek's UART has a high-speed divisor path the plain 8250 divisor doesn't use.
> At 115200 with the standard divisor, dw8250 should produce output; if we get garbage,
> the fix is the baud/clock divisor, not a whole new driver.

## The boot method (from recon)

`fastboot boot` is disabled on Motorola's LK ([03-recon-log.md](03-recon-log.md)), so:

```
fastboot flash boot_b  <lagos-devicetree-shim.zbi>
fastboot set_active b
# boot, read UART;  recover: fastboot set_active a  (TrebleDroid untouched on slot A)
```

## Device tree for lagos (the essentials the shim needs)

Derived from the stock DTB ([02-hardware-map.md](02-hardware-map.md)); a trimmed,
standards-clean version lives at `device-tree/lagos/lagos-min.dts`:

| Node | Value |
|---|---|
| `/cpus` | 8× arm64 (2×A75 + 6×A55), `enable-method = "psci"` |
| interrupt controller | `arm,gic-v3`, GICD `0x0c000000`/`0x40000`, GICR `0x0c040000`/`0x200000` |
| timer | `arm,armv8-timer`, PPI 13/14/11/10, 13 MHz |
| psci | `arm,psci-1.0`, `smc` |
| memory | base `0x40000000` |
| uart (console) | `mediatek,mt6577-uart` @ `0x11002000`, `reg-io-width=4`, `reg-shift=2` |

> Note on interrupt cells: the stock DTB uses MediaTek's 4-cell GIC/timer interrupt form
> (`#interrupt-cells = <4>`). Our trimmed DTB uses the **standard 3-cell** GICv3 form the
> Fuchsia devicetree parser expects. The GIC base addresses are unchanged.

## Open hardware question (blocker to actually *see* output)

We still need **physical UART access** to `0x11002000`'s pins on the G06 (debug test points
or a Type-C analog route). Without it we can build and flash a ZBI but can't read the
console. Tracked in [05-next-steps.md](05-next-steps.md).

## Step list

1. **Build arm64 at all:** `fx set bringup.arm64` ✅ (done). Needs ~100 GB free (we delete
   the x64 build to make room — it's reproducible).
2. **Patch dw8250:** add `"mediatek,mt6577-uart"` to `kDevicetreeBindings`.
3. **Author `lagos-min.dts`** → compile to `lagos-min.dtb`.
4. **Wire the devicetree boot shim** to our DTB and build a `lagos` ZBI.
5. **Flash to `boot_b`**, `set_active b`, boot, read UART → **Hito 0**.
6. Iterate on UART baud/divisor if output is garbled; then GIC/timer/SMP.
