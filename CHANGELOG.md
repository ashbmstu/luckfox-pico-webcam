# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-27

### Added

- Hardware MJPEG encoding via the Rockchip MPI VI-to-VENC kernel bind: 1080p at
  25 fps with no dropped frames, and no frame encoded on the CPU at any point.
  The USB descriptors advertise MJPEG and nothing else.
- Measurement tooling under `tools/measure/`, documented in
  [docs/measuring.md](docs/measuring.md). Most read what the control loop
  decided rather than looking at the picture, so they stay meaningful in an
  unlit room and can run unattended overnight.
  - `ae-probe.ps1` logs the sensor's exposure and gain over time.
  - `ae-cycle.ps1` tests whether repeated stream open/close cycles degrade
    anything.
  - `pipeline-probe.ps1` samples sensor, ISP, daemon and thermal state together,
    closing the blind spot that a sensor-only probe cannot see past: a fault in
    the ISP would darken the picture while every sensor register sat still.
  - `boot-time.ps1` measures reboot to a selectable camera from the host side,
    including the bootloader phase that neither `dmesg` nor a host-side poll can
    see on its own.
  - `luma-probe.ps1` measures the brightness of the picture itself and records
    it beside the sensor and ISP state that produced it, which is what
    distinguishes a scene that got darker from a fault downstream of the
    sensor. Its `-Analyse` mode re-measures existing images and needs no
    camera.
  - `stream-probe.ps1` measures brightness frame by frame from a stream that
    keeps running, and optionally restarts the stream between samples. Every
    still from `luma-probe.ps1` reopens the sensor stream, so on its own it
    cannot separate a fault that develops *during* a session from one decided
    *when the session opens*. This tool can, and it reads frames straight off a
    SampleGrabber, so it also never touches the Windows still-capture path.
- **Identified why the picture is noisier in some sessions than others.**
  Diffing all of `/proc/rkisp-vir0` between a clean session and a noisy one,
  exactly one block of 35 differs: `BAY3D`, the Bayer-domain temporal denoiser,
  which the kernel sometimes refuses to start with `no bay3d buffer available`.
  Clearing the kernel ring before each stream and reading it back after gave 12
  agreements out of 12 between that message and the denoiser being off. Which
  way it lands is decided when the stream opens and holds for the session — a
  stream left running is stable to 2.2% and its black floor never moves — so
  reopening the application re-rolls it. It changes noise and not exposure:
  across those same 12 builds, with the denoiser on five times and off seven,
  mean luminance stayed flat at about 53 either way. Recorded as
  [WP7](docs/roadmap.md#wp7--bay3d-denoiser-fails-to-start), with a user-facing
  entry in [docs/troubleshooting.md](docs/troubleshooting.md) and the
  measurements in [docs/measuring.md](docs/measuring.md).

- **Identified why the picture goes dark after a few reconnections, and
  documented it as a known issue.** The ISP stops applying its output gamma
  curve after about four rebuilds of the capture pipeline, and stays that way
  until the board is power cycled. Mid-grey lands near 17 of 255 instead of near
  74 while highlights barely move, which is the signature of a missing tone
  curve rather than an exposure change; measured across 18 builds, `GAMMA_OUT`
  and the luminance split agree with no overlap. It is driven by build count and
  not by uptime — two watches on fresh boots failed at 222 s / build 4 and 112 s
  / build 5, while 12 stream cycles reusing one pipeline held gamma throughout —
  so an idle board stays good for hours while four camera open/closes break it.
  Each rebuild re-runs the vendor 3A initialisation, which never returns
  everything it allocates. The defect is in a closed vendor library and is not
  fixed here: unplugging and replugging the camera is the workaround. Recorded
  as
  [WP8](docs/roadmap.md#wp8--isp-gamma-curve-lost-after-about-four-pipeline-builds),
  including two approaches that wedge the board and should not be repeated, with
  a user-facing entry in
  [docs/troubleshooting.md](docs/troubleshooting.md#picture-goes-dark-after-a-few-reconnections).
- `pipeline-probe.ps1` records the ISP fields that can change image brightness
  with no sensor register moving — colour space matrix and range, output gamma,
  lens shading, black level, optical black, dehaze, colour correction — plus a
  digest of every block's on/off state, board temperature, CPU clock, free
  memory, per-process resident size and open descriptor counts.
- `docs/hardware.md` gained the full SC3336 gain ladder and instructions for
  reading sensor registers directly.
- `board/` documents the on-device files, with a way to check them against your
  own board.
- Deployment scripts under `scripts/`.
- CI checks that Markdown links resolve to real files and that heading anchors
  resolve.
- `tools/test/check-modes.py`, run by CI, checks that the daemon's frame table
  and the board's USB frame descriptors describe the same resolutions in the
  same order. Nothing else connects those two files: the host sends a
  `bFrameIndex`, not a resolution, and that index means whatever position the
  descriptor was created in. When they drift, the daemon encodes one size while
  the host expects another — quiet enough that Media Foundation rescales it away
  and only DirectShow goes black, which is the shape of the DirectShow fault
  listed under Fixed below.
  The check also enforces that every mode is 16:9 and that the advertised frame
  interval matches the rate the encoder actually runs at. It needs no SDK, no
  board and no dependencies, which is now the only C-adjacent thing CI can do.

### Changed

- `docs/recovery.md` is now a field manual for this project rather than for the
  one it grew out of: maskrom and BOOT button procedure, UART wiring, U-Boot and
  `mtd` sequences, and a list of what not to do. Its dead links and references
  to files that no longer exist are gone.
- The roadmap records the WP0 baseline: 9.59 s from reboot to a selectable
  camera, of which 3.71 s is shutdown and bootloader, 5.63 s is the kernel to
  `USB_STATE=CONFIGURED`, and 0.25 s is host enumeration. The host is not the
  bottleneck.
- The roadmap documents enabling the watchdog as a one-line device-tree change,
  having traced why `/dev/watchdog` does not exist on a stock board.
- README states measured CPU and bitrate figures rather than "negligible" and a
  single bitrate number, since MJPEG bitrate is a property of the scene.
- The build works for someone who is not the author: SDK paths are parameters
  rather than hardcoded.

- **Every USB resolution is now 16:9, and 2304×1296 is offered.** The ladder is
  640×360, 1280×720, 1920×1080 and 2304×1296, each measured at 25 fps with no
  encoder starvation, at roughly 4.7, 12.3, 26.8 and 31.8 Mbit/s on one ordinary
  lit indoor scene. 2304×1296 is the sensor's native readout, so at that size
  nothing in the path scales at all; the rest are ISP downscales of that same
  full frame.

  640×480 is gone. It was the only 4:3 entry, and a 4:3 frame cannot show a 16:9
  sensor field without either cropping the sides away — which changes the angle
  when the host changes resolution — or squeezing the whole field into a
  narrower frame. The old entry did the second, and stretched the picture
  vertically by 4/3.

  The field of view is now identical at every resolution, which was measured
  rather than assumed. A still from each mode was matched against the 2304×1296
  frame across a sweep of crop scales; the best match sits at 1.00 for all four,
  while the same sweep applied to a deliberately 95% cropped reference correctly
  recovers 0.95. The test can therefore see a crop far smaller than any of these
  modes show.

- **The descriptors advertise 25 fps and nothing else.** They previously offered
  30, 15, 10 and 5 fps as well, none of which the daemon honoured, so the host
  displayed a frame rate it never received.

- **A stream the hardware cannot encode is refused rather than degraded.** The
  daemon logs `RK MPI VENC start failed for 1920x1080 - refusing the stream`, or
  the equivalent for a failed prefill or queue, and starts nothing. Handing a
  host a broken stream produces a camera that enumerates, reports healthy, and
  shows black, which is far harder to diagnose than a clean refusal.

### Removed

- **The software JPEG encoder**, together with the V4L2 capture layer that fed
  it and the `-c` option that pointed at it. It reached 4 to 5 fps at 1080p, and
  running it saturated the CPU badly enough to starve the USB isochronous pump,
  which tore frames. A fallback that delivers torn video at a fifth of the frame
  rate is not a degraded camera but a broken one, and having it there made
  faults harder to diagnose rather than easier: a board with a real hardware
  problem still produced a picture, so the problem looked like something else.

- **The field-of-view crop, and `/oem/uvc.conf` with it.** The daemon now reads
  no configuration file at all. The crop was a digital zoom rather than a
  distortion fix: the ISP crops *after* the sensor has been scaled down, so it
  cost real resolution — high-frequency detail fell to 0.74× at matched field
  and matched pixel count — and it could not undo barrel distortion, which is a
  property of the lens and not of the framing. Someone choosing a resolution in
  a video call does not expect the angle to change, so the full 98.3° field is
  now always what you get.

- **The `skipped` counter** from the daemon's periodic line, which now reads
  `streaming: 25.0 fps, 26681 kbps, 0 timeouts`. It was only ever incremented by
  the software drain, so on the hardware path it was a structural zero: a
  constant being quoted as evidence of health, including by this project's own
  documentation.

- **The `/tmp/inject.jpg` test hook**, which replaced every encoded frame with
  the contents of that file. It earned its place while diagnosing the DirectShow
  black-picture fault, but a file dropped in `/tmp` that silently substitutes
  the entire video stream is a surprising thing for a camera other people run to
  do. The one-shot `/tmp/venc-first.jpg` dump is kept, and now documented,
  because it only observes.

### Fixed

- **Black picture in DirectShow applications.** Windows sends a 26-byte UVC 1.0
  probe/commit control, and the daemon had required the 34-byte UVC 1.1 form, so
  every commit was silently dropped and the device always streamed its default
  1080p regardless of what the host asked for.

- **The board could wedge after enough stream starts, needing a physical power
  cycle.** Both USB functions would stop at once — no ADB, no video — while the
  host still listed every interface as healthy. It looked like a fault in
  2304×1296, or in Media Foundation, or in restarting the stream; it was none of
  those. Each of them merely got there faster.

  The pipeline was built on every `STREAMON` and destroyed on every `STREAMOFF`,
  and at 2304×1296 that pipeline is most of this board's 24576 kB CMA region.
  After enough build-and-destroy cycles CMA fragments badly enough that a
  contiguous allocation cannot be found:

  ```
  cma: cma_alloc: rk-dma-heap-cma: alloc failed, req-size: 729 pages, ret: -12
  ```

  The vendor `mpp_vcodec` module then starts the encoder on the channel it has
  just failed to create, dereferences it, and oopses inside `vcodec_ioctl` —
  killing the daemon while the USB gadget is bound, which is the same fatal
  condition as `killall uvc_streamer`. UVC and ADB die together because they are
  two functions of one composite gadget.

  Three changes. The pipeline is now **paused rather than destroyed** when a host
  stops, and reused when the next host asks for the same size, so a burst of
  restarts allocates once instead of once per stream — Media Foundation alone
  restarts three times for a single photograph. It is released on a resolution
  change, or after five seconds idle, so an unused camera does not sit with the
  sensor running. The VI buffer pool went from three NV12 frames to two, which
  returns one 4374 kB frame. The result measures 18336 kB at peak, leaving
  6240 kB of headroom; the third buffer would have put that peak just under the
  region's ceiling. Frame rate is unaffected: 25.0 fps with 0 timeouts at every
  mode.

  Measured, not assumed. Earlier builds wedged after 48, 72 and 93 stream
  cycles; this one ran 144 with no allocation failure and no oops. Note that
  `MemAvailable` is useless for watching this — it sits flat at 10.7 MB straight
  through a wedge. `CmaAllocated` in `/proc/meminfo` is the figure that moves.
  (`CmaFree` reads 0 always on this kernel.)

- **A failed stream start could leave the encoder running and the UVC queue
  half-filled.** `stream_start` filled each buffer in turn and returned on the
  first failure without stopping the encoder it had already started, and
  `stream_stop` returned early whenever the stream had never reached the
  streaming state, so it did not stop it either. A half-filled queue cannot be
  recovered without tearing the encoder down. Both paths now unwind completely.

- **`timeouts` was documented as a USB timeout.** It counts polls where the
  encoder had no frame ready within 100 ms — the sensor, ISP or encoder side
  starving. Nothing about it involves USB, so the figure was being read as
  evidence of the wrong thing.

- **A backup copy of an init script must not be left in `/etc/init.d/`**, which
  is now documented. BusyBox `rcS` runs everything matching `S??*`, so
  `S50usbdevice.bak` is not a backup but a second init script that runs at every
  boot. On the development board that started a second `uvc_streamer`; it failed
  with `uvc subscribe ...: Device or resource busy`, both processes wrote over
  the same `/tmp/uvc.log`, so the log on disk came from whichever lost the race,
  and frame descriptors from the older script appeared in configfs beside the
  current ones.

- **`NOTICE` misattributed `ref/g_uvc.h`.** It was listed alongside the two
  Rockchip reference files as a Rockchip work, offered under the GPL-2-or-BSD
  dual licence and taken from `project/app/uvc_app_tiny/uvc_app/uvc/`. It is
  none of those things. It is the Linux kernel's UVC gadget userspace API
  header, copyright Laurent Pinchart, licensed GPL-2.0+ WITH Linux-syscall-note,
  and it comes from the SDK's kernel tree at
  `sysdrv/source/kernel/include/uapi/linux/usb/g_uvc.h` (Linux 5.10.160). The
  project's own licensing is unaffected — the daemon includes that header from
  the toolchain sysroot rather than from `ref/`, and the syscall-note exception
  exists precisely so userspace using kernel API headers is not made subject to
  the GPL — but the attribution was wrong and is now stated separately. While
  checking, `NOTICE`'s byte-identical claim for `ref/uvc-gadget.c` was verified
  against the SDK copy and holds; `ref/uvc-gadget.h` is byte-identical too.

- **The SC3336 gain calculation was wrong**, reporting values roughly 65 times
  too small. The gain registers are not a linear pair: total gain is the
  analogue code times the coarse digital code times the fine digital value over
  128, and each code maps through a table rather than its raw value. Historic
  logs remain recoverable because the raw register bytes were always kept.
- Every measurement script defaulted `-Adb` to a path inside a directory that
  is not published with the repository, so the documented default could never
  have worked for anyone who cloned it. They now default to `adb` on `PATH` and
  fail with an actionable message when it is missing.
- The CI heading-anchor check collected each file's slugs into a set, so
  repeated headings collapsed into one anchor. GitHub instead suffixes the
  second and later occurrences with `-1`, `-2`, so valid links to them were
  reported broken.
- The PSScriptAnalyzer CI job passed both directories to `-Path` in one call.
  That parameter is `[string]`, not `[string[]]`, so the job would have failed
  with a parameter binding error rather than a lint result.
- `pipeline-probe.ps1` captured only the first of the two values `AWBGAIN`
  reports per gain pair, discarding the one observed to move.
- `pipeline-probe.ps1` reported the daemon's `fps`, `kbps`, `skipped` and
  `timeouts` from the last matching line in a log that is only appended to while
  a host streams, so once the stream stopped it republished the same figures
  indefinitely. In one soak `kbps` sat at exactly 10094 for eighteen samples
  after the stream had already ended, which reads as a suspiciously steady
  bitrate rather than as no data. The line's boot-relative timestamp is now aged
  against `/proc/uptime`, published as `daemon_age_s`, and the statistics are
  left empty rather than stale.
- `deploy.sh` and `deploy.ps1` waited for the board to come back without first
  waiting for it to go down, so they could match the pre-reboot ADB daemon and
  report success immediately.
- `deploy.sh` guards against MSYS path rewriting, which silently rewrote the
  device path so the deployment went to the wrong place without failing.
- `ae-cycle.ps1` phase timing: the three sample points were sorted with
  `Sort-Object`, which cannot sort hashtables by key in PowerShell 5.1 and
  silently reordered them so all three fired at once.
- `boot-time.ps1` timed each wait from the end of the previous one rather than
  from a single origin, so later figures read as much smaller than they were.
- SECURITY.md overstated what the project does about the vendor services it
  ships with.
- The daemon's header comment referenced a file that does not exist; provenance
  is now recorded in NOTICE.

[0.1.0]: https://github.com/ashbmstu/luckfox-pico-webcam/releases/tag/v0.1.0
