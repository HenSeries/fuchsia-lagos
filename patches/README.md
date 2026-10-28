# Local patches to the Fuchsia checkout

`fuchsia-lagos.patch` is `git diff` of the Fuchsia tree (base commit in `BASE`) with every
lagos bring-up change: Bazel OOM fix, dw8250 `mediatek,mt6577-uart` binding, MediaTek
TOPRGU watchdog item, the arm64 boot shim (WDT disable, embedded DTB copied out of the
image, framebuffer paints), the `boot_progress` hook, and the physboot/kernel paints.

The shim `.incbin`s `zircon/kernel/arch/arm64/phys/boot-shim/lagos-min.dtb` by absolute
path; copy `device-tree/lagos/lagos-min.dtb` there before building.

```bash
cd ../fuchsia && git apply ../fuchsia-lagos/patches/fuchsia-lagos.patch
cp ../fuchsia-lagos/device-tree/lagos/lagos-min.dtb zircon/kernel/arch/arm64/phys/boot-shim/
```
