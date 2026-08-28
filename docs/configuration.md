# Configuration

The daemon has **no runtime configuration**. It reads no file on the board at
stream start or at boot. Field-of-view cropping via `/oem/uvc.conf` was removed:
it was a digital zoom that cost real resolution and could not correct barrel
distortion. See [architecture.md](architecture.md#field-of-view).

What you can still change lives in the source tree or on fixed paths on the
board. Every change needs a **rebuild and redeploy** of `uvc_streamer`, except
edits to `board/init.d/S50usbdevice`, which need a **reboot** after you push
the script. Follow [installing.md](installing.md) rather than repeating the
deploy steps here.

## Resolutions

The host picks a mode by **`bFrameIndex`**, not by sending a width and height.
That index is the position of the mode in the USB descriptor table built at
boot. The daemon maps the same index to encoder dimensions in
`mjpeg_frame_dims()` in `src/streamer/uvc_streamer.c`. Nothing else connects
those two files — if they drift apart the daemon encodes one size while the
host expects another, and the failure is quiet.

To add, remove, or reorder modes, edit **both**:

1. The `configure_uvc_resolution_mjpeg` calls in
   `board/init.d/S50usbdevice` — this sets what the host sees in the gadget
   descriptors.
2. `mjpeg_frame_dims()` in `src/streamer/uvc_streamer.c` — this sets what the
   encoder actually produces for each index.

**Creation order is descriptor order is `bFrameIndex` order.** The first
`configure_uvc_resolution_mjpeg` call is index 1, the second is index 2, and so
on.

Every mode should stay **16:9**. The SC3336 readout is 2304×1296. A 4:3 frame
cannot show the full sensor field without either cropping the sides away —
which changes the angle when the host changes resolution — or squeezing the
full field into a narrower frame. Neither matches what someone picking a
resolution in a video call expects.

CI runs `tools/test/check-modes.py`, which verifies that the two files agree,
that every mode is 16:9, and that the advertised frame interval matches
`DEFAULT_FPS`. Run it locally with:

```bash
python3 tools/test/check-modes.py
```

It needs no SDK or other dependencies.

The stock layout is four modes: 640×360, 1280×720, 1920×1080, and 2304×1296
(native sensor readout). At 2304×1296 nothing in the path scales; the other
three are ISP downscales of that same full frame. The field of view is
identical at every resolution.

## Frame rate

Frame rate is fixed at **25 fps**, matching the sensor mode.

| Location | What to set |
|----------|-------------|
| `DEFAULT_FPS` in `src/streamer/uvc_streamer.c` | Daemon expectation |
| `dwFrameInterval` and `dwDefaultFrameInterval` in `board/init.d/S50usbdevice` | Descriptor values in 100 ns units: **10000000 / fps** (400000 for 25 fps) |

Those values must agree. The descriptors advertise only this interval — not 30,
15, 10, or 5 fps.

## JPEG quality

`JPEG_Q_FACTOR` in `src/streamer/rkmpi_venc.c` is currently **80**. Higher
values produce larger frames, and the USB isochronous budget is the ceiling to
stay under: at the gadget's default `streaming_maxpacket` of 1024 bytes per
microframe, high-speed USB carries 1024 x 8000/s, or about **65 Mbit/s**. For
scale, 2304x1296 at 25 fps measured about 32 Mbit/s on an ordinary lit indoor
scene, and MJPEG bitrate moves a lot with scene detail.

`S50usbdevice` carries a commented-out line that would raise `streaming_maxpacket`
to 3072. It is left commented as the vendor shipped it and has not been tested
here.

## USB functions exposed

`/oem/.usb_config` can turn composite-device functions **on**. Defaults live in
`board/init.d/S50usbdevice`. To disable a function the script enables by
default, edit the init script directly. The repo copy is
[board/usb_config](../board/usb_config).

## Daemon log location

`/oem/uvc_run.sh` execs the daemon and redirects output to **`/tmp/uvc.log`**.
Edit the wrapper if you need a different path.

## Encoder diagnostic frame

On each daemon run — once per process start, not once per stream — the daemon
writes the first encoded frame to **`/tmp/venc-first.jpg`**. It shows what the
hardware encoder produced, independent of anything the host did with the stream.
Useful in a bug report:

```powershell
adb pull /tmp/venc-first.jpg
```

## What is not configurable

| Setting | Fixed value | Why |
|---------|-------------|-----|
| Field of view | **98.3° diagonal**, same at every resolution | Full lens field; cropping was removed. See [architecture.md](architecture.md#field-of-view). |
| Pixel format | **MJPEG 4:2:0** | Hardware encoder path is YUV420SP in, MJPEG out. Uncompressed formats are not offered. |
| Lens distortion correction | Not available | Would need ISP LDCH with a full AIQ context and a mesh for this lens. See [architecture.md](architecture.md#field-of-view). |
| Software JPEG fallback | None | If the hardware encoder cannot start, the daemon refuses the stream. See [troubleshooting.md](troubleshooting.md). |

## Related

- [installing.md](installing.md) — deploy and verify the daemon
- [troubleshooting.md](troubleshooting.md) — picture problems and log interpretation
- [architecture.md](architecture.md) — pipeline and advertised formats
- [building.md](building.md) — cross-compile the daemon
