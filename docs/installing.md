# Installing

How to get a built `uvc_streamer` onto a Luckfox Pico Mini B and have it start
at boot. You need a binary from [building.md](building.md) and the Android
platform tools (`adb`) on your PC.

Build-time settings — resolutions, frame rate, JPEG quality — are in
[configuration.md](configuration.md). If something goes wrong, see
[troubleshooting.md](troubleshooting.md).

## Connecting to the board

Plug the Mini B into your PC with a USB-C **data** cable. A power-only cable
charges the board but does not enumerate on USB — this wastes a lot of time and
is the first thing to rule out when nothing appears.

ADB is the transport. On Windows, `adb.exe` ships with the [Android platform
tools](https://developer.android.com/tools/releases/platform-tools); you supply
your own copy and add it to your `PATH`, or call it by full path.

Check the board is visible:

```powershell
adb devices
```

You should see a serial number in the `device` state. If the list is empty,
try another cable or USB port before changing software.

## Run ADB from PowerShell, not Git Bash

On Windows, **always run `adb` from PowerShell or Command Prompt**, never from
Git Bash or other MSYS shells.

MSYS rewrites Unix-style paths such as `/oem` and `/tmp` into Windows paths.
Commands then appear to succeed while touching the wrong location on disk. This
is a genuine trap — if you have pushed files and nothing changed on the board,
check which shell you used.

## Deploying a new binary

> **Warning — read this before updating the daemon**
>
> **Never `killall uvc_streamer` while the USB gadget is bound.**
>
> When the daemon exits, the UVC function deactivates. That triggers a uevent
> which re-runs `/etc/init.d/S50usbdevice`, rewrites the USB Device Controller,
> and can panic the kernel in `ffs_func_unbind`. configfs then wedges, a soft
> reboot hangs, and the board needs a **physical power cycle**.
>
> The supported update path is: push to `/tmp`, make executable, **rename over**
> the running binary (safe on Linux while the process is still mapped), then
> reboot. Do not stop the daemon first.

From the directory that contains your built `uvc_streamer`:

```powershell
adb push uvc_streamer /tmp/uvc_streamer
```

```powershell
adb shell "chmod +x /tmp/uvc_streamer && mv /tmp/uvc_streamer /oem/uvc_streamer"
```

```powershell
adb shell reboot
```

After reboot, wait for the board to come back and run `adb devices` again before
testing.

## First install from stock firmware

The steps above assume the board already has `/oem/uvc_streamer`, `/oem/uvc_run.sh`,
the modified `S50usbdevice` in `/etc/init.d/`, and the `RkLunch.sh` hook for
`start_3a.sh`. A board on stock Luckfox firmware does not. From a working ADB
session on stock Buildroot, provision in this order:

1. **Build** `uvc_streamer` on a Linux host — see [building.md](building.md).
2. **Push the daemon** — same sequence as [Deploying a new binary](#deploying-a-new-binary):
   push to `/tmp`, `chmod +x`, `mv` to `/oem/uvc_streamer`.
3. **Push the run wrapper** from this repository:

   ```powershell
   adb push board/uvc_run.sh /oem/uvc_run.sh
   adb shell "chmod +x /oem/uvc_run.sh"
   ```

4. **Push the 3A launcher** and make it executable:

   ```powershell
   adb push board/start_3a.sh /oem/usr/bin/start_3a.sh
   adb shell "chmod +x /oem/usr/bin/start_3a.sh"
   ```

5. **Hook `start_3a.sh` in `RkLunch.sh`.** Sensor modules load asynchronously in
   a background `post_chk &`, so `/dev/video11` is not there when the main body
   of `RkLunch.sh` runs. The hook must be the **last line** of
   `/oem/usr/bin/RkLunch.sh`:

   ```sh
   /oem/usr/bin/start_3a.sh &
   ```

   If that line is missing, append it. Verify with:

   ```powershell
   adb shell "tail -3 /oem/usr/bin/RkLunch.sh"
   ```

6. **Push the USB gadget init script** — this project's MJPEG descriptor layout
   and daemon autostart:

   ```powershell
   adb push board/init.d/S50usbdevice /etc/init.d/S50usbdevice
   adb shell "chmod +x /etc/init.d/S50usbdevice"
   ```

   **Never leave a backup copy of an init script inside `/etc/init.d/`.** BusyBox
   `rcS` runs everything matching `S??*`, so `S50usbdevice.bak` is not a backup
   — it is a second init script that runs at every boot. Keep backups off the init
   path, for example `/oem/backup/`.

7. **Push USB function defaults** if you rely on this project's layout:

   ```powershell
   adb push board/usb_config /oem/.usb_config
   ```

8. **Reboot** and verify per [Verifying](#verifying) below.

Repo copies of these files and what each does are in
[board/README.md](../board/README.md).

## Autostart

`/oem/uvc_run.sh` is a one-line wrapper invoked when the USB gadget is set up.
It execs the daemon and redirects all output to `/tmp/uvc.log`:

```sh
#!/bin/sh
exec /oem/uvc_streamer >/tmp/uvc.log 2>&1
```

It is launched from `S50usbdevice` with
`start-stop-daemon --start --quiet --background --exec /oem/uvc_run.sh`, so the
daemon comes up with the gadget. You do not run it by hand during normal
updates. See [architecture.md](architecture.md) for
the full startup sequence.

## USB descriptors

At every boot, `/etc/init.d/S50usbdevice` builds the USB gadget through
configfs. This project's configuration trims the composite device to **MJPEG
only** at 640×360, 1280×720, 1920×1080, and 2304×1296, and disables RNDIS.

`/oem/.usb_config` can turn functions **on**, but defaults live in the init
script itself. To disable a function that the script enables by default, edit
`S50usbdevice` directly. Before changing it, copy the current script somewhere
**outside** `/etc/init.d/` — for example `/oem/backup/S50usbdevice` — never as
`S50usbdevice.bak` in the init directory itself.

Why MJPEG only and why RNDIS is off are explained in
[architecture.md](architecture.md#advertised-formats).

## Verifying

### Daemon log

After the board has booted and you have opened a camera application on the host
(or waited a few seconds for the daemon to start), check the log:

```powershell
adb shell "tail /tmp/uvc.log"
```

You should see a line naming the camera and UVC device nodes, then:

`gadget activated, waiting for host`

When a host starts streaming, the log also prints encoder choice and periodic
statistics (see [troubleshooting.md](troubleshooting.md)).

### Host-side capture tests

The device enumerates as **UVC Camera**. Other webcams (for example virtual
cameras) may appear earlier in the device list, so the test scripts select by
name rather than by index.

From PowerShell, in `tools/test/`:

| Script | What it does |
|--------|----------------|
| `capture-test.ps1` | Media Foundation (`MediaCapture`). Captures three frames with pauses for auto-exposure. Defaults to 1920×1080; pass `-Width` and `-Height` for any other advertised mode. Saves `uvc-<width>x<height>.jpg`. |
| `dshow-test.ps1` | Builds a real DirectShow preview graph — the path Zoom, OBS (DirectShow), and e-CamView use. Parameters: `-Width`, `-Height`, `-Seconds` (default 5), `-NoScreenshot` to skip the screen capture. Use `-Width 640 -Height 360` or `-Width 2304 -Height 1296` for the other advertised modes. Saves `dshow-preview.png` by default. |

Example:

```powershell
.\capture-test.ps1
```

```powershell
.\dshow-test.ps1 -Width 1920 -Height 1080 -Seconds 10
```

Test **both** Media Foundation and DirectShow if you care about compatibility
with different applications — they negotiate UVC differently. See
[architecture.md](architecture.md#uvc-negotiation-and-the-bug-that-hid-inside-it).

## First boot — nothing on USB?

Nothing enumerates until `uvc_streamer` subscribes to UVC events on the gadget
node. A board that draws power and shows no USB device usually means the daemon
is not running yet, or failed before activation — not necessarily broken
hardware.

See [architecture.md](architecture.md#the-gadget-will-not-attach-until-userspace-subscribes)
for why the vendor stack is designed this way, and
[troubleshooting.md](troubleshooting.md) if the log never reaches
`gadget activated`.

## Related

- [building.md](building.md) — compile the daemon
- [configuration.md](configuration.md) — build-time settings
- [recovery.md](recovery.md) — if the board no longer boots
