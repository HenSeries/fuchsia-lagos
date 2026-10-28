# 16 — Userspace reached (attempts 21–22)

## Attempt 21: Fuchsia userspace runs on the Moto G06

Attempt 21 (see [15](15-framebuffer-console.md)) made the SMP startup wait
*poll* the counter for 15 s instead of sleeping on a timer interrupt, and gave
secondary CPUs a fallback for a missing PSCI `context_id`.

Result ([photo](img/attempt21-userspace.jpg)): **boot continued past the SMP
wait into Fuchsia userspace.** At ~16.5 s of kernel time the framebuffer
console shows:

- `component_manager` starting the bringup topology
- `driver_manager` main loop running, binding `platform-bus`, finding drivers
- `sysmem` finished initialization
- `fshost` started (config dump)
- `console-launcher` mounting `/svc`, `/tmp`, `/dev`, `/block` and
  **launching `/boot/bin/sh`** (shell on the console)
- `netsvc: running in full mode`
- the kernel's memory monitor: `memory availability state - ImminentOutOfMemory`

So the whole chain — LK → boot shim → physboot → Zircon → userboot →
component_manager → drivers/fshost/shell — works on MT6768 with one CPU.

### What the per-core squares said

Every secondary (cores 1–7) painted GREEN, RED, BLUE:

| stage | colour | meaning |
|-------|--------|---------|
| 0 | GREEN | entered from PSCI at EL1 |
| 1 | **RED** | `x0` was **not** a kernel pointer: MediaTek's ATF does not pass the PSCI `CPU_ON` `context_id` through. The core reloaded it from `gLagosSecondaryContext[Aff1]` |
| 2 | BLUE | after `ArmDropToEl1` |
| 3 | — | never painted |

So the `context_id` hypothesis is **confirmed**; the table fallback is needed
on this firmware (Linux never uses `context_id`, so nobody noticed).

### Why stage 3 never appeared: my own marker

The stage-3 marker sat after this in `secondary.S`:

```
.Lmmu_on_vaddr:
  movlit tmp, MMU_TCR_FLAGS_KERNEL   // disables TTBR0 walks (trampoline off)
  msr tcr_el1, tmp
```

and painted the framebuffer's **physical** address, which is only reachable
through the TTBR0 identity map that had just been switched off. Translation
fault with `vbar_el1 = 0` → the core is gone. In attempt 20 the cores still
had a bad `sp` as well, but in attempt 21 the marker was the only thing left
killing them.

## Attempt 22

1. **Stage-3 marker moved** to the first instruction at `.Lmmu_on_vaddr`,
   before the TCR switch (verified in the disassembly: the `0xffffff00`
   colour stores sit between `br x23` and `msr TCR_EL1`). The table fallback
   stays. Expect cores to reach YELLOW, then WHITE/ORANGE (C code), then
   GREEN at stage 6 (`arch_late_init_percpu`).
2. **More RAM.** The device has 4 GiB (rank0 `0x40000000+2G`, rank1
   `0xc0000000+2G`, from the preloader mblock list in the expdb dump).
   Added two windows that are free in the preloader list *and* untouched by
   every LK `mblock_reserve`:
   - `[0x80000000, 0x9f900000)` — below `SCP-reserved` (0x9f900000),
     `ccci_tag_mem` (0x9fff0000), the modem (`md_mem_usage` 0xa2000000+256M)
     and LK's `avb`/`*_work_buf` buffers (0xb2b00000+)
   - `[0xc0000000, 0x13ffff000)` — all of rank1 except `dramc-rk1`'s page

   Everything between 0x4c080000 and 0x7ec00000+ (ATF, TEE, GenieZone,
   SSPM, SPM, modem shared memory, logo, framebuffer bank remainder) stays
   out. Total goes from ~200 MiB to ~2.7 GiB. DTB installed as
   `lagos-min-v6.dtb` (compile cache, see [14](14-zircon-kernel-runs.md)).
3. **Pinned diagnostics.** In attempt 21 the 71-line wrapping console was
   overrun by userspace logs, so the `lagos[smp-wait]` timer/GIC dump was
   lost. The console region now starts with 12 pinned 2-row slots (yellow
   text, rows 496–880, grey rule below): every logical line starting with
   `lagos`, or containing `PANIC`/`panic`/`ASSERT`, is copied there; slot 0
   is reserved for `lagos: heartbeat`. The scrolling console (46 lines)
   continues below.

### Still open

- **CPU0 timer interrupt**: unknown whether it fires. The heartbeat slot
  answers it: if `lagos: heartbeat N s` keeps counting, timer IRQs work.
- Secondaries after the fix.

## Attempt 22 result: 8/8 CPUs, shell prompt, but no timer interrupt

[Photo](img/attempt22-8cpus-shell.jpg).

- **All 8 CPUs online**: `lagos: smp wait done after 75 ms, ready 0xff online 0xff`.
  The per-core square row is full for every core: the stage-3 fix was the
  last thing keeping them out. MediaTek's firmware really drops the PSCI
  `context_id`; the `gLagosSecondaryContext` table stays.
- Userspace comes up in **~1.5 s** of kernel time (was ~16.5 s: the SMP
  wait no longer times out). `vc` (virtual console), archivist,
  driver_manager, console-launcher, sysmem, and a **`$` shell prompt** on
  the framebuffer console. No OOM warning with the extra RAM.
- **Heartbeat slot is empty**: the kernel thread that sleeps 500 ms never
  wakes, so the timer interrupt is still not delivered.

Timer/GIC snapshot at the SMP wait (CPU0, IRQs unmasked, `DAIF 0x240`):

| register | value | reading |
|---|---|---|
| `CNTV_CTL` | `0x5` | enabled, not masked, **ISTATUS = 1**: the virtual timer fired |
| `CNTV_CVAL` vs `CNTVCT` | `0xc782b7c` < `0xc898e78` | expired **~87 ms** earlier, never serviced |
| `ISR_EL1` | `0` | the CPU sees no pending IRQ |
| `ICC_HPPIR1` | `0x3ff` | no pending Group-1 interrupt at the CPU interface |
| `ICC_IGRPEN1` / `PMR` / `RPR` | `1` / `0xf0` / `0xff` | enabled, unmasked, idle |
| `GICD_CTLR` | `0x12` | ARE_NS + EnableGrp1A (non-secure view) |
| GICR0 `ISENABLER0` | `0x0800000f` | SGI 0-3 (IPIs) and **PPI 27 enabled** |
| GICR0 `ISPENDR0` | `0x893f0000` | **PPI 27 pending** at the redistributor |
| GICR0 `IGROUPR0` | `0` | Secure-only register when DS = 0: RAZ to us, not informative |
| `IPRIORITYR6` | `0xa0a0a0a0` | priority 0xa0 < PMR |

So the interrupt is **pending and enabled in the redistributor, but the CPU
interface never presents it**. The LK log in expdb has the likely reason:
`[BLDR] next is GZ at 0x47EC00000`. The preloader boots **MediaTek
GenieZone**, a hypervisor, after ATF. With GZ at EL2 (consistent with
secondaries entering at EL1 even though PSCI normally enters at the highest
NS EL, and with `context_id` getting lost), EL1's `ICC_*` accesses may
really be the *virtual* CPU interface (`ICV_*`). Interrupts then reach us
only if GZ injects them.

## Attempt 23: active IRQ-path probe

`LagosIrqProbe()` (kernel/mp.cc) runs right after the SMP-wait snapshot,
with IRQs masked so nothing is taken. It raises three interrupts at the CPU0
redistributor, and after each one prints the redistributor's
pending/active/enabled bits next to `HPPIR1` and `ISR_EL1`:

1. **SGI 15 to self** via `ICC_SGI1R_EL1` (the IPI path)
2. **PPI 30, the physical timer** (`CNTP` with an expired compare value),
   unused by Zircon
3. **PPI 27, the virtual timer** as left by the kernel

It also prints `ID_AA64PFR0_EL1`, `ICC_AP1R0` and `MPIDR`. If PPI 30 or the
SGI shows up in `HPPIR1`/`ISR` but PPI 27 doesn't, the hypervisor treats the
virtual timer specially. The fix is then `kernel.arm64.force-pct=true`, the
physical timer. If none of them show up, the whole physical IRQ path is
owned by GZ.

Also: 16 pinned slots instead of 12, and the boot `CMDLINE` line no longer
gets pinned (it matched "panic" via `halt-on-panic`).
