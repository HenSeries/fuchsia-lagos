# MT6768 (lagos) USB2 device-mode: register-level notes

Sources (all fetched 2026-10-28, raw files cached in `scratchpad/src/`):

- [A] MTK 4.14 tree (planet-com/astro-kernel, has mt6768 dir):
  - https://github.com/planet-com/astro-kernel/blob/main/include/dt-bindings/clock/mt6768-clk.h
  - https://github.com/planet-com/astro-kernel/blob/main/drivers/clk/mediatek/clk-mt6768.c
  - https://github.com/planet-com/astro-kernel/blob/main/drivers/misc/mediatek/usb20/mt6768/usb20_phy.c
  - https://github.com/planet-com/astro-kernel/blob/main/drivers/misc/mediatek/usb20/mt6768/usb20.c
  - https://github.com/planet-com/astro-kernel/blob/main/drivers/misc/mediatek/usb20/mtk_musb_reg.h
  - https://github.com/planet-com/astro-kernel/blob/main/drivers/misc/mediatek/usb20/musb_core.c
  - https://github.com/planet-com/astro-kernel/blob/main/drivers/misc/mediatek/usb20/musbhsdma.h
- [B] Motorola 5.10 MTK kernel (same DT clock names as lagos stock DT: sys_clk/ref_clk/src_clk, usb_phy_offset):
  - https://github.com/MotorolaMobilityLLC/kernel-mtk/blob/android-13-release-ttt/drivers/phy/mediatek/phy-mtk-tphy.c
  - https://github.com/MotorolaMobilityLLC/kernel-mtk/blob/android-13-release-ttt/drivers/misc/mediatek/usb20/musb_core.c
  - https://github.com/MotorolaMobilityLLC/kernel-mtk/blob/android-13-release-ttt/drivers/misc/mediatek/usb20/usb20_host.c (set_usb_phy_mode)
- [C] LineageOS mt6768 DT: https://github.com/LineageOS/android_kernel_xiaomi_mt6768/blob/lineage-24.0/arch/arm64/boot/dts/mediatek/mt6768.dts
- [D] **Bare-metal-ish working reference**: mt6768-mainline U-Boot (chain-loaded from LK on Redmi 9 lancelot, gadget works):
  - https://github.com/mt6768-mainline/u-boot/blob/0f587c97b74dbc161769a82b63249948eb15e143/drivers/usb/musb-new/mt6768.c
  - https://github.com/mt6768-mainline/u-boot/blob/0f587c97b74dbc161769a82b63249948eb15e143/drivers/phy/phy-mtk-tphy.c
  - https://github.com/mt6768-mainline/u-boot/blob/0f587c97b74dbc161769a82b63249948eb15e143/arch/arm/dts/mt6768.dtsi
  - https://github.com/mt6768-mainline/u-boot/blob/0f587c97b74dbc161769a82b63249948eb15e143/drivers/clk/mediatek/clk-mt6768.c
- [E] Mainline Linux on MT6768 (gadget ECM/ACM confirmed working per README):
  - https://github.com/mt6768-mainline/linux/blob/6.18/drivers/usb/musb/mediatek.c
  - https://github.com/hataketsu/mt6768-mainline-notes (README.md, reference/mt6768.dtsi)
- [F] torvalds/linux: drivers/usb/musb/musb_core.c (flat EP offsets), arch/arm64/boot/dts/mediatek/mt6358.dtsi (vusb)
- [G] Local: ../fuchsia-lagos/reference/mt8167-musb-2021/ (old Fuchsia mt-musb, MT8167)

---------------------------------------------------------------------------

## 1. Clocks

Bases (verified in [C]): topckgen 0x10000000, infracfg_ao 0x10001000, apmixed 0x1000C000.

| DT cell | ID name ([A] mt6768-clk.h) | what it is ([A] clk-mt6768.c) |
|---|---|---|
| `<&infracfg_ao 8>` | `CLK_IFR_ICUSB` = 8 | gate "ifr_icusb", parent axi_ck, `GATE_IFR2(..., 8)` |
| `<&topckgen 0x66>` | `CLK_TOP_USB_TOP_SEL` = 102 | mux "usb_top_sel", parents {clk26m, univpll3_d4} |
| `<&topckgen 0x20>` | `CLK_TOP_UNIVPLL3_D4` = 32 | fixed factor univpll_d5 / 4 = 62.4 MHz (univpll 1248 MHz) |

### ICUSB gate (infra "ifr2" bank, setclr ops) — HIGH confidence
- SET (gate OFF): infracfg_ao + **0x80** (MODULE_SW_CG_0_SET) -> 0x10001080
- CLR (gate ON):  infracfg_ao + **0x84** (MODULE_SW_CG_0_CLR) -> 0x10001084
- STA:            infracfg_ao + **0x90** (MODULE_SW_CG_0_STA) -> 0x10001090, bit=1 means gated
- Bit **8** -> enable = `write32(0x10001084, 1<<8)`; check `(read32(0x10001090) & 0x100) == 0`.
- Cross-check: U-Boot [D] clk-mt6768.c `GATE_INFRA2(CLK_INFRA_ICUSB, CLK_TOP_AXI, 8)`.

### usb_top_sel mux — HIGH confidence (production table, MT_MUXPLL_ENABLE=1)
`MUX_CLR_SET_UPD(CLK_TOP_USB_TOP_SEL, ..., CLK_CFG_5, CLK_CFG_5_SET, CLK_CFG_5_CLR, 16, 1, 23, CLK_CFG_UPDATE, 22)`
- CLK_CFG_5 = topckgen + 0x90 (SET 0x94, CLR 0x98)
- select: bit **16** (1 bit): 0 = clk26m, 1 = univpll3_d4 (62.4 MHz). Linux 4.14 driver does
  `clk_set_parent(usb_top_sel, univpll3_d4)` ([A] usb20_phy.c usb_prepare_clock).
- PDN (gate) bit **23**: 1 = clock off. Enable = write `1<<23` to CLK_CFG_5_CLR (0x10000098).
- update: CLK_CFG_UPDATE = topckgen + 0x004, bit **22** (write 1 to latch the mux change).
- Sequence: `w(0x10000098, 1<<16 | 1<<23)` (clr sel+pdn) ; `w(0x10000094, 1<<16)` (sel univpll3_d4) ; `w(0x10000004, 1<<22)`.
  (Frequency table in [A] lists usb_top_sel at 62400 kHz.)
- 5.10 [B] driver just clk_enable()s sys/ref/src without set_parent (relies on default/DT assigned-clocks).

### univpll3_d4
Pure divider, no gate. Depends on UNIVPLL (apmixed + 0x238 UNIVPLL_CON0 bit0 EN). UNIVPLL is
used by many blocks; assumed already on. Not separately gate-able.

### Are they on after LK? — MEDIUM confidence: YES on normal boot
- Evidence: the working mt6768 U-Boot [D] (LK chain-loads it as the "kernel") passes
  `<&clk26m>` dummies for all three USB clocks ("usbpll","usbmcu","usb") and never touches
  ICUSB/usb_top_sel, yet the gadget works. So LK leaves them enabled.
- Linux 4.14 clk init (MT_CG_ENABLE=1) explicitly writes INFRA_CG2=0x983fff00 to MODULE_SW_CG_0_SET
  at boot, which includes bit 8 -> Linux *gates* ICUSB early (implying it was left on before).
- Recommendation: write the enable sequence anyway (idempotent, cheap).
- The PHY port's own "ref" clock in [C]/[D] is clk26m (always on). Mainline [E] uses ICUSB as PHY ref.

### Power rails
- MT6358 VUSB (3.0-3.1V): Linux 4.14/5.10 do `regulator_enable("vusb")`, plus "va12", "vio18".
  Mainline mt6358.dtsi marks `ldo_vusb` **regulator-always-on** [F]. Assume ON; no PMIC writes needed.
- MT6370 charger: not needed for device mode if PHY session signals are forced (below).

---------------------------------------------------------------------------

## 2. U2 PHY (0x11cc0800, "U2PHY_COM" bank) — HIGH confidence

USBPHY_* macros in [A] = `usb_phy_base(=of_iomap(np,1)=0x11cc0000) + USB_PHY_OFFSET(0x800) + off`.
So all offsets below are relative to **0x11cc0800** (same as MT8167 Fuchsia phy_mmio layout).

### Register/bit map (names from [B] phy-mtk-tphy.c; MT8167 header [G] agrees on DTM1 bits)
| off | reg | bits |
|---|---|---|
| 0x00 | USBPHYACR0 | 5 RG_USB20_INTR_EN, 0 BGR_EN, 3:2 BGR_DIV, 15 U2PLL_FORCE_ON |
| 0x04 | USBPHYACR1 | 23:19 INTR_CAL (efuse), 14:12 VRT_SEL, 10:8 TERM_SEL |
| 0x08 | USBPHYACR2 | 18 SIF_U2PLL_FORCE_EN, 21:19 PLL_BW |
| 0x14 | USBPHYACR5 | 15 HSTX_SRCAL_EN, 14:12 HSTX_SRCTRL (slew), 11 HS_100U_U3_EN |
| 0x18 | USBPHYACR6 | 31:24 PHY_REV (31:30 REV6), 23 **BC11_SW_EN**, 20 **OTG_VBUSCMP_EN**, 7:4 DISCTH, 3:0 SQTH |
| 0x1C | USBPHYACR3 | 12 PUPD_BIST_EN, 9 EN_PU_DP |
| 0x20 | U2PHYACR4 | 18 dp_100k_mode, 17 DM_100K_EN, 16 DP_100K_EN, 9 RG_USB20_GPIO_CTL, 8 USB20_GPIO_MODE |
| 0x60 | U2PHYDCR0 | 24 SIF_U2PLL_FORCE_ON |
| 0x68 | U2PHYDTM0 | 31:30 uart_mode, 26 **FORCE_UART_EN**, 23 force_datain, 21 force_dm_pulldown, 20 force_dp_pulldown, 19 force_xcvrsel, 18 **FORCE_SUSPENDM**, 17 force_termsel, 13:10 RG_DATAIN, 7 RG_DMPULLDOWN, 6 RG_DPPULLDOWN, 5:4 RG_XCVRSEL, 3 RG_SUSPENDM, 2 RG_TERMSEL |
| 0x6C | U2PHYDTM1 | 18 RG_UART_BIAS_EN, 17 RG_UART_TX_OE, 16 **RG_UART_EN**; 13 FORCE_VBUSVALID, 12 FORCE_SESSEND, 11 FORCE_BVALID, 10 FORCE_AVALID, 9 FORCE_IDDIG, 8 FORCE_IDPULLUP; 5 RG_VBUSVALID, 4 RG_SESSEND, 3 RG_BVALID, 2 RG_AVALID, 1 RG_IDDIG, 0 RG_IDPULLUP |
| 0x80 | U2PHYBC12C | 0 RG_CHGDT_EN |

### Power-on sequence, 4.14 mt6768 `usb_phy_recover()` ([A] usb20_phy.c, "M17_USB_PWR Sequence")
(run after clocks on; `mt_usb_enable` waits 10 ms after clock enable)
1. udelay(50)
2. 0x1C clr bit12 (PUPD_BIST_EN)
3. 0x68 clr bit26 (force_uart_en); 0x6C clr bit16 (RG_UART_EN)
4. 0x20 clr bit9, bit8 (gpio_ctl / gpio_mode)
5. 0x68 clr bit18 (force_suspendm)
6. 0x68 clr bits 7,6 (DM/DP pulldown), clr 5:4 (XCVRSEL=0), clr bit2 (TERMSEL), clr 13:10 (DATAIN)
7. 0x68 clr bits 20,21,19,17,23 (force_dp_pd, force_dm_pd, force_xcvrsel, force_termsel, force_datain)
8. 0x18 clr bit23 (BC11_SW_EN); 0x18 set bit20 (OTG_VBUSCMP_EN)
9. 0x18[31:24] = 0x40 (PHY_REV; i.e. REV6=1)
10. udelay(800)
11. **set_usb_phy_mode(PHY_DEV_ACTIVE)**: `0x6C &= ~0x10; 0x6C |= 0x2F; 0x6C |= 0x3F00`
    -> VBUSVALID=1, AVALID=1, BVALID=1, SESSEND=0, IDDIG=1 (device), IDPULLUP=1, all six FORCE bits set.
    Net low-16 of 0x6C = **0x3F2F**. This is what fakes VBUS/session without charger/extcon.
12. HS slew-rate calibration (optional; default SRCTRL=4 if skipped/timeout)
13. efuse: devinfo index 107 bits[4:0] -> 0x04[23:19] (INTR_CAL) if nonzero (stock DT: nvmem `intr_cal`, mask 0x1f)
14. 0x18[7:4] = 7 (DISCTH 700 mV)
15. 0x04[14:12] = 5 (VRT), 0x04[10:8] = 5 (TERM)  ("HQA special request")
16. optional tuning from DT. Stock lagos DT values: discth=7, eye-vrt=7, eye-term=7, rev6=3 ->
    0x18[7:4]=7, 0x04[14:12]=7, 0x04[10:8]=7, 0x18[31:30]=3.

5.10 [B] same 0x6C forcing in `usb20_host.c: set_usb_phy_mode(PHY_MODE_USB_DEVICE)` (called right
after musb_start() in the connect path). The tphy power_on in [B] only sets RG_VBUSVALID|RG_AVALID
and clears RG_SESSEND (no FORCE bits); set_mode(DEVICE) adds FORCE_IDDIG|RG_IDDIG.

### tphy (5.10 [B]) u2_phy_instance_init + power_on, condensed
init: 0x68 clr {26,18} set XCVRSEL=1, DATAIN=0; 0x6C clr16; 0x00 set5 (INTR_EN); 0x14 clr11;
0x20 clr{9,8}; 0x18 clr23, SQTH=2.
power_on: toggle 0x68 bit18/bit3 (force_suspendm + suspendm pulse, 30us), then clr 18/3/26,
0x6C clr16, 0x20 clr{9,8}, 0x68 clr XCVRSEL/DATAIN/DTM0_PART_MASK, 0x18 clr23, set20,
0x6C set{5,2} clr4, 0x18 REV6=1, udelay(800).

### Slew-rate freq meter location — CONFLICT, LOW confidence
- 4.14 [A]: FM regs at PHY+0xF00/0xF0C/0xF10 -> 0x11cc0F00 (FMCR0), 0x11cc0F0C (VALUE), 0x11cc0F10 (FMMONR1).
- 5.10 tphy v1 [B]/[D]: fmreg = sif_base(0x11cc0000) + 0x100 -> 0x11cc0100.
- Can't resolve from sources. Skip calibration; write 0x14[14:12]=4 (U-Boot [D] does exactly this).

### Is any of this already done by LK? — MEDIUM
U-Boot [D] (after LK) only does tphy init + power_on (no FORCE bits, no set_mode op exists in its
tphy) and gadget enumerates. Suggests LK leaves DTM1 force bits / VBUS in a usable state OR VBUS
is sensed natively. Don't rely on it: write 0x3F2F into 0x6C[15:0] like Linux.

---------------------------------------------------------------------------

## 3. MUSB core @ 0x11200000 — HIGH confidence unless noted

Standard Mentor regs at base+0x00 (mtk_musb_reg.h [A]):
FADDR 0x00 (8), POWER 0x01 (8: 0x40 SOFTCONN, 0x20 HSENAB, 0x10 HSMODE, 0x08 RESET, 0x02 SUSPENDM, 0x01 ENSUSPEND),
INTRTX 0x02 (16), INTRRX 0x04, INTRTXE 0x06, INTRRXE 0x08, INTRUSB 0x0A (8), INTRUSBE 0x0B (8),
FRAME 0x0C, INDEX 0x0E, TESTMODE 0x0F, indexed EP regs 0x10+, FIFOs 0x20+4*ep, DEVCTL 0x60,
TXFIFOSZ 0x62, RXFIFOSZ 0x63, TXFIFOADD 0x64, RXFIFOADD 0x66, HWVERS 0x6C, EPINFO 0x78, RAMINFO 0x79.
Flat EP regs 0x100 + 0x10*ep also work (mainline mediatek.c [E] has no MUSB_INDEXED_EP quirk ->
musb_flat_ep_offset = 0x100+0x10*ep [F]; MT8167 Fuchsia driver uses flat too).

MediaTek-specific:
| off | name | notes |
|---|---|---|
| 0x74 (16-bit) | MUSB_SWRST / "BUSPERF3" | 7 PHY_RST, 6 PHYSIG_GATE_HS, 5 PHYSIG_GATE_EN, 4 REDUCE_DLY, 3 UNDO_SRPFIX, 2 FRC_VBUSVALID, 1 SWRST, 0 DISUSBRESET. Linux reset: `|= DISUSBRESET|SWRST`. Same byte also = MUSB_ULPI_REG_DATA: musb_start sets bit7 NOISE_STILL_SOF, clears bit6 BABBLE_CLR_EN. |
| 0x80/0x82/0x84/0x86 | RXTOG/RXTOGEN/TXTOG/TXTOGEN | mainline [E] and U-Boot [D] write 0xFFFF to TXTOGEN/RXTOGEN at init |
| 0xA0 | USB_L1INTS | level-1 status |
| 0xA4 | USB_L1INTM | level-1 mask |
| 0xA8 | USB_L1INTP | polarity (bits 8 VBUSVALID, 9 IDDIG, 10 DRVVBUS) |
| 0xAC | USB_L1INTC | (MT8167 header: bit0 usb_int_sync) — not in mt6768 Linux header |
| 0x200 | MUSB_HSDMA_INTR | Linux writes 0xFF | 0xFF<<24 (clear + unmask). Channels at 0x200+0x10*ch (+4 CTRL, +8 ADDR, +0xC COUNT); REALCOUNT 0x280+0x10*ch |
| 0x480+8*ep | TXFUNCADDR... | host-mode busctl only |
| 0x620 | MUSB_OPSTATE | |
| 0x700 | RESREG (5.10) | bit0 HSTPWRDWN_OPT |
| 0x730/0x731 | OTG20_CSRL/H | |
| 0x800.. | QMU (QCR0 0x800, RQCSR(n) 0x810+.., TQCSR 0xA00.., QISAR 0xC00, QIMR 0xC04, QIMCR 0xC08, QIMSR 0xC0C) | only with CONFIG_MTK_MUSB_QMU_SUPPORT; ignore for PIO |

L1 bits: 0 TX, 1 RX, 2 USBCOM, 3 DMA, 4 PSR, 5 QINT, 6 QHIF, 7 DPDM, 8 VBUSVALID, 9 IDDIG, 10 DRVVBUS.

**USB_L1INTM must be set** — the ISR in [A]/[D]/[E] computes `L1INTS & L1INTM` and only
dispatches when TX/RX/USBCOM bits are set. Linux writes `L1INTM = TX|RX|USBCOM|DMA` (0x0F), +QINT with QMU.
For PIO: 0x07 is enough (MT8167 Fuchsia writes tx|rx|usbcom too).

**Interrupt status regs are W1C on MediaTek** (not Mentor read-to-clear): Linux generic_interrupt
reads INTRUSB&INTRUSBE, INTRTX&INTRTXE, INTRRX&INTRRXE, then writes those values back; mainline/U-Boot
use `mtk_musb_clearb/clearw` (read then write-back). MT8167 Fuchsia driver already does
`ReadFrom().WriteTo()` — compatible.

### Minimal device-mode bring-up (synthesised from [A] musb_start + [D] mtk_musb_platform_init)
1. Clocks (section 1), PHY power-on + force 0x6C = ...0x3F2F (section 2).
2. FADDR=0; POWER = 0x08 (RESET) for 10 us, then POWER=0, wait 100 us   ([D])
3. DEVCTL = 0x80 (B-device)  ([D]); **no DEVCTL.SESSION needed for peripheral** — Linux device
   path never sets SESSION in musb_start; mainline [E] *clears* SESSION when switching to DEVICE role.
4. Optional (Linux musb_platform_reset): HSDMA channel CTRL regs = 0; SWRST(0x74) |= 0x3.
5. Disable/flush: INTRUSBE=0, INTRTXE=0, INTRRXE=0; INTRRX=0xFFFF, INTRTX=0xFFFF, INTRUSB=0xEF (W1C).
6. TXTOGEN=0xFFFF, RXTOGEN=0xFFFF ([D],[E]).
7. INTRTXE=0x0001 (EP0), INTRRXE=0, INTRUSBE |= RESET(0x04) (+SUSPEND/RESUME/DISCONNECT as desired).
8. 0x74 byte: |=0x80, &=~0x40 (ignore babble; host-relevant, harmless).
9. L1INTM = 0x07 (or 0x0F).
10. POWER = ENSUSPEND(0x01) | HSENAB(0x20) | SOFTCONN(0x40) = 0x61 -> D+ pull-up, host sees attach.
    musb_pullup() toggles SOFTCONN|ENSUSPEND for connect/disconnect.
11. On RESET irq: speed = POWER.HSMODE(0x10); select EP0 and FADDR=0 ([D] "prevent peripheral reset irq lost").

FIFO RAM: 8 KB (`musb->fifo_size = 8*1024` [A]; mainline/U-Boot ram_bits=11). Mainline/U-Boot
use num_eps=8 ("hw has 8 eps") although DT says num_eps=16 — read EPINFO (0x78: [3:0]=TX EPs, [7:4]=RX EPs)
and RAMINFO (0x79) at runtime to confirm (NOT verified on hardware).

IRQ: GIC SPI 97 (0x61). [C]/[E] declare `IRQ_TYPE_LEVEL_LOW` behind the MediaTek sysirq polarity
inverter (`mediatek,mt6768-sysirq` @ 0x0C53A650, size 0x50). If the source really is active-low,
set INTPOL bit: reg 0x0C53A650 + 4*(97/32) = **0x0C53A65C, bit 1** (mtk-sysirq semantics: 1 = invert),
then configure GIC as level-high. Check whether the stock lagos DT cell is 4 (HIGH) or 8 (LOW); not verified.

---------------------------------------------------------------------------

## 4. MT8167 Fuchsia driver ([G]) vs MT6768 — what to change

1. **PHY init is incomplete for MT6768**: MT8167 `InitPhy()` writes RG_VBUSVALID/AVALID/BVALID/IDDIG
   but **never sets the FORCE_* bits (0x6C bits 13:8)**; it relied on the bootloader. Add `0x6C |= 0x3F00`
   (and the 0x2F/clear-bit4 RG values). It also sets RG_UART_TX_OE(17)/RG_UART_I(19)/clk48m/clk60m in DTM1
   and only clears RG_UART_EN afterwards — on MT6768 bit17 = RG_UART_TX_OE, bit18 = RG_UART_BIAS_EN;
   better to port the Linux mt6768 sequence verbatim than this write.
2. MT8167 sets `otg_abist_sele=1` in ACR6[18:16]; MT6768 Linux never touches it. MT6768 sets
   ACR6 OTG_VBUSCMP_EN (bit20) and PHY_REV 0x40 / REV6. MT8167 driver doesn't set VBUSCMP_EN.
3. **FIFO allocation overflows**: MT8167 driver allocates 64 B + 15 EPs x (TX+RX) x 1024 B double-buffered
   (~61 KB). MT6768 FIFO RAM is 8 KB with ~8 EPs. Limit to e.g. EP1-4 512 B single/double buffered
   (U-Boot uses EP1-5, 512 B single, num_eps=6).
4. NUM_EPS=15 in MT8167 -> use EPINFO / <=7 for MT6768.
5. Clocks: MT8167 enables kClkUsb/kClkUsb1p through the clock driver; MT6768 needs ICUSB (infra 0x84 bit8),
   usb_top_sel (CLK_CFG_5 bit23 clr, bit16 set, update bit22) — likely already on from LK.
6. MMIO: USB 0x11200000 (size 0x10000), PHY mapped at 0x11cc0800 so offsets 0x00..0x6C match.
7. TXTOGEN/RXTOGEN=0xFFFF is done by mainline/U-Boot on MT6768; MT8167 driver doesn't (add it).
8. MT8167 HandleReset writes BUSPERF3(0x74)=0x3 (ep_swrst|disusbreset) — same bits as MT6768 MUSB_SWRST
   bit1/bit0, OK.
9. Register map (FADDR..DEVCTL, L1INTS/M/P at 0xA0/A4/A8, flat EP CSR at 0x100+0x10*ep, W1C irq
   status) is identical — the MT8167 core logic should carry over.

## Not found / unverified
- Which slew-rate FM block address is correct on MT6768 (0x11cc0F00 vs 0x11cc0100).
- Actual EP count on lagos silicon (8 per mainline vs 16 per DT).
- Whether LK leaves DTM1 force bits set on lagos (Motorola LK, not Xiaomi).
- Stock lagos IRQ polarity cell value; whether LK/ATF already programmed INTPOL for SPI 97.
