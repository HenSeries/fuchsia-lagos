# 01 — Background: what we're doing and why it's hard

## The goal

Run **Google Fuchsia** on a **Motorola Moto G06** (`lagos`). Fuchsia is Google's OS
built on the **Zircon** microkernel — it is **not** Linux and **not** Android. It shares
nothing with the Android stack except the physical silicon.

## The core misconception to clear up first

> "Isn't Fuchsia compatible with any Android device?"

No. Two very different ideas get conflated:

| Claim | True? | Why |
|---|---|---|
| Fuchsia can run Android **apps** | ✅ Yes | Fuchsia has **Starnix**, a Linux syscall-compatibility layer that runs unmodified Linux/Android binaries (including the Android Runtime). |
| Fuchsia runs **on the hardware** of an Android phone | ❌ No | Zircon needs its own board bring-up and drivers for every hardware block. It inherits **nothing** from Android's Linux kernel or vendor drivers. |

Android boots on the G06 because Motorola/MediaTek wrote a Linux kernel + drivers for
the MT6768. Fuchsia would need its **own** drivers for that same hardware, written for
Zircon. None exist. The fact that the phone runs Android contributes nothing toward
running Fuchsia — they are two separate software stacks that merely share a chip.

That is why Fuchsia's official supported-hardware list is just **two boards** (Intel NUC,
Khadas VIM3) plus the emulator — not "any ARM phone".

## Why you can't just flash an image

Fuchsia does not boot like an Android GSI:

- It does **not** chain off the Android `boot.img`/system/vendor partitions.
- It uses its own boot image format (**ZBI** — Zircon Boot Image).
- The bootloader must either understand ZBI or be fed a **boot shim** that wraps the ZBI
  so a legacy bootloader (e.g. one that only knows `fastboot boot` of a Linux-style
  kernel) can launch it.
- Every peripheral (display, touch, storage, modem, wifi, GPU) needs a Zircon driver.

So "trying Fuchsia on this phone" means **porting** it: board bring-up.

## What bring-up actually requires

From the official bring-up guide, the minimal `bringup` product needs:

1. A supported architecture (arm64 ✅).
2. **Bootloader + kernel support**: early serial debug, an interrupt controller, and
   timers, provided as *kernel drivers*.
3. **Build assembly**: a GN board config (`fx set bringup.<board>`).
4. A **board driver**: configures the non-probeable hardware (common on ARM64).
5. **Non-kernel drivers**: GPIO, clocks, power, storage, display, …

Items 1–3 are the floor for a **serial console** (our Hito 0). Items 4–5 and beyond are
where the multi-year difficulty lives.

## Scope decision

We target **Hito 0: a serial console**. That alone is a real achievement on a MediaTek
phone and exercises the whole early-boot path. A usable graphical UI is a separate,
much larger project; the modem/radio is effectively out of reach (proprietary baseband
firmware, no documentation).

See [04-feasibility.md](04-feasibility.md) for the full milestone ladder and blockers.
