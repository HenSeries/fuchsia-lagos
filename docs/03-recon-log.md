# 03 — Recon log (reproducible)

Chronological record of the reconnaissance done on **2026-10-27**. Everything here is
reproducible from the Motorola stock firmware zip plus a phone in fastboot.

Tools used: `unzip`, `unpack_bootimg`, `dtc`, `python3`, Android `fastboot`.

## 1. Inventory — what we already had

The `moto-g06-mod` repo already contained the full Motorola stock firmware:

```
tools/RETBR_XT2535-1_lagos_g_user_15_VVOBS35.78_158_1_6d855a_release_keys_CFC.zip
```

Relevant images inside it:

| Image | Size | Why it matters |
|---|---|---|
| `vendor_boot.img` | 64 MB | contains the **main DTB** (hardware description) |
| `dtbo.img` | 8 MB | device tree overlays (board config) |
| `boot.img` | 64 MB | kernel; used for the `fastboot boot` probe |
| `lk.img` | 1.7 MB | the **LK bootloader** (little kernel) |
| `tee.img`, `gz.img`, `sspm.img`, `scp.img`, `spmfw.img` | — | secure-world / coprocessor firmware → memory carveouts |

## 2. Extract the device tree

The DTB handed to the kernel lives inside `vendor_boot.img`.

```bash
unpack_bootimg --boot_img vendor_boot.img --out out/
```

Header highlights (vendor boot image v4):

```
kernel load address: 0x40080000
kernel tags load address: 0x4bc80000
dtb size: 144695
vendor command line args: bootopt=64S3,32N2,64N2
```

The unpacked `dtb` file was **not** a raw FDT — `dtc` rejected it ("incorrect magic").
First bytes:

```
d7b7ab1e 00023537 00000020 00000020  00000001 00000020 00000800 00000000
```

`0xd7b7ab1e` is the **Android DTB/DTBO table** magic. So `vendor_boot`'s dtb is a
container holding FDT blobs. Parsing the header: 1 entry, FDT at offset 64, size
`0x234f7` (144631 bytes). Carved it out and decompiled:

```bash
dtc -I dtb -O dts -o vendor_boot-fdt0.dts vendor_boot-fdt0.dtb   # 6277 lines
```

Result:

```
model      = "MT6768";
compatible = "mediatek,MT6768";
```

→ **SoC = MediaTek MT6768.** Full hardware map in [02-hardware-map.md](02-hardware-map.md).

This whole step is automated by [`tools/extract-device-tree.sh`](../tools/extract-device-tree.sh).

## 3. Key hardware extracted

Grepping the decompiled DTS for the bring-up essentials:

- GIC: `arm,gic-v3`, GICD `0x0c000000`, GICR `0x0c040000`
- Timer: `arm,armv8-timer`, 13 MHz, PPI 13/14/11/10
- UART: `mediatek,mt6577-uart` @ `0x11002000` (+ `0x11003000`)
- PSCI: `arm,psci-1.0`, `smc`
- CPUs: 2×A75 + 6×A55, all `enable-method = "psci"`
- Memory: base `0x40000000`

## 4. `fastboot boot` probe — the decisive test

**Question:** can the bootloader boot an image from RAM (zero-risk), or must we flash?

Device enumerated as `22b8:2e80 Motorola PCS Android`, `fastboot devices` → `ZY32M9R2JH`.
(First attempt the phone was not on USB at all — a reconnect/cable reseat fixed it.)

getvar snapshot:

```
product: lagos | unlocked: yes | secure: yes | is-userspace: no
current-slot: a | slot-count: 2 | max-download-size: 0x8000000
```

The probe (stock `boot.img`, RAM only — **no partition is written**):

```
$ fastboot boot boot.img
Sending 'boot.img' (65536 KB)      OKAY [ 1.751s]
Booting                            FAILED (remote: 'unknown command')
```

**Result: `fastboot boot` is DISABLED in Motorola's LK.** The download transport works
(OKAY), but the `boot` command is rejected ("unknown command"). The phone was unchanged
and stayed in fastboot afterward.

### Consequence

RAM boot is off the table. The Fuchsia test path is:

1. Build the shim-wrapped **ZBI**.
2. `fastboot flash boot_b <zbi>` — write to the **B slot** only.
3. `fastboot set_active b` and boot; watch the UART.
4. Recover by `fastboot set_active a` (TrebleDroid on slot A) — plus full stock backups
   exist in `moto-g06-mod/backup/` and the stock zip.

Slot A is never touched. This is the safety model for all Hito 0 flashing.

> Note: `max-download-size` is 128 MB, larger than our ZBI will be, so the transport
> won't be a limit.

## 5. Open items after recon

- [ ] Physical UART access route (test points / Type-C) to actually read the console.
- [ ] Decompile `dtbo.img` overlays if board-config fine-tuning needs them.
- [ ] Confirm `boot_b` partition size is ≥ expected ZBI (`getvar partition-size:boot_b`).
