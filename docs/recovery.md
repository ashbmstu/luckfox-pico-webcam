# Brick recovery — Luckfox Pico Mini B

How to recover a Mini B that won't boot. The most common cause is a bad
write to the bootloader area of the SPI NAND (`idblock.img` / `uboot.img`
/ `download.bin`). The fix is the **maskrom + SocToolKit** path, which
bypasses U-Boot entirely and reflashes the chip from a clean factory
image. Maskrom is implemented in the SoC's mask ROM (silicon — can't be
overwritten), so as long as the chip is alive it will respond.

This procedure has been used successfully on this exact board model
before. Hard rule from past experience: **if everything else is
working, don't touch this — it really only exists for boards that won't
boot.** And **never** flash `idblock.img` / `uboot.img` / `download.bin`
piecemeal; always flash the combined `update.img` (it bundles them
correctly and atomically).

## What you need

- The bricked Mini B
- A USB-C **data** cable (not power-only — power-only cables silently
  fail to enumerate)
- A pin / paperclip / fine tweezers (to hold the BOOT button)
- A Windows 10 / 11 PC
- Third-party tools and firmware you must obtain yourself — none of
  these ship in this repository:
  - **Rockchip DriverAssistant** (version 5.13 is known to work) —
    `DriverInstall.exe` installs the Rockchip "RKDevice" / loader USB
    driver that Windows needs for maskrom mode
  - **SocToolKit** (version 1.98 is known to work) or **RKDevTool**
    (the more widely distributed equivalent) — the flashing GUI
  - **Luckfox Pico Mini B factory image** — from the Luckfox Pico wiki
    or Luckfox firmware downloads. A build dated 250429 is known to
    work on Mini B; newer releases from Luckfox should also be fine.
    You need at least:
    - `update.img` — the all-in-one factory image (~7 MB; contains
      bootloader, kernel, rootfs, oem, userdata, env)
    - `download.bin` — the initial loader the maskrom needs to receive
      before it can accept the rest of the flash
    - For Method B, also copy from the same package onto a microSD card:
      `env.img`, `boot.img`, `oem.img`, `rootfs.img`, `userdata.img`
      (the package often includes `sd_update.txt`, which lists the
      U-Boot `mtd` commands for SD-card flashing)
  - **Android platform tools** (`adb` on your `PATH`) — for verifying
    recovery after a reflash; see [installing.md](installing.md)
  - **A terminal emulator** for the serial console — PuTTY, Tera Term,
    or picocom (on Linux/WSL) are all freely available; any terminal
    that can open a serial port at 115200 8N1

Allow ~10 minutes for the whole procedure on a first attempt.

## Decision tree — which recovery do you need?

Before reaching for maskrom, figure out *how* the board fails so you
pick the right method.

| Symptom | What it means | Method |
|---------|---------------|--------|
| `adb devices` shows the board as `device` after replug | Not bricked. You don't need this doc. | n/a |
| Windows enumerates a `Rockchip` / `RKusb` / `RK3xxx Loader Device` after replug | Board is in maskrom mode (or stuck loader). The bootloader ROM is responding — chip is alive. | **Method A** below — full reflash via SocToolKit |
| Windows enumerates an "Unknown Device" after replug | Probably maskrom but the Rockchip USB driver isn't installed. | Run `DriverInstall.exe` first, replug, re-check. Then **Method A**. |
| Nothing on USB-C, but with a UART adapter you can see U-Boot output / interrupt boot | Bootloader region intact; rootfs / kernel / oem corrupt. | **Method B** — U-Boot console + SD-card flash |
| Board boots normally but daemon misbehaves and ADB is dropping out under load | OS is fine; you need a console that doesn't depend on the USB stack. | **Method C** — UART for live diagnostics (no flashing) |
| Nothing enumerates on USB-C *and* nothing comes out of UART even when powered | Either bad USB cable, dead USB port, dead UART adapter, miswired pins, or hardware-dead chip. | See troubleshooting; if nothing helps, hardware-dead. |

For "we touched the bootloader and now nothing happens", the answer is
almost always **Method A**. For "the OS is partly broken but bootloader
still works", **Method B** is less invasive. For "I just need to see what
the kernel is doing", **Method C** gets you a console without touching
anything.

---

## Method A — full reflash via maskrom + SocToolKit

This wipes the entire SPI NAND and rewrites it from `update.img`. It
brings the board back to factory stock — not a working webcam. After
this you must rebuild and deploy this project's daemon and restore the
on-device configuration files; see [Step 5](#step-5--verify-recovery).

### Step 1 — install the Rockchip USB driver (one-time)

Skip this if Device Manager already shows a "Rockchip" or "RKDevice"
entry (i.e. you've installed it on this PC before).

1. Run `DriverInstall.exe` from the Rockchip DriverAssistant package
   as Administrator (right-click → "Run as administrator").
2. In the window: click **Driver Install** (left button). Wait until it
   reports success. If it asks "Are you sure you want to install this
   driver?" Windows pop-ups, click "Install".
3. Close the window.

### Step 2 — enter maskrom mode

The board has a tiny SMD button labelled `BOOT` on the silkscreen
(it's near the USB-C connector, opposite side from the camera FPC
connector). It's a momentary push-button. You'll need a paperclip,
pin or fine-tip tweezers because it's small.

1. **Unplug** the board completely.
2. With the board *unpowered*, press and **hold** the BOOT button.
3. *While still holding BOOT*, plug the USB-C cable into the PC.
4. Keep holding for **~3 seconds** after plug-in.
5. Release BOOT.

Windows should make its USB-connect chime. If you have Device Manager
open you'll see a new device appear under "Universal Serial Bus
controllers" or "Other devices" — it'll be called `Rockchip Device` /
`RKDevice` / `RK3xxx Loader Device` or similar. (Exact name varies with
driver version.)

### Step 3 — verify maskrom in SocToolKit

1. Run `SocToolKit.exe` (or RKDevTool) from the package you downloaded.
2. In the chip-select bar at the top, pick **RV1106** (the RV1103 on
   Mini B uses the same loader). If you don't see RV1106 / RV1103 in
   the dropdown, try RV1126 / RK3308 — the loader format is shared
   across this generation. RV1106 is the safest pick for Mini B.
3. Look at the device list in the main window. You should see one
   entry like `LDR-1` or `Maskrom-1` with status `Connected` or
   `Found Device`.

If no device appears here even though Device Manager sees it, the
driver tier is wrong — close SocToolKit, re-run `DriverInstall.exe`,
replug with BOOT held, retry.

### Step 4 — flash update.img

1. In SocToolKit, switch to the **Download Image** tab.
2. **Loader** field — click the `...` button and select `download.bin`
   from your factory image folder.
3. **Image** / **Firmware** field — click `...` and select
   `update.img` from the same folder.
4. Make sure the "all" / "全部" checkbox is ticked so SocToolKit
   flashes every partition (env, idblock, uboot, boot, oem,
   userdata, rootfs). If there are individual partition checkboxes
   per slot, leave them all ticked.
5. Click **Run** / **Download** / **Upgrade** (label varies by
   SocToolKit version — it's the green button that's not "Reset").
6. Watch the progress bar in the device row. Sequence is roughly:
   - "Download Boot" (~1 s) — the download.bin loader is sent
   - "Test Device" / "Read Capability" (~1 s) — board acknowledges
   - "Download Image" (~30-60 s) — actual flash
   - "Reset Device" — board reboots automatically when done
7. **Don't** unplug or reboot the PC during this. If something stalls
   for >2 minutes, see Troubleshooting below.

When SocToolKit reports success, the board should automatically
re-enumerate as the **stock RNDIS+ADB composite** (just like a fresh
out-of-box Mini B) within ~30 s.

### Step 5 — verify recovery

```powershell
adb devices
```

Expected:

```
List of devices attached
0123456789abcdef   device
```

(The serial is a placeholder — every board has its own.)

If you see this, **the board is recovered** at the firmware level.
Stock Luckfox firmware does not include this project's webcam daemon
or its configuration. From here:

1. [Build](building.md) `uvc_streamer`.
2. [Deploy](installing.md) the binary to `/oem/uvc_streamer` and reboot.
3. Restore the on-device files from
   [../board/README.md](../board/README.md) — at minimum `uvc_run.sh`,
   `start_3a.sh`, the `RkLunch.sh` hook for `start_3a.sh`, the modified
   `S50usbdevice` if you rely on this project's USB descriptor layout, and
   `/oem/.usb_config` if you rely on this project's USB function defaults.

Until those steps are done, the board may enumerate as stock
RNDIS+ADB rather than as a UVC camera. That is expected on factory
firmware.

**Never leave a backup copy of an init script inside `/etc/init.d/`.** BusyBox
`rcS` runs everything matching `S??*`, so `S50usbdevice.bak` is not a backup —
it is a second init script that runs at every boot. On this board that meant two
`uvc_streamer` processes started, the second failing with
`uvc subscribe ...: Device or resource busy`, both writing over the same
`/tmp/uvc.log` so the log came from whichever lost, and stale frame descriptors
from the old script appearing alongside the current ones in configfs. Keep
backups somewhere off the init path — `/oem/backup/` for instance. See
[board/README.md](../board/README.md#init-script-backups).

---

## UART console setup — prerequisite for Methods B and C

The UART debug serial console is the most reliable way to see what
the board is doing when USB is being weird. It's wired straight to
the SoC, doesn't depend on any USB stack or kernel driver inside the
board, and starts working from the moment U-Boot prints its first
line. If your board is stuck before USB enumerates (or if USB is
unstable under load), this is the path.

### Hardware you need

- **A USB-to-UART adapter at 3.3 V logic.** Any modest adapter works —
  this Mini B firmware build outputs the debug console at **115200
  baud, 8N1, 3.3 V TTL** (verified empirically on this hardware; some
  other Luckfox firmware variants use 1500000, so if 115200 gives
  garbage characters try 1500000 next). Common adapter chips:
  - **CH340G/N** (cheapest, common on Aliexpress dongles labelled
    "USB-TTL CH340"). Win10/11 picks up the driver automatically; if
    not, install
    [CH340 driver](http://www.wch-ic.com/downloads/CH341SER_EXE.html).
  - **CP2102 / CP2104** (Silicon Labs). Excellent. Win10/11 picks it up.
  - **FT232R / FT232H** (FTDI). Best signal integrity. Costs more.
  - **PL2303** — avoid on Win10+, the official driver dropped support
    for older revisions and many cheap dongles ship the unsupported
    rev. It works on Linux/Mac but on Windows you'll fight Code 10
    errors.

  **3.3 V logic is mandatory.** Adapters that only output 5 V TTL
  will damage the SoC. Most modern adapters either auto-detect the
  level from a VCCIO pin or have a 3.3 V / 5 V jumper — check yours
  is set to 3.3 V before connecting.

- **3 jumper wires** (female-female) to connect the adapter to the
  board's header pins.

### Wiring — Mini B debug UART pinout

The debug console (FIQ TTY in U-Boot, `console=ttyFIQ0` in the kernel)
lives on these pins of the Mini B header (from the Luckfox-Pico-Mini-B
pin diagram):

| Mini B header | Pad name | Direction | Wire to USB-UART adapter |
|---------------|----------|-----------|--------------------------|
| GPIO1_B2      | TX (FIQtty_TX) | Board → PC | adapter **RX** |
| GPIO1_B3      | RX (FIQtty_RX) | PC → Board | adapter **TX** |
| GND (any)     | Ground   | shared      | adapter **GND** |

**Cross the TX/RX lines.** The board's TX is the PC's RX, and vice
versa. This catches almost every first-timer.

**Do NOT connect the USB-UART adapter's VCC / 3.3 V / 5 V pin to the
board.** The board is still powered from its own USB-C connector.
Cross-feeding power from two USB sources is a good way to brown out
both.

Physical pin positions on the Mini B header (looking at the board with
USB-C at top, camera FPC at bottom — pins are numbered from the
USB-C end):

```
                    Luckfox Pico Mini B
                          + USB +
       VBUS  ──┤ pin 1            pin 2 ├──  1V8
        GND  ──┤ pin 3            pin 4 ├──  GND      ← adapter GND
        3V3  ──┤ pin 5            pin 6 ├──  GPIO4_C1
   GPIO1_B2  ──┤ pin 7  ←TX       pin 8 ├──  GPIO4_C0   ← adapter RX (board TX)
   GPIO1_B3  ──┤ pin 9  ←RX      pin 10 ├──  GPIO0_A4   ← adapter TX (board RX)
   GPIO1_C0  ──┤ pin 11           pin 12├──  GPIO1_C7
   ...
```

(Pin numbers depend on which silkscreen you're reading; the *pad
names* GPIO1_B2 / GPIO1_B3 / GND are the source of truth. Match by name,
not by counting positions.)

### Software — terminal emulator

Use any serial terminal. PuTTY, Tera Term, and picocom are common
choices; all support 115200 trivially.

**PuTTY (Windows):**

1. Connection type → **Serial**.
2. Serial line — the COM port your USB-UART adapter appears as (find
   it in Device Manager → Ports (COM & LPT); something like
   `USB-SERIAL CH340 (COM5)`).
3. Speed — `115200`. 8 data bits, no parity, 1 stop bit, no flow
   control.
4. Open the session. The terminal is blank until the board boots.
5. Replug the board (USB-C). Within a second you should see U-Boot's
   boot log streaming in.

**Tera Term (Windows):** Setup → Serial port. Pick the COM port, set
baud to `115200`, 8N1, no flow control.

**picocom / minicom (Linux/WSL):**

```bash
picocom -b 115200 /dev/ttyUSB0
```

WSL2 needs `usbipd-win` to expose the COM port; a native Linux box
is easier.

If you get a blank screen or only garbage at 115200, try `1500000`
instead — different firmware builds use either.

### First contact — entering U-Boot

With the terminal open at **115200 baud** and the board powered off:

1. Plug in USB-C. The board boots.
2. Within ~1 second of seeing U-Boot's first log line ("U-Boot
   2017.09 ..."), **press any key** in the terminal repeatedly. The
   countdown timer aborts and you drop to the U-Boot prompt:
   ```
   =>
   ```
3. From this prompt you can read NAND, load files from SD, write
   partitions, and reset the board.

If the countdown completes before you can hit a key, U-Boot tries to
boot the kernel. On a healthy board the boot succeeds and you start
seeing kernel messages. On a board with corrupt rootfs/boot you'll
see an error and U-Boot retries — at which point another key press
should land you at the prompt.

---

## Method B — UART + U-Boot + SD-card recovery

Use when U-Boot loads (you can reach the `=>` prompt over UART) but
the kernel/rootfs/oem partition is broken. This avoids re-flashing
the bootloader region, so it is safer than Method A when the
bootloader is intact.

### Setup

1. Format a microSD card as **FAT32**.
2. Copy these files from your Luckfox Pico Mini B factory image package
   onto the SD root: `env.img`, `boot.img`, `oem.img`, `rootfs.img`,
   `userdata.img`. (You can include `idblock.img` and `uboot.img` too
   but only flash them if you're certain the bootloader is the cause —
   piecemeal writes to the bootloader region are the most common way to
   make recovery harder.)
3. Insert the SD card into the Mini B's microSD slot.
4. Set up the UART console per the **UART console setup** section
   above and reach the `=>` prompt.

### Sanity check the SD is visible to U-Boot

```
=> mmc list
=> mmc dev 1
=> fatls mmc 1
```

`mmc list` should show your card; `mmc dev 1` selects it; `fatls
mmc 1` lists the files at the SD root. If you don't see your `.img`
files, the SD wasn't mounted (FAT32 formatting issue, or the SD is
seated wrong).

### Flash the partitions you need

Run the commands from `sd_update.txt` in the factory image package —
but only the **blocks** for the partitions you want to recover. Each
block is a 4-line sequence: zero a RAM region, load the image into RAM,
erase the NAND area, write RAM to NAND.

Example — reflash just the rootfs (the heaviest partition, takes
~30 s):

```
=> mw.b ${ramdisk_addr_r} 0xff 0x3060000
=> fatload mmc 1 ${ramdisk_addr_r} rootfs.img
=> mtd erase spi-nand0 0x2900000 0x5500000
=> mtd write spi-nand0 ${ramdisk_addr_r} 0x2900000 0x3060000
```

Example — reflash boot (kernel + DTB), oem, userdata, env:

```
=> mw.b ${ramdisk_addr_r} 0xff 0x40000
=> fatload mmc 1 ${ramdisk_addr_r} env.img
=> mtd erase spi-nand0 0x0 0x40000
=> mtd write spi-nand0 ${ramdisk_addr_r} 0x0 0x40000

=> mw.b ${ramdisk_addr_r} 0xff 0x301000
=> fatload mmc 1 ${ramdisk_addr_r} boot.img
=> mtd erase spi-nand0 0x100000 0x400000
=> mtd write spi-nand0 ${ramdisk_addr_r} 0x100000 0x301000

=> mw.b ${ramdisk_addr_r} 0xff 0xCE0000
=> fatload mmc 1 ${ramdisk_addr_r} oem.img
=> mtd erase spi-nand0 0x500000 0x1E00000
=> mtd write spi-nand0 ${ramdisk_addr_r} 0x500000 0xCE0000

=> mw.b ${ramdisk_addr_r} 0xff 0x1E0000
=> fatload mmc 1 ${ramdisk_addr_r} userdata.img
=> mtd erase spi-nand0 0x2300000 0x600000
=> mtd write spi-nand0 ${ramdisk_addr_r} 0x2300000 0x1E0000
```

When done, reboot:

```
=> reset
```

The board cycles through U-Boot again and (if the rootfs is good)
boots into Linux. Watch the UART for kernel messages — the boot tail
should end with `Welcome to Buildroot` followed by a login prompt
(or the USB enumeration messages if it goes straight to ADB
gadget).

After a partial reflash that restores a working OS, repeat the
webcam bring-up from Method A Step 5: [build](building.md),
[deploy](installing.md), and restore board files from
[../board/README.md](../board/README.md).

### What if `fatload` fails

```
** Bad device specification mmc 1 **
```

means U-Boot doesn't see the SD. Causes:
- SD inserted *after* boot — pull and reinsert with the board off,
  then reset.
- SD not FAT32 (some Macs default to ExFAT).
- SD genuinely dead.

Try `mmc rescan` first, then `mmc list`. If still nothing, take the
SD to a PC and verify the files are at the root in FAT32.

### What if `mtd write` reports errors

NAND bad blocks — the kernel and U-Boot normally route around them
with the BBT (bad-block table). If `mtd write` complains about a bad
block, just retry the same command — the second attempt usually
lands in a fresh page. If it consistently fails on the same address,
the NAND is wearing out and Method A (which uses the proper bad-block
aware flasher in SocToolKit) is your best option.

---

## Method C — UART for live diagnostics (no flashing)

Sometimes the board boots fine but the webcam daemon is misbehaving
and ADB keeps dropping out under load. The UART console is the right
tool — it gives you a shell that doesn't go away when USB does.

### Setup

Same hardware + terminal setup as the **UART console setup** section
above. Don't interrupt U-Boot — let it finish booting Linux. After
~10 s of kernel logs you'll see the Buildroot login prompt:

```
Welcome to Buildroot
luckfox login: root
Password:
#
```

Default credentials: **`root` / `luckfox`** (or no password — empty
press Enter — depending on firmware build).

### What you can do from here

This is a fully-functional shell on the device. Useful even when ADB
is fine, because it survives USB drops. Things to do:

```sh
# Watch kernel messages live (Ctrl-C to stop)
dmesg -w

# Watch the daemon log
tail -f /tmp/uvc.log

# Confirm the webcam stack is running
ps | grep -E 'uvc_streamer|rkaiq_3A_server'

# Reboot from the shell
reboot
```

**Do not `killall uvc_streamer` while the USB gadget is bound.** When
the daemon exits, the UVC function deactivates, a uevent re-runs
`S50usbdevice`, the USB Device Controller is rewritten, and the kernel
can panic in `ffs_func_unbind`. configfs wedges, a soft reboot hangs,
and the board needs a physical power cycle. See
[architecture.md](architecture.md#the-kernel-panic-you-must-not-trigger)
and [installing.md](installing.md) for the supported update path
(push to `/tmp`, `mv` over the running binary, reboot).

### Catching the moment a crash kills USB

If a process dies in a way that takes USB enumeration with it, the
UART console keeps printing kernel messages through the failure. Open
`dmesg -w` before reproducing the problem — OOM kills, driver faults,
and panics show up in real time, including the process name and
allocation size. That is often clearer than reconstructing from a
post-reboot `dmesg` after ADB has already dropped.

---

## Troubleshooting

### "BOOT held during plug-in but nothing enumerates"

- Try a different USB-C cable. Many cheap cables are charge-only.
- Try a different USB port. USB 2.0 ports on the back of a desktop
  tend to be the most reliable for low-level device work.
- Try holding BOOT longer (count to 5 with the cable plugged in).
- If still nothing on a known-good cable + port, the chip is likely
  hardware-dead. There's no software path to recover from that.

### "Device Manager shows 'Unknown Device'"

The Rockchip USB driver isn't installed. Run `DriverInstall.exe` as
Administrator, click "Driver Install", let it complete, then replug
with BOOT held.

### "SocToolKit doesn't see the device, but Device Manager does"

The driver may have installed for a different driver tier than
SocToolKit expects. Try:
- In Device Manager → right-click the Rockchip device → "Update
  driver" → "Search automatically" → let it pick the latest.
- Or uninstall the driver from Device Manager (right-click → Uninstall
  device), then re-run `DriverInstall.exe` and replug.

### "Download stalls partway through"

- Don't replug while the bar is still moving. Wait at least 2 minutes.
- If truly frozen: replug with BOOT held, restart SocToolKit, retry.
  An interrupted flash partway through is recoverable — just retry
  the same procedure. The maskrom doesn't care about previous state.

### "Flash succeeds but the board doesn't enumerate as ADB after"

Wait the full 30 s — first boot after a fresh flash takes longer
because the kernel does first-time initialisation (resize partitions,
generate SSH host keys, etc.). If after 60 s there's still no ADB:

- Check Device Manager — you should see the composite device.
- If you see "Unknown Device", the post-flash kernel may need the ADB
  driver — that's also installed by `DriverInstall.exe` (the ADB
  branch).

### "ADB shows the board as 'unauthorized'"

This shouldn't happen on the Luckfox build (ADB authentication is
disabled), but if it does:
- Click "Allow" in any "Allow USB debugging" prompt that appears on
  the board (it doesn't have a screen for that, so this won't apply
  here in practice).
- Run `adb kill-server; adb start-server; adb devices`.

### UART: "terminal is open but I see nothing when the board boots"

In rough order of how often each cause shows up:

1. **TX/RX swapped.** The most common first-timer mistake. Board TX
   goes to adapter RX, board RX goes to adapter TX. Swap and replug.
2. **GND not connected** or connected to a different ground (e.g. PC
   chassis but board on a separate isolated supply). Hook adapter GND
   to one of the board's GND pins, even if everything is on the same
   PC.
3. **Wrong baud rate.** This firmware build uses **115200 baud** —
   try that first. If you see garbage or a blank screen at 115200,
   the firmware on your board may be configured for **1500000**
   instead (some Luckfox builds default to it). Try both before
   blaming wiring.
4. **Adapter set to 5 V instead of 3.3 V.** At 5 V you may still see
   garbled output but you're slowly damaging the SoC. Verify with a
   multimeter on the adapter's TX line — should sit at ~3.3 V idle.
5. **Wrong COM port.** Device Manager → Ports — make sure the COM
   number in your terminal matches the adapter that's actually plugged
   in. If you have multiple USB-serial adapters, unplug the others
   while debugging.
6. **Bad jumper wires.** Especially the cheap dupont wires that
   sometimes lose contact when bent. Wiggle them; if the boot log
   appears intermittently it's the wires.
7. **Adapter doesn't reach the high baud setting.** Only relevant if
   your firmware actually uses 1500000 — some PL2303 clones cap below
   that. If 1500000 gives nothing, drop to 115200 and try again; the
   board's bootloader may print there too.

### UART: "I see boot log but typing in the terminal does nothing"

- Check terminal is set to "no flow control" (not RTS/CTS).
- Check you're hitting Enter after each U-Boot command (CR or CR+LF
  both work in U-Boot; some terminals send only LF which U-Boot
  ignores).
- If U-Boot has finished booting into Linux, login first (`root` /
  `luckfox` — see Method C). Before login, only a few characters
  produce visible output.

### UART: "garbled characters / random bytes"

Almost always a baud-rate mismatch. Try **115200 8N1** first; if that
gives garbage too, try **1500000 8N1**. No flow control either way.
If your terminal gives weird results at 1500000, switch to PuTTY ≥
0.74 (older PuTTY caps the custom-baud field).

---

## What NOT to do — the kill list

These are the operations that **will brick the board further** or
make recovery harder:

- **Don't flash `idblock.img`, `uboot.img`, or `download.bin`
  individually unless you understand the partition layout and
  consequences.** This is the most common way these boards end up
  here. Always use `update.img` (the combined image) — it places
  these correctly and atomically.
- **Don't `killall uvc_streamer` while the USB gadget is bound.** See
  [architecture.md](architecture.md#the-kernel-panic-you-must-not-trigger).
- **Don't unplug during a flash.** Even if it looks stuck, wait 2
  minutes before doing anything.
- **Don't power-cycle during a flash.**
- **Don't run multiple flashers at once.** SocToolKit + RKDevTool
  fighting over the same device will corrupt the flash.
- **Don't try to "fix" individual partitions** unless you're certain
  what you're doing. The full `update.img` reflash is almost always
  safer than guessing.

---

## Appendix — SPI NAND partition layout (for reference)

This table lists the **raw NAND partition regions** that U-Boot `mtd`
commands target. Useful if you need to compute offsets manually for a
partial recovery. The **usable UBI volume sizes** on a running board
(as `df` reports them) are smaller — see
[hardware.md](hardware.md#board--luckfox-pico-mini-b).

| Partition | Offset (NAND) | Size | Image |
|-----------|---------------|------|-------|
| env       | 0x000000     | 256 KB | `env.img` |
| idblock   | 0x040000     | 256 KB | `idblock.img` — bootloader region; don't touch |
| uboot     | 0x080000     | 512 KB | `uboot.img` — bootloader region; don't touch |
| boot      | 0x100000     | 4 MB  | `boot.img` (kernel + DTB FIT image) |
| oem       | 0x500000     | 30 MB | `oem.img` (vendor binaries: rkipc, librknnmrt, etc.) |
| userdata  | 0x2300000    | 6 MB  | `userdata.img` (the writable `/userdata` mount) |
| rootfs    | 0x2900000    | 85 MB | `rootfs.img` (Buildroot rootfs, `/`) |
| (free)    | 0x7E00000    | ~12 MB| unused tail |

Total NAND: 128 MB. Partitions sum to ~116 MB; the ~12 MB tail is
unused free space.
