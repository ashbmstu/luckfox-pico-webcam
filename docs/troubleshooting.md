# Troubleshooting

Symptom-first reference for the UVC webcam firmware. For deployment rules and
ADB pitfalls, read [installing.md](installing.md) first. For brick recovery, see
[recovery.md](recovery.md).

## Quick reference

| Symptom | Likely cause | Section |
|---------|--------------|---------|
| Nothing enumerates at all | Power-only USB cable; or daemon not running, so gadget stays soft-disconnected | [Nothing on USB](#nothing-on-usb) |
| Black picture with ticking frame counter in Zoom / OBS / e-CamView | Format negotiation mismatch — DirectShow decoder rejects frames larger than negotiated | [Black picture in DirectShow apps](#black-picture-in-directshow-apps) |
| Camera listed but no picture | Hardware encoder refused to start — daemon deliberately did not stream | [Encoder refused to start](#encoder-refused-to-start) |
| Works in Windows Camera but not Zoom | Different stacks (Media Foundation vs DirectShow) | [Works in Camera app but not Zoom](#works-in-camera-app-but-not-zoom) |
| Grey, black, or wrong colours | `rkaiq_3A_server` not running | [Wrong colours or grey picture](#wrong-colours-or-grey-picture) |
| Picture noisier in some sessions than others | ISP temporal denoiser `BAY3D` disabled at stream start — `no bay3d buffer available` | [Picture noise differs between sessions](#picture-noise-differs-between-sessions) |
| Picture suddenly much darker, midtones crushed, only a replug fixes it | ISP output gamma curve lost after about four pipeline rebuilds | [Picture goes dark after a few reconnections](#picture-goes-dark-after-a-few-reconnections) |
| Board stops responding after `killall uvc_streamer` | `ffs_func_unbind` kernel panic | [Board hung after killing daemon](#board-hung-after-killing-daemon) |
| ADB and video both stop at once, host still lists the device as healthy | CMA exhausted by rebuilding the encoder pipeline on every stream start | [Board stops responding mid-session](#board-stops-responding-mid-session) |
| `adb` succeeds but nothing changes on board | `adb` run from Git Bash / MSYS path rewriting | [ADB path rewriting](#adb-path-rewriting) |
| Board no longer boots at all | Corrupt flash or bootloader | [recovery.md](recovery.md) |

### Useful diagnostic commands

```powershell
adb shell "tail -20 /tmp/uvc.log"
```

```powershell
adb shell "dmesg | tail -50"
```

```powershell
adb shell "ps | grep -E '3A|uvc'"
```

```powershell
adb shell "grep 'fps,' /tmp/uvc.log | tail -3"
```

A healthy 1080p stream prints a statistics line every five seconds: **25 fps**,
zero timeouts.

---

## Nothing on USB

**Likely cause:** Power-only cable, or `uvc_streamer` not running so the gadget
never leaves soft-disconnect.

**Diagnose:**

```powershell
adb devices
```

If ADB sees the board, the USB data path works at least for the debug
interface. Check the daemon:

```powershell
adb shell "tail -30 /tmp/uvc.log"
```

```powershell
adb shell "ps | grep uvc"
```

**Fix:**

- Use a known **data** USB-C cable and try another port.
- If the log is empty or shows an early failure, redeploy the binary per
  [installing.md](installing.md) and reboot.
- If the log never reaches `gadget activated, waiting for host`, see
  [architecture.md](architecture.md#the-gadget-will-not-attach-until-userspace-subscribes).

Remember: the composite device does not enumerate to the host until userspace
subscribes to UVC events — a powered board with no camera in Device Manager is
not always a hardware fault.

---

## Black picture in DirectShow apps

**Likely cause:** UVC probe/commit negotiation mismatch. DirectShow's MJPEG
decompressor rejects frames whose JPEG dimensions exceed the negotiated size,
so you get a black preview with a frame counter that still ticks.

Current code accepts 26-byte UVC 1.0 commits (Windows sends 26, not 34). If you
see this on a **modified** build, suspect probe/commit handling in
`uvc_streamer.c`.

**Diagnose:**

```powershell
.\tools\test\dshow-test.ps1 -Width 1920 -Height 1080
```

Compare with Media Foundation:

```powershell
.\tools\test\capture-test.ps1
```

**Fix:** Use an unmodified build that includes the 26-byte commit fix (see
[architecture.md](architecture.md#uvc-negotiation-and-the-bug-that-hid-inside-it)).
If you are developing negotiation code, test **both** stacks before declaring
success.

---

## Works in Camera app but not Zoom

**Likely cause:** Windows Camera uses Media Foundation; Zoom uses DirectShow.
They negotiate and decode differently.

**Diagnose:** Run both harnesses from `tools/test/`:

```powershell
.\tools\test\capture-test.ps1
```

```powershell
.\tools\test\dshow-test.ps1
```

**Fix:** If MF passes and DirectShow fails, focus on UVC commit sizes and
advertised MJPEG dimensions — not on the sensor or encoder. If both fail, work
through [Nothing on USB](#nothing-on-usb) and
[Wrong colours or grey picture](#wrong-colours-or-grey-picture) first.

---

## Wrong colours or grey picture

**Likely cause:** `rkaiq_3A_server` is not running. Without the closed-loop 3A
binary, exposure and white balance do not update and the picture looks grey,
black, or wrong.

**Diagnose:**

```powershell
adb shell "ps | grep -E '3A|uvc'"
```

You should see `rkaiq_3A_server` alongside `uvc_streamer`.

**Fix:** Reboot the board and watch startup order in the log. The 3A server
waits for `/dev/video11` — if the ISP node never appears, fix sensor module
loading before suspecting the streamer. See
[architecture.md](architecture.md#startup).

---

## Encoder refused to start

**Likely cause:** The hardware encoder could not start, prefill a buffer, or
queue to the UVC gadget. The daemon **refuses the stream** rather than handing
the host a broken picture. Windows still lists the camera, but the preview stays
black — which is harder to diagnose than a clean refusal if you do not read the
log.

**Diagnose:**

```powershell
adb shell "grep -E 'refusing the stream|RK MPI' /tmp/uvc.log"
```

Typical lines:

```
RK MPI VENC start failed for 1920x1080 - refusing the stream
RK MPI prefill failed at buffer 0 - refusing the stream
uvc queue failed at buffer 0 - refusing the stream
```

```powershell
adb shell "dmesg | tail -50"
```

Pull the encoder's first-frame diagnostic — written once per daemon run, not
once per stream:

```powershell
adb pull /tmp/venc-first.jpg
```

That file shows what the encoder produced, independent of anything the host did
with the stream.

**Fix:** Determine why Rockit or the ISP was not ready (sensor modules not
loaded, `/dev/video11` missing, resource exhaustion). Reboot and retry. If the
failure persists after a clean boot, open a GitHub Issue with the log tail,
`dmesg`, and `venc-first.jpg` if present. See
[architecture.md](architecture.md#why-the-encoder-is-bound-in-the-kernel).

---

## Picture noise differs between sessions

**Symptom:** The picture looks noisier in some sessions than others, with
nothing changed in between. It stays that way for the whole session, and
reopening the app can change it back. Most obvious in a dim room.

If the picture is *dark* rather than noisy, this is the wrong section — see
[picture goes dark after a few reconnections](#picture-goes-dark-after-a-few-reconnections).

**Likely cause:** The ISP's Bayer-domain temporal denoiser, `BAY3D`, failed to
get its buffer when the stream started and was disabled for that stream. The
kernel logs it:

```
rkisp rkisp-vir0: no bay3d buffer available
```

The state is chosen when the stream opens and held until it closes, which is why
it never changes mid-session and why reopening the app can clear it.

**Which one is the fault:** the noisier one, which is `BAY3D` off. In a dim
room at high gain the denoiser is the difference between a clean image and one
whose black floor sits several levels off the bottom.

**It does not affect brightness.** An earlier version of this page said it did,
on the strength of a mean-luminance split measured in a dim room. That does not
reproduce: across 12 pipeline builds in which `BAY3D` came up ON five times and
OFF seven, mean luminance stayed flat at about 53 either way. The brightness
two-state effect that measurement was chasing is a different defect entirely —
see [picture goes dark after a few reconnections](#picture-goes-dark-after-a-few-reconnections).

**Diagnose:** while a host is streaming,

```powershell
adb shell "grep BAY3D /proc/rkisp-vir0"
```

`ON(0x…)` is the healthy state; `OFF(0x0 …)` means the denoiser is disabled for
this stream. Check `dmesg` for the message above.

**Workaround:** close the capturing application and reopen it. Each reopen
re-rolls the allocation, so it is a retry rather than a fix — in measured runs
the denoiser came up roughly one time in five, and repeating until `dmesg` stays
quiet is currently the only way to get the good state deliberately.

Two things that do **not** help, both tested: leaving a long idle gap between
sessions (45 s between streams gave the same failure rate as 6 s), and waiting
for free memory to recover — the allocation fails with several megabytes free.

This is a real defect rather than a configuration problem, and it is not yet
fixed in this project — see [WP7 in roadmap.md](roadmap.md#wp7--bay3d-denoiser-fails-to-start).
The measurements behind this entry, and the tool that produced them, are in
[measuring.md](measuring.md#stream-probeps1).

---

## Picture goes dark after a few reconnections

**Symptom:** The picture is correctly exposed after a power-up, then at some
point turns much darker and stays that way for as long as the camera remains
plugged in. Midtones and shadows are crushed while bright areas — a window, a
lamp — still look about right. Closing and reopening the application does not
help. Unplugging and replugging the camera restores it.

**Cause:** the ISP's output gamma curve, `GAMMA_OUT`, stops being programmed.
Without it the sensor's near-linear data reaches the host with no tone mapping,
so mid-grey lands near 17 of 255 instead of near 74.

It is not an exposure problem, and the percentiles are how you tell. Two
measurements fifteen minutes apart, same room, same daylight, same 2304×1296:

| | working | failed |
|---|---------|--------|
| p01 / p05 | 26 / 32 | 3 / 3 |
| p50 | 74 | 17 |
| p95 | 230 | 162 |
| mean | 85.5 | 35.8 |
| `GAMMA_OUT` | `ON(0xc0000005)` | `OFF(0x0)` |

Highlights fall by 30% while the median falls by 77% and the shadows collapse.
Less light, a shorter exposure or a gain change moves all of those together;
only a missing tone curve crushes the bottom and leaves the top roughly alone.

**What triggers it: about four rebuilds of the capture pipeline.** Not elapsed
time, not uptime, and not how long the camera has streamed. Two watches on fresh
boots, probing at different rates to separate the two, put the failure at uptime
222 s / build 4 and uptime 112 s / build 5 — the times differ by a factor of two,
the build counts do not. From the other side, 12 stream cycles that *reused* an
existing pipeline (2 builds total) held `GAMMA_OUT ON` throughout at mean
106–107.

A build happens when:

| Event | Rebuilds the pipeline? |
|-------|------------------------|
| First stream after power-up | yes |
| Host asks for a different resolution | yes |
| Camera unused longer than `VENC_IDLE_MS` (5 s), then reopened | yes |
| Host stops and restarts the stream within 5 s | no — pipeline reused |

The third row is why this shows up as "a few app open/closes". Each build
re-runs the vendor 3A initialisation — `RTIsp3x ... ispInitDevice` in the daemon
log — and something it allocates is not returned when the pipeline is torn down.
`MemAvailable` falls by roughly 100 kB per build until the gamma LUT can no
longer be programmed, then stops falling.

**Diagnose:** while a host is streaming,

```powershell
adb shell "grep GAMMA_OUT /proc/rkisp-vir0"
```

`ON(0x...)` is healthy; `OFF(0x0)` means the tone curve is gone. Count the
rebuilds so far with

```powershell
adb shell "grep -c 'start ok' /tmp/uvc.log"
```

**Workaround:** unplug and replug the camera; a reboot works too. Nothing short
of a power cycle resets it — in particular, closing the application does not,
because that is what causes it.

**Things that do not work, all measured:**

- *Rebuilding the pipeline again.* Twelve consecutive fresh builds all came up
  with `GAMMA_OUT OFF`. Unlike `BAY3D`, this is not a retryable dice roll: once
  it is gone it stays gone until the board is power-cycled.
- *Leaving `RK_MPI_VI_DisableDev` uncalled* so the VI device stays enabled.
  `ispInitDevice` still ran once per build and gamma still died on build 4, so
  the 3A cycle is driven by the VI **channel**, not the device.
- *`RK_MPI_VI_PauseChn` / `ResumeChn` instead of disabling the channel.* Pausing
  works and silences the `jpeg overflow` noise completely, but the stream never
  recovers on resume — the first frame grab returns nothing, the next graph
  cannot start, and the board wedges as in
  [board stops responding mid-session](#board-stops-responding-mid-session),
  needing a physical replug. Do not repeat this one.

**Not a leak in this daemon.** Across seven builds the daemon's own resources
were flat: file descriptors 24 then 25, threads 3, `VmRSS` 1992 then 2020 kB.
The resource that runs out is inside the vendor stack, and `ispInitDevice` lives
in `librockit.so`, which ships without source — so the cycle cannot be patched
here, only made to happen less often.

This is a real defect and is not fixed — see
[WP8 in roadmap.md](roadmap.md#wp8--isp-gamma-curve-lost-after-about-four-pipeline-builds).

---

## Board hung after killing daemon

**Likely cause:** `killall uvc_streamer` (or any abrupt exit) while the USB
gadget is bound triggers `ffs_func_unbind` panic, wedges configfs, and breaks
soft reboot.

**Diagnose:** Board unresponsive over ADB; subsequent `adb shell reboot` may
hang.

**Fix:** **Physical power cycle** — unplug USB, wait a few seconds, plug back
in. Prevention: always deploy with push → `mv` → `reboot` as described in
[installing.md](installing.md). Never kill the daemon on a live gadget.

---

## Board stops responding mid-session

**Symptom:** Video stops and `adb devices` goes empty at the same moment, while
Windows still shows every interface with `Status=OK`. `adb kill-server` does not
help. Only a physical power cycle recovers it.

**Likely cause:** CMA exhaustion. UVC and ADB are two functions of one composite
gadget, so a daemon killed in the kernel takes both down while the device stays
enumerated — the host has no idea anything is wrong.

This should not happen on current firmware, which builds the encoder pipeline
once and reuses it across stream restarts. If you see it, something is
allocating from CMA that did not used to:

```powershell
adb shell "grep -E 'CmaAllocated|CmaReleased|CmaTotal' /proc/meminfo"
```

`CmaAllocated` is the figure to watch. It falls below 100 kB once the pipeline
has been released, and peaks at 18336 kB of 24576 kB under a hard soak of
restarts across all four modes; a single sustained 2304×1296 stream holds 11760
kB. `MemAvailable` tells you nothing here — it stays flat at around 10.7 MB
straight through a failure — and `CmaFree` reads 0 on this kernel whatever is
happening.

**Diagnose:** the kernel says so plainly, if you catch it. The ring only holds a
few seconds, so clear it first and read it while the failure is happening:

```powershell
adb shell "dmesg -c > /dev/null"
```

```powershell
adb shell "dmesg | grep -E 'cma_alloc|Internal error|VCODEC_CHAN_CREATE'"
```

A line like `cma: cma_alloc: rk-dma-heap-cma: alloc failed, req-size: 729 pages,
ret: -12` is the allocation failing. The oops that follows it is in the vendor
`mpp_vcodec` module, which starts the encoder on a channel it just failed to
create; it cannot be caught from userspace, which is why the daemon avoids
reaching it rather than handling it.

**Fix:** Physical power cycle. Then check what changed: raising the VI buffer
count in `vi_chn_init`, raising `u32BufSize` above `w*h`, or shortening
`VENC_IDLE_MS` so the pipeline is torn down between restarts will each bring it
back.

**Not a fix:** unbinding VI from VENC while the pipeline is paused. It silences
the `jpeg overflow` messages below, but the matching `RK_MPI_SYS_Bind` on the
next resume never returns and the board hangs on the first restart.

---

## Harmless `jpeg overflow` messages in dmesg

**Symptom:** `dmesg` fills with, once per frame:

```
rkvenc_540c: jpeg overflow
hal_jpege_v540c:hal_jpege_vepu540c_status_check:480: JPEG BIT_STREAM_OVERFLOW
mpp_vcodec: 305: enc 0 handle int err
```

**Cause:** expected, and harmless. Between streams the encoder is stopped but
still bound to VI, so VI offers it a frame every 40 ms and the hardware rejects
each one. It costs nothing measurable — 144 stream cycles ran through it at 25.0
fps with 0 timeouts — and the alternative, unbinding while paused, hangs the
board on the next restart.

Despite the name it is not a buffer-size problem. `u32BufSize` must stay at
`w*h`: the VEPU sizes its requirement from the pixel count rather than from what
it actually emits, so halving it raises real overflows on ordinary 250 kB
frames.

---

## ADB path rewriting

**Likely cause:** Commands run from Git Bash or another MSYS environment, which
rewrites `/oem` and `/tmp` to Windows paths.

**Diagnose:** You used Git Bash. Commands returned success but
`adb shell "cat /oem/uvc_streamer"` on a **PowerShell** session shows the old
file or missing changes.

**Fix:** Repeat all `adb` commands from **PowerShell** or Command Prompt. See
[installing.md](installing.md#run-adb-from-powershell-not-git-bash).

---

## Board no longer boots

This is outside normal daemon troubleshooting. Follow
[recovery.md](recovery.md) — maskrom and SocToolKit for a full reflash, or UART
methods if U-Boot still runs.

---

## Getting help

If you open an issue, include enough context to reproduce the problem:

| Information | Example |
|-------------|---------|
| Host OS and application | Windows 11, Zoom 6.x |
| Resolution and format | 1920×1080 MJPEG |
| Daemon log | Output of `adb shell "tail -50 /tmp/uvc.log"` while the fault occurs |
| Kernel tail | Output of `adb shell "dmesg | tail -50"` |
| Which test harnesses pass or fail | `capture-test.ps1`, `dshow-test.ps1`, etc. |

Do not paste secrets or credentials. For build problems, say which SDK path and
toolchain you used — see [building.md](building.md).

## Related

- [installing.md](installing.md) — correct deploy procedure
- [configuration.md](configuration.md) — build-time settings and diagnostics
- [architecture.md](architecture.md) — design constraints and startup order
- [recovery.md](recovery.md) — unbootable board
