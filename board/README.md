# Board files

The `board/` directory holds copies of files that live **on the device**, kept
under version control so they are reviewable and restorable. They are not used
at build time — they document and back up the runtime configuration of a
working webcam image.

These copies came from one specific board and firmware build. Diff them against
your device before overwriting anything; do not assume they match yours.

## Files

| Repo path | Device path | What it is |
|-----------|-------------|------------|
| `uvc_run.sh` | `/oem/uvc_run.sh` | One-line wrapper that execs the daemon with output to `/tmp/uvc.log` |
| `start_3a.sh` | `/oem/usr/bin/start_3a.sh` | Waits for `/dev/video11` to appear, then execs `rkaiq_3A_server`. Hooked as the last line of `/oem/usr/bin/RkLunch.sh` |
| `init.d/S50usbdevice` | `/etc/init.d/S50usbdevice` | Builds the USB gadget through configfs at every boot. This copy is modified from the vendor original: RNDIS disabled, UVC descriptors trimmed to MJPEG at 640×360, 1280×720, 1920×1080, and 2304×1296 |
| `usb_config` | `/oem/.usb_config` | Vendor config file. It can only turn functions **on**; the defaults live in the init script |

### Why `start_3a.sh` exists

Sensor modules load asynchronously in a background `post_chk &` inside
`RkLunch.sh`, so `/dev/video11` is not there when the script's main body runs.
Anything that depends on the ISP must wait for the node rather than assume it
is already present. That is what `start_3a.sh` does. The full startup sequence
is in [architecture.md](../docs/architecture.md#startup).

### How the daemon is launched

`S50usbdevice` starts the wrapper with:

```sh
start-stop-daemon --start --quiet --background --exec /oem/uvc_run.sh
```

The daemon therefore comes up with the USB gadget. See
[installing.md](../docs/installing.md#autostart).

### USB descriptors and `.usb_config`

At every boot, `S50usbdevice` builds the composite gadget through configfs.
`/oem/.usb_config` can turn functions **on**, but defaults live in the init
script itself. To disable a function that the script enables by default, edit
`S50usbdevice` directly. Why MJPEG only and why RNDIS is off are explained in
[architecture.md](../docs/architecture.md#advertised-formats).

### Init script backups

**Never leave a backup copy of an init script inside `/etc/init.d/`.** BusyBox
`rcS` runs everything matching `S??*`, so `S50usbdevice.bak` is not a backup — it
is a second init script that runs at every boot. On this board that meant two
`uvc_streamer` processes started, the second failing with
`uvc subscribe ...: Device or resource busy`, both writing over the same
`/tmp/uvc.log` so the log came from whichever lost, and stale frame descriptors
from the old script appearing alongside the current ones in configfs. Keep
backups somewhere off the init path — `/oem/backup/` for instance.

## Restoring a file

1. Push the repo copy to the device path:

   ```powershell
   adb push board/uvc_run.sh /oem/uvc_run.sh
   ```

2. Mark it executable — `adb push` does not preserve the executable bit, which
   catches people out:

   ```powershell
   adb shell "chmod +x /oem/uvc_run.sh"
   ```

3. Reboot:

   ```powershell
   adb shell reboot
   ```

Adjust the paths for whichever file you are restoring. For `S50usbdevice`,
push to `/etc/init.d/S50usbdevice` and `chmod +x` that path.

Before overwriting `S50usbdevice`, copy the current script somewhere **outside**
`/etc/init.d/`:

```powershell
adb shell "mkdir -p /oem/backup && cp /etc/init.d/S50usbdevice /oem/backup/S50usbdevice"
```

Deploying a new `uvc_streamer` binary without touching these files is covered
in [installing.md](../docs/installing.md#deploying-a-new-binary) and
`scripts/deploy.ps1` / `scripts/deploy.sh`.

## Checking your board against these copies

These are copies from one specific board and firmware build. Before overwriting
anything, compare rather than assume:

```bash
adb shell "md5sum /oem/uvc_run.sh /oem/usr/bin/start_3a.sh /etc/init.d/S50usbdevice /oem/.usb_config"
```

and compare against the repository copies. All four in this directory were last
verified byte-identical to a running board on 2026-08-26.

## Related

- [hardware.md](../docs/hardware.md) — board and camera physical reference
- [architecture.md](../docs/architecture.md) — startup sequence and the kernel panic to avoid
- [installing.md](../docs/installing.md) — deploying binaries and verification
