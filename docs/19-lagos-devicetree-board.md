# 19 — A real board driver: lagos-devicetree

Until attempt 29 the phone booted the stock `arm64` board config, whose platform
ID (`qemu-arm64`, VID/PID 1/1) bound the **QEMU** board driver. That driver:

- ignored our devicetree;
- published QEMU's PCI ECAM and PL031 RTC at QEMU physical addresses, which
  pl031-rtc then poked on the real phone;
- carried the lagos USB node as hardcoded C++ (`lagos-usb.cc`).

## What changed (attempts 30–31)

- **New board driver** `src/devices/board/drivers/lagos-devicetree`. It is
  built with GN, like crosvm.
  - It walks the DTB the shim passes as `ZBI_TYPE_DEVICETREE` with
    statically linked visitors: `DefaultVisitors` (bind properties from
    `compatible`, `reg` → MMIO, BTI, boot metadata, SMC, driver host,
    config) plus `ArmGicVisitor`, which turns `interrupts` into Zircon
    IRQs and handles our 3-cell GICv3 specifiers.
  - It publishes every node through `PublisherDev`.
- **Board identity.** `boards/arm64/BUILD.bazel` sets
  `hardware_info = { name: "lagos", vendor_id: 7, product_id: 1 }`, which
  is `fuchsia.mediatek.platform` MEDIATEK / MT6768. The board driver binds
  on that.
- **Board bundle.** `boards/arm64/BUILD.gn` replaces `qemu-arm64` +
  `pl031-rtc` with `lagos-devicetree`. The QEMU driver is back to stock,
  and `lagos-usb.cc` is gone.
- **DTB v8** gets a `usb@11200000` node:
  - `compatible = "mediatek,mt6768-usb20"`
  - 4 `reg` entries: MUSB, U2 PHY, infracfg_ao, topckgen
  - `interrupts = <0 0x61 4>`
- **mt-musb is now a composite driver.** It has a primary parent `pdev`
  bound by `compatible` and connects with
  `Connect<Service::Device>("pdev")`.

### Attempt 30: board OK, USB not bound

[Photo](img/attempt30-lagos-devicetree.jpg): `lagos: devicetree board started`,
but nothing for mt-musb, and the host saw no USB device. The devicetree
library publishes **every** node as a *composite node spec*, with the
platform device as its primary parent (`sdk/lib/driver/devicetree/manager/node.cc`).
A plain, non-composite bind rule never matches that. dwc2 binds the same
way for the same reason.

### Attempt 31: everything bound by devicetree

[Log over USB](../logs/attempt31-devicetree-board.txt):

```
platform-bus: VID: 7 PID: 1 board: "lagos"
Binding fuchsia-boot:///lagos-devicetree#meta/lagos-devicetree.cm to pt
Matched 'fuchsia-boot:///mt-musb#meta/mt-musb.cm' to composite node spec 'usb-11200000'
lagos-devicetree: lagos: devicetree board started
Binding fuchsia-boot:///mt-musb#meta/mt-musb.cm to usb-11200000
mt-musb: HWVERS 0xe503 EPINFO 0x88 RAMINFO 0x8b ...
Binding fuchsia-boot:///usb-peripheral#meta/usb-peripheral.cm to mt-musb-dci
mt-musb: bus reset, high speed / address 1 / Configuration 1 / ep 0x81, 0x1, 0x82 configured
platform device timer did not match a driver/composite.          <- expected: no driver
platform device memory-40000000 did not match a driver/composite. <- expected
```

`tools/lagos-sh ps` works as before. `qemu-arm64` and `pl031-rtc` are no
longer running.

From here on, a new device driver needs:

1. a DTB node;
2. a composite bind on `compatible`.

The board driver needs no C++ changes.
