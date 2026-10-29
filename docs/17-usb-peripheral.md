# 17 — USB peripheral (device mode): plan and first contact

Goal: make the phone show up on a PC over USB as a **CDC-ethernet** device,
so the host can use Fuchsia's netsvc tools (`loglistener` for logs,
`netruncmd` for shell commands, `netcp`) instead of photographs.

## What exists

- **Fuchsia today** (stack survey):
  - Already in the bringup image: `usb-peripheral`, `usb-cdc-function` and
    `network-device`. netsvc auto-picks the first ethernet-class netdevice.
  - The DCI protocol is FIDL `fuchsia.hardware.usb.dci` (`UsbDci` +
    `UsbDciInterface`); data goes over `fuchsia.hardware.usb.endpoint`.
  - The only real DCI drivers are dwc2/dwc3. **dwc2 is the template**
    (DFv2, FIFO-based).
  - `usb-peripheral.bind` only accepts DesignWare VIDs, so it needs a MUSB
    branch.
  - The default function list is `cdc,vsock_bridge`, and vsock_bridge isn't
    in bringup, so the controller would never start. Pass
    `driver.usb.peripheral=cdc`.
  - The board driver that binds today is **qemu-arm64**: the arm64 board's
    platform ID is 1/1 and the driver ignores the DTB. Fuchsia has no
    generic devicetree board driver; the library is
    `sdk/lib/driver/devicetree`.
- **Old Fuchsia MT8167 MUSB driver** (`mt-musb-peripheral`, PIO, DFv1/banjo,
  deleted 2021), saved in
  [reference/mt8167-musb-2021](../reference/mt8167-musb-2021). Same IP; the
  PHY port is at `+0x800` on both chips.
- **MT6768 register facts**: [reference/mt6768-usb-research.md](../reference/mt6768-usb-research.md),
  with sources (MediaTek 4.14/5.10 kernels, Motorola kernel-mtk, the
  mt6768-mainline U-Boot MUSB gadget driver, and mainline 6.18 notes).
  - Clocks: `CLK_IFR_ICUSB` is infracfg_ao gate bit 8 (status 0x10001090,
    clr 0x10001084). `CLK_TOP_USB_TOP_SEL` is CLK_CFG_5 (0x10000090):
    bit 23 = power down, bit 16 = parent.
  - PHY @0x11cc0800: the device-mode sequence clears the UART/GPIO/suspend
    forcing and `BC11_SW_EN`, sets `OTG_VBUSCMP_EN`, waits 800 µs, then
    writes `U2PHYDTM1` low 16 bits = `0x3F2F` (forces VBUSVALID, BVALID,
    AVALID and IDDIG; clears SESSEND).
  - MUSB @0x11200000:
    - The Mentor register map plus MediaTek `L1INTS/L1INTM` at `0xA0/0xA4`.
      `L1INTM` must be set to `0x07`, otherwise no interrupt is dispatched.
    - `TXTOGEN`/`RXTOGEN` at `0x86/0x82` are written `0xFFFF`.
    - Only **8 KB of FIFO RAM**, so the old driver's 61 KB layout must be
      cut to a few 512 B endpoints.
  - IRQ: SPI 97. The stock DT says level-high, connected directly to the
    GIC.
- The preloader log shows `VUSB33 is on`, `mt_usb_phy_poweron` and a USB
  enumeration on every boot (the download-mode handshake), so the block is
  probably left powered.

## Attempt 25: first contact (kernel-side, read-mostly)

`LagosUsbProbe()` in `kernel/mp.cc` replaces the timer/GIC diagnostics
(solved):

1. Reads the always-on blocks: the ICUSB gate, CLK_CFG_5 and sysirq
   `INTPOL` word 3 (SPI 97 is bit 1).
2. Ungates the clocks if needed, using the idempotent set/clr registers.
3. Only once both clocks run, reads the PHY (`ACR1/ACR6/ACR4/DTM0/DTM1`)
   and the MUSB core (`FADDR, POWER, DEVCTL, HWVERS, EPINFO, RAMINFO,
   L1INTS, L1INTM`).

`HWVERS`, `EPINFO` and `RAMINFO` confirm the IP and its real
endpoint/FIFO counts before any driver code depends on them.

## Plan after that

1. **Board publishing**: `qemu-arm64` (already bound) gets a lagos-only
   function that adds a pbus node for the MUSB controller (two MMIOs plus
   the IRQ). Replacing qemu-arm64 with a devicetree board driver can come
   later.
2. **`mt-musb` DCI driver**, DFv2, modelled on dwc2, with logic from the
   old MT8167 driver. PIO only, with its own endpoint server that maps the
   request VMOs, so there are no DMA or 4 GiB address issues.
3. `usb-peripheral.bind` gets a MUSB branch, and `driver.usb.peripheral=cdc`
   goes in the DTB bootargs.
4. Host: `ip link` shows a CDC-ECM interface. Then `loglistener` and
   `netruncmd`.

## Attempt 26: the mt-musb driver (first run)

New in the fuchsia tree (all in `patches/fuchsia-lagos.patch`):

- `src/devices/usb/drivers/mt-musb/`: a DFv2 `fuchsia.hardware.usb.dci`
  driver.
  - It is PIO only and has its own `fuchsia.hardware.usb.endpoint` server,
    which maps registered VMOs instead of pinning them.
  - It runs an ep0 state machine (SETUP / DATA IN / DATA OUT / STATUS, with
    SET_ADDRESS applied after the status stage) plus bulk/interrupt
    transfers through 512-byte FIFOs on ep1–5.
  - It does the clock enables and the mt6768 PHY device-mode sequence,
    including `U2PHYDTM1 = …0x3F2F`.
  - `GetHardwareInfo` returns NOT_SUPPORTED, so usb-peripheral uses legacy
    endpoint allocation.
- `src/devices/bind/fuchsia.mediatek.platform`: VID MEDIATEK = 0x07 and
  DID MUSB_PERIPHERAL.
- `usb-peripheral.bind` gets a MEDIATEK branch.
- `qemu-arm64/lagos-usb.cc` publishes the pbus node: MMIOs USB, PHY,
  infracfg_ao and topckgen, plus IRQ 129 (SPI 97) level-high.
- `boards/arm64/BUILD.gn` adds the driver to bootfs, and
  `build/drivers/all_drivers_list.txt` allowlists it.
- DTB v7 adds `driver.usb.peripheral=cdc`.
- The console pins lines that mention `mt-musb`, `usb-peripheral`,
  `usb-cdc` or `netsvc`.

Result ([photo](img/attempt26-mt-musb-cycle.jpg)): **the driver binds and
reads the real hardware.**

```
mt-musb: clocks CG0 0x0->0x0 CLK_CFG_5 0x1010201->0x1010201
mt-musb: HWVERS 0xe5.. EPINFO 0x88 RAMINFO 0x8b POWER 0x21 DEVCTL 0x99
mt-musb: started, waiting for usb-peripheral
```

- The clocks were already running: ICUSB is ungated and usb_top_sel is
  powered with parent univpll3_d4, as LK left them.
- EPINFO 0x88 means 8 TX + 8 RX endpoints, and RAMINFO 0x8b means 2^11
  words = **8 KB of FIFO RAM**, both matching the research.
- `POWER 0x21` and `DEVCTL 0x99` (session, B-device, VBUS) are the state
  LK left behind.

But usb-peripheral never started:

```
component_manager WARN: Failed to create child "mt-musb" in collection "boot-drivers" ...
  dynamic offer would create a cycle; (child boot-drivers:mt-musb -> child boot-drivers:mt-musb)
driver_manager ERROR: Failed to create child 'mt-musb': kDependencyCycle
```

The driver named its DCI child node `mt-musb`, the same as its own pdev
node, so the usb-peripheral component and the mt-musb component collided
on one name, and the UsbDciService offer pointed at itself. The host
saw nothing past the preloader.

**Attempt 27:** the child node is now `mt-musb-dci`.

## Attempt 27 result: the phone is a USB device. Logs flow over the cable.

[Photo](img/attempt27-usb-enumerated.jpg), [full log captured over USB](../logs/attempt27-loglistener-over-usb.txt).

On the phone (pinned lines):

```
mt-musb: bus reset, high speed
mt-musb: address 1
usb_device: Configuration 1
usb_cdc_function: configured = true
mt-musb: ep 0x81 configured, type 3 maxp 16     (CDC notification, interrupt IN)
mt-musb: ep 0x1  configured, type 2 maxp 512    (bulk OUT)
mt-musb: ep 0x82 configured, type 2 maxp 512    (bulk IN)
```

On the host (Arch Linux):

```
$ lsusb
Bus 007 Device 119: ID 18d1:a020 Google Inc. CDC Ethernet
$ ip -br link
enp8s0f4u1   UP   02:01:79:a3:48:46 <BROADCAST,MULTICAST,UP,LOWER_UP>
$ host_x64/netaddr
fe80::1:79fe:fea3:4847%5
$ host_x64/loglistener        # 268 lines: the whole boot, klog + every component
```

Everything the bring-up worked toward is now wired end to end:

1. My MUSB driver handles ep0 enumeration at high speed: descriptors, SET_ADDRESS
   and SET_CONFIGURATION.
2. usb-peripheral sets up the CDC-ECM function.
3. The bulk endpoints carry ethernet frames both ways.
4. netsvc answers discovery (`netaddr`) and streams the debuglog
   (`loglistener`).

**No more photographs are needed to read the logs.**

`netruncmd` reaches netsvc (`[netsvc] net cmd: uname -a; ...`), but it
can't run anything: `netsvc: cannot launch /boot/bin/sh: ZX_ERR_PEER_CLOSED`.
In this bringup configuration netsvc has no working `fuchsia.process.Launcher`
to start processes with. That's a product-configuration issue, not a USB one,
and it's next.

### How to read logs from the host

```bash
cd fuchsia/out/bringup.arm64-balanced/host_x64
./netaddr          # discover the phone over the USB link
./loglistener      # stream its log
```
