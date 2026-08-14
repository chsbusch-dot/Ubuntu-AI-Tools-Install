# Putting generic Android on a MYX fitness console (MYX215A)

Notes for converting a dead-service MYX / MYX II bike console into a general
purpose Android device, keeping the touchscreen working.

Last updated: 2026-08-14

## What the device is

Identified from the FCC label on the bottom edge (`FCC ID 2AUR9-MYX215A`,
`Serial INB24524B`, `Input 12V 5A`, "Designed in Connecticut"):

| Item | Value |
|---|---|
| Product | MYX fitness "Tablet", model **MYX215A** (the 21.5" bike console) |
| Applicant | Myx Fitness, LLC (later Beachbody / BODi) |
| SoC | **MediaTek MT8176** — 2× Cortex-A72 + 4× Cortex-A53, Mali-T880 |
| RAM / storage | 4 GB / 32 GB eMMC |
| OS as shipped | **Android 8.1 (Oreo)** |
| Display | 21.5" 1080p, capacitive touch |
| Power | 12 V ⎓ 5 A barrel jack (60 W) |
| Ports | RJ45, USB-C, micro-USB, 3.5 mm headphone |
| Mount | 75 × 75 VESA pattern on the rear plate |

The important consequence: **this is already an Android tablet**, not an
embedded RTOS appliance. There is an Android userspace, a Linux kernel, and a
working touch driver in there — the goal is to get at it, not to invent it.

The micro-USB port next to the USB-C is almost certainly the **USB OTG /
download port** — on MediaTek all-in-one boards that is the port SP Flash Tool
and mtkclient talk to. That is the port that matters here. (Unverified — see
"Open questions".)

There is **no public MYX firmware, no scatter file, and no community ROM** for
this device. Nobody has done this before, so anything destructive has to be
preceded by a full backup.

## Route 0 — take over the Android that is already on it (free, zero risk)

Do this before touching a flash tool. Appliance builds very often ship with
ADB over TCP left enabled, and the console has an Ethernet port.

```bash
# Plug the console into the LAN, find its IP in the router's DHCP table
adb connect <console-ip>:5555

# Or over the micro-USB port, with a USB-A -> micro-B cable to a PC
adb devices
```

If ADB answers, the job is basically done — no flashing needed:

```bash
adb shell getprop ro.build.version.release     # confirm 8.1
adb shell getprop ro.treble.enabled            # tells you if Route 1 is viable
adb install lawnchair.apk                      # any launcher
adb shell cmd package set-home-activity <pkg>/<launcher-activity>
adb shell pm disable-user --user 0 <myx-package>   # stop the kiosk app
```

Then sideload F-Droid / Aurora Store and use it as a normal Android 8.1 tablet.
Touch keeps working because nothing was changed underneath it.

Also worth five minutes: a USB keyboard/mouse into the USB-C port through an
OTG adapter. Esc, Alt-Tab, or a long-press on Home escapes a lot of badly
built kiosk launchers.

## Route 1 — flash it (the MT8176 is fully exploitable)

The key finding: **MT8176 is hwcode `0x8176` in
[mtkclient](https://github.com/bkerler/mtkclient)'s chip table, with kamakiri
BROM exploit support** — the same class as MT8163/MT8173. That means the
bootloader lock state is irrelevant: every partition can be read and written
over the micro-USB port from BROM, and `seccfg` can be unlocked, without any
vendor signing keys.

### 1. Back up everything first

Non-negotiable — there is no firmware to restore from if this goes wrong.

```bash
git clone https://github.com/bkerler/mtkclient && cd mtkclient
pip install -r requirements.txt

python mtk printgpt                 # partition table — read this carefully
python mtk rl dump/ --skip userdata # full per-partition dump
```

Entering BROM on a device with no volume buttons: connect the cable with the
unit powered off and let mtkclient catch the handshake, or force it with
`python mtk crash`, which crashes the preloader into BROM. Test points on the
board are the last resort.

### 2. Read the GPT — this single fact decides the whole project

- **A `vendor` partition exists** → the device is Treble'd → **GSI works** →
  continue below.
- **No `vendor` partition** → no GSI is possible. A full port would need
  MT8176 kernel sources MYX never published, plus re-doing the touch and panel
  drivers against a new kernel. Not worth it — go to Route 2.

### 3. Flash a GSI, not a random ROM

This is the part that answers "I want touch to work". A **GSI (Generic System
Image) replaces only the `system` partition and keeps the stock kernel and
vendor HALs** — so the touchscreen, panel timings, WiFi and audio keep running
on the drivers that already work on this exact hardware.

- Target: **arm64, A-only, `vndklite`** build (the vndklite variants exist
  precisely for Oreo-era vendor partitions with an incomplete VNDK).
- Sensible targets are Android 9 or 10 — TrebleDroid / phh-AOSP or LineageOS
  17.1/18.1 GSI. Android 12+ GSIs dropped the Oreo-vendor workarounds and are
  much less likely to boot.
- Write it with mtkclient directly (`python mtk w system system.img`) rather
  than relying on fastbootd, which Oreo appliances often do not implement. If
  a `vbmeta` partition exists, flash a verification-disabled vbmeta too or
  dm-verity will reject the modified system.

**The failure mode to avoid:** flashing some other MT8176 device's full stock
ROM. Different digitizer, different I2C address and firmware blob — touch will
be dead and the panel may not light. GSI-over-stock-vendor is the whole trick.

## Route 2 — swap the mainboard (~$60–150, predictable outcome)

Perfectly viable, and the fallback if there is no vendor partition. A 21.5"
1080p panel is the most commodity LCD in existence, and Android all-in-one
boards (RK3566 / RK3568, Android 11/12) with LVDS output and a touch header
are sold for exactly this — signage, POS, vending. The existing 12 V 5 A
supply and barrel jack drive them directly.

Before buying anything, open the rear cover and check two things:

**1. How does the touch flex terminate?**

- → a small separate PCB with a **4-wire USB pigtail** = **USB HID touch**.
  Best case. Plugs into any board — Android, Linux, Windows — no drivers.
- → a **6–8 pin FFC straight into the mainboard** = **I2C touch**. The new
  board must support that exact controller (GT9xx / ILI2xxx) with a matching
  device tree entry. Fiddly. At that point, buying an off-the-shelf 21.5"
  open-frame USB touch monitor and reusing only the housing and arm is often
  cheaper than fighting it.

**2. What panel is it?** Photograph the model sticker on the back of the LCD
(e.g. `LM215WF3`, `MV215FHM-N30`). You need the replacement board's LVDS to
match — almost certainly 2-channel 8-bit, 30-pin — and its backlight driver to
match the panel's LED string voltage/current.

Outcome: stock Android 11/12, working touch, Play Store, on the original
screen and mount.

## Recommendation

1. **Route 0 tonight.** Costs nothing, and on kiosk appliances it works more
   often than it should.
2. If ADB is closed: **Route 1's dump + `printgpt`**. One evening, $0, needs a
   USB-A→micro-B cable and a Linux box. The GPT tells you if a GSI is possible.
3. No vendor partition → **Route 2**.

## Caveats

- **No HDMI input**, so it cannot be used as a plain monitor without going
  inside and swapping the board.
- **Widevine drops to L3** after a GSI — Netflix and friends will be SD-only.
- Play certification after a GSI needs the usual GSF-ID registration step.
- MT8176 is a 2016-era SoC. Expect Android 9/10-class performance: fine for a
  browser, YouTube, a dashboard, or a Home Assistant wall panel.

## Open questions (verify physically)

- Is the micro-USB port really the OTG/download port? (Strongly implied by the
  MediaTek board design, not confirmed.)
- Is the touch controller USB HID or I2C? Decides how easy Route 2 is.
- Does the GPT contain a `vendor` partition? Decides whether Route 1 exists.

The FCC internal photos for `2AUR9-MYX215A` would answer the first two, but
every FCC mirror (fccid.io, fcc.report, device.report) and `apps.fcc.gov` are
blocked from the environment these notes were written in. Worth a look from an
unfiltered connection before opening the case.

## Sources

- [FCC ID 2AUR9-MYX215A — Myx Fitness, LLC, Tablet MYX215A](https://fccid.io/2AUR9-MYX215A)
- [MYX215A user manual (FCC exhibit)](https://fcc.report/FCC-ID/2AUR9-MYX215A/4565469.pdf)
- [mtkclient — MediaTek BROM/DA client](https://github.com/bkerler/mtkclient)
- [Generic system images — Android Open Source Project](https://source.android.com/docs/core/tests/vts/gsi)
- [TrebleDroid GSI list](https://github.com/TrebleDroid/treble_experimentations/wiki/Generic-System-Image-%28GSI%29-list)
