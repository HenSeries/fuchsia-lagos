# 04 — Feasibility, blockers and risk

## Milestone ladder

| Hito | Goal | Realism | Rationale |
|---|---|---|---|
| **0** | Zircon boots `bringup` → **serial console** | 🟡 Achievable (weeks) | All 4 kernel drivers exist or have precedent (below) |
| **1** | Display + touch → minimal UI | 🟠 Months | MediaTek DSI + panel + Mali-G52 magma + I2C touch |
| **2** | Storage (UFS/eMMC) / USB / WiFi | 🔴 Unlikely | MediaTek controllers, closed wifi firmware |
| **3** | Modem / calls / radio | ⛔ Never | proprietary baseband, no docs |

## Why Hito 0 is feasible

| Requirement | Status |
|---|---|
| arm64 support | ✅ first-class in Fuchsia |
| GICv3 driver | ✅ in current tree; addresses known (`0x0c000000` / `0x0c040000`) |
| ARM generic timer | ✅ standard; 13 MHz known |
| PSCI (SMP, reset) | ✅ supported; every core is `enable-method=psci` |
| **MediaTek UART driver** | 🟡 existed in Zircon (MT8167S, 2018) — *same `mt6577-uart` IP*; resurrect/port |
| Boot format | 🟡 ARM `devicetree-boot-shim` wraps a ZBI so a legacy bootloader can launch it |
| Download transport | ✅ fastboot download works, 128 MB cap |

The kernel work for a serial console is **port an existing driver + write a board config
with our addresses** — not greenfield.

## Blockers and how each is handled

### 1. `fastboot boot` disabled → must flash (RESOLVED, mitigated)
Confirmed by probe (see [03-recon-log.md](03-recon-log.md)). No RAM boot.
**Mitigation:** flash the ZBI to **`boot_b`**; keep TrebleDroid on **`boot_a`** as a
one-command recovery (`fastboot set_active a`). Full stock backups exist. Risk of a
*permanent* brick is low because the preloader/LK are never touched in this flow.

### 2. MT6768 board support was removed from the current Fuchsia tree
MediaTek boards (mt8167s_ref etc.) were deleted from mainline Fuchsia years ago.
**Mitigation:** work from Fuchsia **git history** (the 2018 MT8167S commits) for the
Zircon-side patterns, and from **mainline Linux / postmarketOS MT6768** device trees for
register-level detail the stock DTB omits.

### 3. No MediaTek datasheets
Standard for MediaTek. **Mitigation:** the stock device tree + the GPL kernel source
Motorola must publish for `lagos` + postmarketOS give us GIC/UART/timer/clock/pinctrl
details. Enough for Hito 0; the hard gaps (display, modem) are later milestones.

### 4. MediaTek secure world (TEE/GZ at EL3/EL2) and memory carveouts
MediaTek runs a lot in secure world and reserves DRAM regions dynamically.
**Mitigation:** for Hito 0 we load at the bootloader-validated `0x40080000` and avoid
touching reserved regions; precise carveout mapping is deferred to SMP/driver bring-up.

### 5. Physical UART access
We need to actually read the serial console. **Open:** locate debug UART test points or
route it over the Type-C analog lines. Tracked as an open item.

## Risk posture

- Device is the user's **secondary** phone; aggressive experimentation is acceptable.
- The flashing model (B slot only, A untouched, preloader never touched) keeps bricks
  recoverable. The one historically dangerous operation on this device —
  erasing/flashing the preloader — is **not** part of this project.
- Worst realistic case for a bad ZBI: slot B won't boot → `set_active a` → back to normal.

## Honest expectation

The likely terminal state of this project is **a working serial console (Hito 0)** and
maybe partial progress on Hito 1. A daily-driver Fuchsia phone is not a realistic outcome;
the modem alone makes it impossible. The value is the bring-up itself — few people have
booted Zircon on a MediaTek phone.
