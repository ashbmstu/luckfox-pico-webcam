# Measuring

Scripts for observing what the camera pipeline is doing **without looking at the
picture**. The 3A server (`rkaiq_3A_server`) drives auto-exposure by writing
registers on the SC3336 sensor over I²C, and the ISP reports its own state
through `/proc/rkisp-vir0`. Reading those back tells you what the control loop
decided, independently of what the camera is pointed at or how bright the room
is. A measurement can run unattended overnight in an unlit room and still be
meaningful.

For how the pipeline fits together, see [architecture.md](architecture.md). For
the sensor register map and gain decoding, see
[hardware.md](hardware.md#reading-sensor-registers-directly).

## Sensor and ISP are separate layers

The sensor and the ISP are not the same thing. Auto-exposure runs on the sensor:
exposure and gain registers at `0x3e00` and `0x3e06`–`0x3e09` reflect what the
3A server last wrote. Downstream, the ISP applies its own white balance, gain
and tone mapping. A fault in the ISP could darken the image while the sensor's
registers sat perfectly still.

| Script | What it sees | Reach for it when… |
|--------|-------------|-------------------|
| `ae-probe.ps1` | Sensor only | You care about auto-exposure drift on the sensor, with no host streaming |
| `pipeline-probe.ps1` | Sensor, ISP and daemon | You need the full picture — including whether the ISP and streamer are healthy |
| `ae-cycle.ps1` | Sensor, sampled around DirectShow open/close cycles | You suspect the AE working point shifts across repeated stream sessions |
| `luma-probe.ps1` | The picture itself, next to the sensor and ISP state that produced it | You need to know whether the image actually got darker, not just whether the control loop moved |
| `stream-probe.ps1` | The picture itself, frame by frame, from a stream that keeps running | You need to tell a fault that develops *during* a stream from one decided *when the stream opens* |
| `boot-time.ps1` | Host-visible enumeration timing | You need time from reboot to a selectable camera |
| `dshow-test.ps1` | A real DirectShow capture graph on Windows | You need to hold a stream open (used by `ae-cycle.ps1`; also tests the DirectShow path) |

The daemon and ISP figures from `pipeline-probe.ps1` are only meaningful while a
host is streaming. With no stream the pipeline is idle and the sensor registers
simply hold whatever they were last left at. Reading sensor and ISP state over
ADB does not interfere with an existing stream.

Shared sensor decoding lives in `tools/measure/ae-common.ps1` and shared ISP
decoding in `tools/measure/isp-common.ps1`, both dot-sourced by the probe
scripts.

## Requirements

- **Windows PowerShell 5.1**
- **ADB** — all scripts default to `adb` on `PATH`. Pass `-Adb` with a full
  path if yours is installed somewhere the shell cannot find.
- **DirectShow** — required for `dshow-test.ps1` and `ae-cycle.ps1`, which
  open a capture graph on a Windows host

The camera is an exclusive resource: only one capture application can hold the
stream at a time. Two of these scripts cannot run concurrently if both need the
stream. Reading sensor and ISP state over ADB is safe while something else is
streaming.

---

## ae-probe.ps1

**Question it answers:** What is auto-exposure doing on the sensor over time?

Samples exposure and gain registers through ADB at a fixed interval and appends
to a CSV. Because it reads the control loop's own decisions rather than judging
the picture, it works in a completely dark room.

### Running it

```powershell
.\tools\measure\ae-probe.ps1 -Seconds 28800 -Interval 30 -Csv .\ae-log.csv
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-Seconds` | `0` | Total run time; `0` runs until interrupted |
| `-Interval` | `30` | Seconds between samples |
| `-Csv` | `tools\measure\ae-log.csv` | Output file; header written on first create |
| `-Adb` | `adb` | Path to `adb`, or a bare name to find on `PATH` |

### Output columns

| Column | Meaning |
|--------|---------|
| `time` | Local timestamp on the host (`yyyy-MM-dd HH:mm:ss`) |
| `uptime_s` | Board uptime in seconds (`/proc/uptime`) |
| `exp_lines` | Exposure in whole lines (20-bit value from `0x3e00`–`0x3e02`, in 1/16-line units internally) |
| `dgain` | Coarse and fine digital gain registers as hex (`0x3e06`, `0x3e07`) |
| `again` | Analogue gain register as hex (`0x3e09`) |
| `gain_x` | Total gain multiplier after decoding the gain ladder |
| `raw` | Raw hex bytes from the exposure and gain reads |

### Interpreting results

A stable fault-free run shows `exp_lines` and `gain_x` holding a consistent
working point, or moving slowly in response to a changing scene. Sudden step
changes or a steady drift over hours point at the control loop rather than the
USB path. Failed samples print `sample failed (board offline?)` and are skipped.

For sensor-only checks with no host involved, this is the lightest tool.

---

## pipeline-probe.ps1

**Question it answers:** Are the sensor, ISP and daemon all healthy together?

This is the most complete probe. Each sample is one ADB round trip that reads:

1. **Sensor** — exposure and gain registers (same decoding as `ae-probe.ps1`)
2. **ISP** — `/proc/rkisp-vir0`
3. **Daemon** — the last statistics line from `/tmp/uvc.log` matching `fps,`

Everything is read-only. Like `ae-probe.ps1`, it is valid in a dark room — but
the ISP and daemon columns only carry meaning while a host is actively
streaming.

### Running it

Start a stream on the host (for example with `dshow-test.ps1` or any camera
application), then:

```powershell
.\tools\measure\pipeline-probe.ps1 -Seconds 28800 -Interval 60 -Csv .\pipeline-log.csv
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-Seconds` | `0` | Total run time; `0` runs until interrupted |
| `-Interval` | `60` | Seconds between samples |
| `-Csv` | `tools\measure\pipeline-log.csv` | Output file; header written on first create |
| `-Adb` | `adb` | Path to `adb`, or a bare name to find on `PATH` |

### Output columns — sensor

Same as `ae-probe.ps1`: `time`, `uptime_s`, `exp_lines`, `dgain`, `again`,
`gain_x`, plus `raw_gain` (the raw hex exposure and gain bytes).

### Output columns — ISP

Parsed from `/proc/rkisp-vir0`:

| Column | Source in proc output | Meaning |
|--------|----------------------|---------|
| `awb_gain0` | `AWBGAIN` line, first `gain0:` value | White balance gain channel 0, as reported in force by the ISP |
| `awb_gain0b` | second `gain0:` value | The pair's second value |
| `awb_gain1` | first `gain1:` value | White balance gain channel 1 |
| `awb_gain1b` | second `gain1:` value | The pair's second value, and the only one observed to move on a settled board |
| `isp_gain` | `GAIN` line | ISP gain block state |
| `isp_drc` | `HDRDRC` line | ISP dynamic-range / tone-mapping block state |
| `isp_cproc` | `CPROC` line | ISP colour-processing block state |
| `isp_csm` | `CSM` line | Colour space matrix, including range. `FULL` versus `LIMITED` changes image brightness on its own |
| `isp_gamma` | `GAMMA_OUT` line | Output gamma block state |
| `isp_lsc` | `LSC` line | Lens shading correction state |
| `isp_bls` | `BLS` line | Black level subtraction state |
| `isp_ob` | `OB` line | Optical black state |
| `isp_dhaz` | `DHAZ` line | Dehaze block state |
| `isp_ccm` | `CCM` line | Colour correction matrix state |
| `isp_blocks` | every block's on/off state | Short digest, so a block with no column of its own still shows a change |
| `isp_frame` | `Isp online frame:` counter | Frames the ISP has processed; **must advance between samples** while streaming — this is how you know the pipeline is actually running |
| `isp_err` | `ErrCnt:` | ISP error counter; should be **zero** |
| `frameloss` | `frameloss:` | Frames lost inside the ISP; should be **zero** |
| `soc_temp_c` | `thermal_zone0` | SoC temperature in °C |
| `cpu_mhz` | `scaling_cur_freq` | Current CPU clock in MHz |

`AWBGAIN` reports two values per gain pair. Both halves are logged because only
the second half of `gain1` was observed to move on a settled board, so recording
the first value alone hides the field that changes.

`isp_blocks` digests block **names and states only**, never the values in
parentheses. Several blocks, `CCM` and `HDRDRC` among them, toggle bit 30 of
that value from frame to frame as a "config updated" flag. Digesting the raw
lines produces a value that changes on nearly every sample and means nothing.
Note that `isp_drc` and `isp_ccm` are logged raw, so they show that toggle:
treat a change confined to bit 30 as noise.

The white balance gains and the frame-loss counter are the fields most likely
to move if the fault is downstream of the sensor.

### Output columns — daemon

Parsed from the last line in `/tmp/uvc.log` that contains `fps,`, for example
`streaming: 25.0 fps, 24252 kbps, 0 timeouts`:

| Column | Meaning |
|--------|---------|
| `fps` | Reported frame rate |
| `kbps` | Reported bitrate |
| `timeouts` | Polls where the encoder had no frame ready within 100 ms — sensor, ISP or encoder starvation; not USB timeouts |

Memory and descriptor counts come from `/proc`:

| Column | Meaning |
|--------|---------|
| `mem_free_kb` | `MemFree` from `/proc/meminfo` |
| `mem_avail_kb` | `MemAvailable` from `/proc/meminfo` |
| `rss_3a_kb` | Resident set size of `rkaiq_3A_server` |
| `rss_daemon_kb` | Resident set size of `uvc_streamer` |
| `fd_3a`, `fd_daemon` | Open file descriptors for each |

These matter more on this board than the numbers suggest. It has about 33 MB
usable and roughly 2 MB genuinely free while streaming, so a slow leak in either
process is a plausible mechanism for a fault that only shows after hours. A
descriptor count that climbs steadily is the other classic long-run failure, and
costs nothing to watch.

One further column, `raw_gain`, holds the four gain register bytes exactly as
they came off the sensor. It exists so that a reading can be re-derived if the
decoding is ever found to be wrong — which has already happened once, and made
every historic row in an overnight log recoverable rather than worthless.

The daemon prints this line every five seconds while streaming.

### Interpreting results

A healthy streaming session looks like:

- `isp_frame` increasing on every sample
- `isp_err` and `frameloss` at zero
- `soc_temp_c` climbing then levelling off, which is normal; a fault that only
  appears once the board is warm presents as a fault that appears "over time",
  so it is worth being able to separate the two
- `fps` near 25 and `timeouts` at zero
- Sensor `exp_lines` and `gain_x` stable or slowly tracking the scene

If the sensor registers are steady but the ISP columns shift while the image
darkens — `awb_gain1b`, `isp_csm`, `isp_gamma`, `isp_gain` or a changed
`isp_blocks` digest — the fault is likely in
the ISP path — invisible to `ae-probe.ps1` alone. Empty ISP or daemon columns
usually mean no host is streaming.

---

## luma-probe.ps1

**Question it answers:** Has the picture got darker, and did the sensor ask for
that?

Every other script here reads the control loop and never looks at the picture.
That makes them work in an unlit room, but it leaves one question unanswerable.
A fault downstream of the sensor — the colour space matrix flipping from full to
limited range, output gamma changing, black level drifting — darkens the image
with every sensor register sitting still, and `ae-probe.ps1` would report a
perfectly healthy camera throughout.

This script captures stills, measures the luminance of each one, and reads the
sensor and ISP at the same moment, so the two can be compared row by row:

| Luma | Gain | Reading |
|------|------|---------|
| steady | steady | Nothing is happening |
| falls | rises | The scene got darker; AE is compensating |
| steady | rises | The scene got darker; AE is keeping up |
| **falls** | **steady** | **The fault is downstream of the sensor** |

The last row is the one worth catching, and the one no other script here can
see. When it happens, sort the CSV by `mean` and look for an ISP column that
splits the same way brightness does — that names the block.

### Running it

```powershell
.\tools\measure\luma-probe.ps1 -Shots 60 -GapSec 60 -DiscardImages
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-Shots` | `30` | Number of stills to capture |
| `-GapSec` | `10` | Seconds between shots; `Shots × GapSec` is the run length |
| `-Width` / `-Height` | `1920` / `1080` | MJPEG mode to request |
| `-DiscardImages` | off | Delete each JPEG once measured, keeping only the numbers |
| `-OutDir` | timestamped directory | Where images and the CSV go |
| `-Csv` | `luma.csv` inside `-OutDir` | Output file |
| `-Adb` | `adb` | Path to `adb`, or a bare name to find on `PATH` |
| `-Analyse` | — | Measure existing image files instead of capturing |

`-Analyse` takes paths or wildcards and touches no camera, so it is safe to run
while something else is streaming:

```powershell
.\tools\measure\luma-probe.ps1 -Analyse .\run\*.jpg -Csv .\redo.csv
```

Without `-Analyse` the script needs the camera, which is an exclusive resource:
it will fail if another application holds the stream, including this project's
own soak tests. A missing `adb` is not fatal — the luminance measurement still
stands, it just loses the columns saying what the camera was doing.

### Output columns — image

| Column | Meaning |
|--------|---------|
| `mean` | Mean luminance over the whole frame, 0–255 |
| `centre_mean` | Mean luminance of the centre half, roughly what AE meters |
| `stddev` | Standard deviation of luminance; contrast, loosely |
| `p05`, `p50`, `p95` | Luminance percentiles |
| `black_pct`, `clipped_pct` | Percentage of pixels at exactly 0 and exactly 255 |
| `bytes` | JPEG size; scene-dependent, not a brightness measure |
| `note` | `empty file`, `capture failed` or `unreadable` where a shot did not work |

The percentiles earn their place: a fault that crushes the shadows moves `p05`
while barely touching the mean, and one that clips highlights moves `p95` and
`clipped_pct`. A mean alone would miss both.

`mean` and `centre_mean` diverging is worth attention in itself. On a healthy
frame of a static scene they agree closely; a frame with a corrupt region was
caught during development by its whole-frame mean sitting 58% above its centre
mean, where every healthy frame in the same set agreed within 8%.

Luminance is Rec.601 (`0.299R + 0.587G + 0.114B`), computed from a full-
resolution histogram rather than a downsample, so the percentiles are exact.
The implementation was cross-checked against an independent one using Python's
Pillow over fourteen frames: the means agreed to within 0.019 of 255, and every
percentile matched exactly.

### Output columns — sensor and ISP

`exp_lines`, `again` and `gain_x` are as in
[ae-probe.ps1](#output-columns), read immediately after the shutter. The
`isp_*` columns and `awb_gain1b` are as in
[pipeline-probe.ps1](#output-columns--isp).

These are read while the stream that capture opened is still up. A moment later
`/proc/rkisp-vir0` returns its idle stub and every ISP field would be empty.

### Interpreting results

**Expect a wide spread, and do not read a single shot as a trend.** Each
`CapturePhotoToStorageFileAsync` call starts and stops the sensor stream even
within one session, so auto-exposure re-converges for every shot.

Measurements taken during development show this concretely. Across fourteen
captures of one static scene, with the sensor's exposure and gain registers
bit-identical every time (1215 lines, 510.72×), mean luminance did not scatter
— it landed in **two separate clusters**, at 7.58 and 12.30, a ratio of 1.62×.
The largest gap between sorted values was wider than either cluster's entire
spread; a single unimodal population produces a gap that extreme with
probability 0.0008. The same two levels appeared again in a separate capture
session.

So the brightness of a still sits in one of two states, chosen afresh for each
shot, while the sensor is bit-identical. Each shot here is also a fresh stream,
and [stream-probe.ps1](#stream-probeps1) later showed that the stream restart is
what re-rolls it: hold one stream open and the picture is stable.

Comparing the two states pixel by pixel narrows what can be responsible. Taking
matched quantiles of the dark and bright frames — which cancels the scene, since
it is the same static scene either way — the transfer between them is **not a
simple gain change**:

| Model | Best fit | RMS error, levels |
|-------|----------|------------------:|
| Pure gain | `y = 1.535 x` | 1.592 |
| Pure offset | `y = x + 4.720` | 0.686 |
| Power law | `y = 3.252 x^0.669` | 0.547 |
| **Affine** | **`y = 1.156 x + 3.539`** | **0.375** |

The additive term is the point. It is not an artefact of fitting over a narrow
range: it is directly visible in the frames without fitting at all. The first
percentile of luminance is exactly 3 in every one of the five dark frames and
exactly 6 in every one of the eight bright frames. Fitting all forty dark ×
bright pairs individually gives an intercept of +3.54 (sd 0.41), positive in
forty pairs out of forty.

A purely multiplicative change cannot move a black floor — and exposure, sensor
gain and ISP digital gain are all multiplicative. So whatever differs between
the two states **adds a pedestal**, and the ~1.6× ratio in the mean is mostly
that pedestal rather than gain.

**The block was subsequently identified as `BAY3D`**, the Bayer-domain temporal
denoiser, by dumping all of `/proc/rkisp-vir0` in both states and diffing: it is
the only block of 35 that differs. The pedestal is clipped shadow noise that the
denoiser removes when it is enabled, which is why it adds rather than scales.
The evidence and the kernel message behind it are under
[stream-probe.ps1](#interpreting-results-3).

Note that this made the *brighter* state the faulty one — the opposite of the
reading a brightness measurement invites. None of the named `isp_*` columns
above ever split with the two states; only the `isp_blocks` digest did, which is
the reason that digest covers every block rather than a chosen few.

**This is not the fault that makes the picture look dark.** The split measured
here is a pedestal of about three and a half levels, on a scene whose mean is
under 13 — which is the only reason it reads as a 1.6× ratio. The same pedestal
is invisible in a lit room. What a user notices as a dark picture is a separate
defect with a different signature: the ISP's output gamma curve goes missing
after about four rebuilds of the capture pipeline, crushing midtones while
barely touching highlights, and stays missing until the board is power cycled.
See [picture goes dark after a few
reconnections](troubleshooting.md#picture-goes-dark-after-a-few-reconnections).

---

## stream-probe.ps1

`luma-probe.ps1` measures stills, and every still it takes restarts the sensor
stream — `CapturePhotoToStorageFileAsync` does that even inside a single
session. That confounds two faults which need completely different fixes:

- brightness wanders **while a stream is running**
- brightness is decided **when a stream opens**, then held until it closes

`stream-probe.ps1` separates them. It builds one DirectShow graph, taps it with
a SampleGrabber, and reads raw RGB24 frames while the graph stays in Run state,
so nothing restarts between samples. Pass `-Restart` and it tears the graph down
and rebuilds it for every sample instead, reintroducing exactly one variable and
nothing else.

Taking frames straight off the graph also means it never touches the Windows
still-capture path, which makes it the control for "is this the board or the
host?".

### Running it

```powershell
# Sixty frames from one uninterrupted stream
.\tools\measure\stream-probe.ps1 -Samples 60 -GapSec 3 -Csv .\continuous.csv

# Twenty frames, each from its own freshly opened stream
.\tools\measure\stream-probe.ps1 -Samples 20 -Restart -SettleSec 5 -GapSec 8 -Csv .\restart.csv
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-Samples` | 60 | How many frames to record |
| `-GapSec` | 3 | Seconds between samples |
| `-Restart` | off | Rebuild the capture graph before every sample |
| `-SettleSec` | 5 | With `-Restart`, seconds of streaming before grabbing. Auto-exposure needs a moment after a restart; too short and you measure the ramp |
| `-Width`, `-Height` | 1920, 1080 | Capture format to pin |
| `-Camera` | `UVC Camera` | Substring of the device's friendly name |
| `-Csv` | `stream-log.csv` | Output file |
| `-Adb` | `adb` | Used only to record ISP state beside each frame |

The camera is exclusive — nothing else may hold it while this runs.

**Keep restart cycles slow.** Opening and closing the stream every few seconds
wedges the board's MPP channel (`mpp_chan: ctx is no found in chan server` in
`dmesg`, alongside `rkisp-vir0: waiting on params stream off event timeout`),
after which frames stop arriving until the rate drops. The fault is rate
dependent and clears on its own; a total cycle of about 15 s has been stable.

### Output columns

`time`, `sample`, `w`, `h`, then the image measurements `mean`, `stddev`,
`p01`, `p05`, `p50`, `p95` — the same integer Rec.601 luma `luma-probe.ps1`
uses, so the numbers are comparable between the two tools. No display or colour
transform is applied, so they are *not* comparable to a JPEG opened in another
application.

The ISP columns (`isp_gain`, `isp_drc`, `isp_cproc`, `isp_csm`, `isp_gamma`,
`isp_lsc`, `isp_bls`, `isp_ob`, `isp_blocks`, `isp_frame`) are read at the same
moment as the frame and decode exactly as in
[pipeline-probe.ps1](#output-columns--isp).

### Interpreting results

**Brightness is decided when the stream opens, not while it runs.** Two runs
minutes apart, same scene, same decode path, differing only in whether the
stream restarted:

| Run | Samples | Result |
|-----|--------:|--------|
| One continuous graph | 60 over 3 min | mean 15.286, sd 0.336 (2.2%); `p01` fixed at 7–8 and `p05` at 9 in every frame |
| `-Restart` each sample | 18 | two clusters: **8.300** (n=4) and **16.666** (n=14), ratio **2.008**; `p01` 1 versus 7–8, `p05` 2 versus 9–10 |

Within one stream the picture is stable and its black floor does not move. Add
stream restarts and the two-state split appears immediately. So this is a
per-stream-open effect, and because the restart run never used the Windows
still-capture path, the host's photo pipeline is not involved.

**The block responsible is `BAY3D`.** Dumping the whole of `/proc/rkisp-vir0`
at each restart and diffing the two states, of 35 reported block lines exactly
one differs — every other block is identical in state and value:

| Block | Dimmer state | Brighter state |
|-------|--------------|----------------|
| `BAY3D` | `ON(0x80010001 …)` | `OFF(0x0 …)` |

Fourteen dumps, seven per state, split perfectly. And the kernel says why it is
sometimes off:

```
rkisp rkisp-vir0: no bay3d buffer available
```

`BAY3D` is the Bayer-domain temporal denoiser. When its buffer cannot be
allocated as the stream starts, it is disabled for that stream's whole life.

That message is the cause rather than a bystander, which is worth establishing
because the board's ring buffer holds only about twenty seconds — long enough
that a message seen after the fact says nothing about which stream produced it.
Clearing the ring before each stream and reading it back afterwards:

| Streams | `BAY3D` ended up | Kernel logged the failure |
|--------:|------------------|---------------------------|
| 10 | `OFF` | yes |
| 2 | `ON` | no |

Twelve agreements out of twelve. Two explanations that the same experiments rule
out: it is not memory exhaustion, since it fails with several megabytes free;
and it is not the previous stream's teardown racing the next one, since a 45 s
idle gap between streams failed as often as a 6 s gap.

**Which means the brighter state is the degraded one.** With auto-exposure
railed at 510× gain in a dim room, shadow noise is large, and because luma
cannot go below zero that noise is clipped — which biases the measured mean
*upward*. Temporal averaging removes it, so the mean falls and the black floor
drops to 1. The extra brightness is noise, not signal:

| `BAY3D` | Trials | Mean luma | Frame-to-frame MAD |
|---------|-------:|-----------|--------------------|
| `ON` | 2 | 20.6, 20.9 | 1.34, 1.43 |
| `OFF` | 10 | 27.2–30.3 | 2.04–2.92 |

Those means are higher than the table above because the room was getting light
by then; the `ON` trials fall *between* `OFF` trials in time, so the trend does
not explain the split. Note that frame-to-frame difference partly scales with
brightness, so it corroborates the denoising account rather than proving it on
its own — the black floor moving from 7–8 to 1 is the stronger evidence, since
nothing multiplicative can shift a floor.

Because the effect is additive it matters most in dim scenes. In a well-lit
room a pedestal of a few levels on a mean of a hundred is not visible; at 510×
gain in the dark it nearly doubles the mean.

That scoping is what separates this from the dark-picture fault, and the two are
easy to conflate because both re-roll when the stream reopens. A picture that is
*visibly* dark in an ordinary lit room is not `BAY3D`: across 12 builds in such a
room the denoiser came up on five times and off seven with mean luminance flat at
about 53 either way. That fault is the ISP's output gamma curve going missing
after about four pipeline rebuilds — midtones crushed, highlights roughly intact,
and no recovery short of a power cycle. See [picture goes dark after a few
reconnections](troubleshooting.md#picture-goes-dark-after-a-few-reconnections).

---

## ae-cycle.ps1

**Question it answers:** Does the auto-exposure working point degrade across
repeated stream open/close cycles?

Each cycle starts a DirectShow capture stream, samples AE registers at three
phases during the stream, stops the stream, waits, then samples once more idle.
After all cycles it compares the first and last settled samples and writes a
summary.

### Running it

```powershell
.\tools\measure\ae-cycle.ps1 -Cycles 60 -StreamSec 45 -IdleSec 20 -Width 1920 -Height 1080
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-Cycles` | `60` | Number of open/close cycles |
| `-StreamSec` | `45` | How long each DirectShow stream runs |
| `-IdleSec` | `20` | Idle wait after each stream before the idle sample |
| `-Csv` | `tools\measure\ae-cycle.csv` | Per-sample output |
| `-Adb` | `adb` | Path to `adb`, or a bare name to find on `PATH` |
| `-Width` | `1920` | Capture width passed to `dshow-test.ps1` |
| `-Height` | `1080` | Capture height passed to `dshow-test.ps1` |

Each cycle's DirectShow output is saved under
`tools/measure/ae-cycle-logs/cycle-NNN.log`.

### Output columns

| Column | Meaning |
|--------|---------|
| `cycle` | Cycle number (1-based) |
| `phase` | `early` (3 s after stream start), `mid` (10 s), `settled` (`StreamSec − 5` s), or `idle` (after stream ends and idle wait) |
| `time` | Sample timestamp |
| `uptime_s` | Board uptime |
| `exp_lines` | Exposure in lines |
| `again` | Analogue gain register |
| `gain_x` | Total gain multiplier |

### Interpreting results

After all cycles, `ae-cycle.csv.summary.txt` compares the mean of the first
five settled samples against the mean of the last five (or fewer if the run was
short). It reports exposure and gain ratios and a verdict:

- Change under 3% — *Working point looks stable*
- Lower exposure or gain in the last block — *Working point moved darker across cycles*
- Otherwise — *Working point shifted (exposure or gain changed beyond 3%)*

Compare `early`, `mid` and `settled` within a cycle to see how quickly AE
converges after each open.

---

## boot-time.ps1

**Question it answers:** How long from reboot until a host application can select
the camera?

Measures the host-visible answer: time from `adb reboot` until Windows reports
the device as present with `Status = OK`. It then lines that up against kernel
milestones from `dmesg` and the daemon log.

Soft reboot over ADB does not drop the power rails, so the number is a slight
under-estimate of a true cold plug-in.

### Running it

```powershell
.\tools\measure\boot-time.ps1 -Runs 3 -DeviceName 'UVC Camera'
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-Runs` | `3` | Reboot cycles to average |
| `-DeviceName` | `UVC Camera` | Friendly name as Windows sees it |
| `-Adb` | `adb` | Path to `adb`, or a bare name to find on `PATH` |
| `-Csv` | `tools\measure\boot-time.csv` | Per-run results |

### Output columns

| Column | Meaning |
|--------|---------|
| `run` | Run number |
| `gone_after_s` | Seconds until the camera disappeared from Device Manager |
| `camera_s` | Seconds until the camera reappeared with `Status = OK` |
| `adb_s` | Seconds until `adb devices` shows the board again |
| `uptime_at_adb_s` | The board's own `/proc/uptime` at the moment ADB returned |
| `pre_kernel_s` | Shutdown plus bootloader: `adb_s` minus `uptime_at_adb_s` |
| `total_s` | Wall-clock time from reboot command to end of run |

The script also prints board milestones from the last boot (`init starts`, ISP
probe, sensor detected, encoder module, UVC function bound, USB configured, ISP
first params, and `daemon ready` from `/tmp/uvc.log` if present).

### Interpreting results

`camera_s` is the figure that matters for "can I open the camera app yet?".

`pre_kernel_s` is the phase neither clock can see alone. `dmesg` timestamps
start when the kernel starts, so the bootloader is invisible to the board; the
host sees nothing at all until USB enumerates. Reading the board's uptime the
instant ADB returns bridges the two clocks, and what is left over is shutdown
plus bootloader. The script prints a phase breakdown from this, and measured
figures for this board are in [roadmap.md](roadmap.md#wp0--measure-the-baseline-done).

Because the reading is a USB round trip, it is timed to the midpoint of that
round trip rather than to either end. Expect a few tens of milliseconds of
uncertainty, which is well below the differences worth acting on.
Compare it against the kernel timestamps to see how much time is spent after the
gadget binds but before Windows finishes enumeration.

---

## dshow-test.ps1

**Question it answers:** Does the DirectShow path render a real preview?

Builds a minimal DirectShow graph for **UVC Camera**: capture → auto decoder →
renderer. By default it runs for five seconds and saves a full-screen screenshot
so you can see what the DirectShow stack actually renders. This is the harness
[architecture.md](architecture.md) refers to for testing the DirectShow path
(alongside Media Foundation's `capture-test.ps1`).

`ae-cycle.ps1` invokes this script with `-NoScreenshot` to hold a stream without
writing a PNG.

### Running it

```powershell
.\tools\test\dshow-test.ps1 -Seconds 30 -Width 1920 -Height 1080 -OutPng .\preview.png
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-OutPng` | `tools\test\dshow-preview.png` | Screenshot path |
| `-Width` | `0` | Requested capture width; `0` leaves the default format |
| `-Height` | `0` | Requested capture height; `0` leaves the default format |
| `-Seconds` | `5` | How long to run the preview |
| `-NoScreenshot` | off | Skip the screenshot (used by `ae-cycle.ps1`) |

The camera name is fixed to `UVC Camera` in the script. Exit code is `1` if the
graph fails to start.

### Interpreting results

`StartPreview: running` and a sensible screenshot mean the DirectShow path is
working. A black preview with a ticking frame counter — the failure mode
described in [architecture.md](architecture.md#uvc-negotiation-and-the-bug-that-hid-inside-it)
— shows up here even when Media Foundation applications look fine.

---

## Interpreting sensor gain

Do not read gain registers at face value. The full gain ladder and the arithmetic
are in [hardware.md](hardware.md#decoding-the-gain-registers). Two points that
commonly mislead:

**The gain codes are not linear.** Each analogue code is the lower bound of a
band one octave wide, with fine digital gain interpolating within it. Treating
the bytes as a linear scale produces plausible-looking but wrong numbers.

**Gain only makes sense next to exposure.** In a dark room the sensor pins
exposure at its ceiling and controls brightness with gain alone, so a very large
`gain_x` is normal and not a fault by itself.

---

## What these cannot tell you

**Image brightness, from most of these scripts.** `ae-probe.ps1`,
`pipeline-probe.ps1`, `ae-cycle.ps1` and `boot-time.ps1` observe control state
and pipeline health, not pixels. Only [luma-probe.ps1](#luma-probeps1) measures
the luminance of a frame; the rest cannot tell a darkened picture from a healthy
one.

**A single still is not a brightness measurement.** The capture harnesses in
`tools\test\` save real JPEGs (see [installing.md](installing.md)), so it is
tempting to use one as a brightness meter. Do not. On this hardware the
luminance of a still lands in one of two states differing by a factor of 1.62
with the sensor bit-identical, so one frame tells you which state it landed in
and nothing else. Use `luma-probe.ps1` over many shots and read the
distribution, not the value. The evidence is in
[Interpreting results](#interpreting-results-2) under that script.

**The capture path is not perfectly reliable.** During development 27 of 30
paced shots were usable, and a burst with no gap between shots produced only 3
usable frames out of 15. `luma-probe.ps1` records these as `empty file` or
`capture failed` in its `note` column rather than skipping them silently, but
always check that a frame decoded before drawing a conclusion from it.

**`kbps` is not a brightness meter.** The daemon's bitrate is a weak proxy for
image content: a dark scene compresses smaller, but a noisy high-gain image
compresses worse, so the two effects fight. Do not treat `kbps` as a brightness
measurement.

**Reduced sensitivity in the dark.** A dark room pins auto-exposure near the top
of its range, which compresses the headroom available for exposure to move
upwards. Overnight tests in an unlit room are less sensitive to faults that
would show as increased gain, because gain may already be near its ceiling.
