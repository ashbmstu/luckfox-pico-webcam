# Roadmap — from "works" to "appliance"

The camera works. This document is the plan to make it behave like an appliance
rather than a small computer: self-healing, safe to unplug, quick to appear, and
carrying nothing it does not need.

It is written so that someone who has never seen the project can pick up any
single item and do it. Read [architecture.md](architecture.md) first.

**Nothing here should change the picture.** Frame rate and image quality come
from the sensor mode and the ISP, not from how much Linux is running. Any change
that alters the image is a bug in that change.

## Goals

| # | Goal | How you know it is done |
|---|------|------------------------|
| G1 | **Self-healing** | A hung daemon or kernel results in an automatic reboot within ~30 s with no human intervention. Demonstrated by deliberately hanging the daemon. |
| G2 | **Power-fail safe** | Root filesystem mounted read-only. Yanking power mid-operation twenty times in a row leaves the board booting normally every time. |
| G3 | **Fast to appear** | Under 10 s from plugging in to being selectable in a host application. Stretch: under 5 s. Currently **9.59 s** from a soft reboot — see WP0. |
| G4 | **Minimal surface** | The production image runs the 3A server and the daemon. Nothing else. |
| G5 | **No regressions** | 25 fps with `0 timeouts` at 640×360, 1280×720, 1920×1080, and 2304×1296; verified on both DirectShow and Media Foundation. |

**G5 gates everything.** The daemon prints a statistics line every five seconds:

```bash
adb shell "grep 'fps,' /tmp/uvc.log | tail -3"
```

## Before you touch anything

- **Recovering a board that will not boot needs physical access** — you hold the
  BOOT button while replugging. Do not start work that risks the boot path
  unless you can reach the hardware. See [recovery.md](recovery.md).
- **Never `killall uvc_streamer` while the gadget is bound.** Kernel panic,
  physical power cycle. See [architecture.md](architecture.md#the-kernel-panic-you-must-not-trigger).
- **The rootfs is 96% full.** Anything added has to displace something.
- **`/dev/video11` appears asynchronously.** Wait for the node; never assume it.
- **Without `rkaiq_3A_server` the picture is grey.** If an image looks wrong
  after a change, check that process before suspecting the pipeline.

## Where the time goes at boot

Measured from `dmesg` on a working board:

| Milestone | Kernel time |
|-----------|------------|
| `init` starts | 0.52 s |
| MIPI receiver and ISP probe | 2.58 – 2.66 s |
| SC3336 detected on I²C | 2.81 s |
| Hardware encoder module loaded | 3.01 s |
| UVC function bound | 4.56 s |
| USB configured, host sees the device | 5.57 s |
| Daemon reports `gadget activated` | 5.40 s |
| ISP delivers first parameters buffer | 5.90 s |

So the kernel-side path to enumeration is under six seconds, and the daemon is
not the bottleneck. What is *not* in this table is the bootloader before the
kernel starts, which has to be measured from the host side. It has since been
measured at 3.71 s, and the whole phase breakdown is in [WP0](#wp0--measure-the-baseline-done).

The useful thing this shows: **the daemon reaches "waiting for host" at 5.4 s,
before the ISP has even finished initialising at 5.9 s.** The camera can be
selectable in an application while the imaging pipeline is still coming up,
because `rkmpi_venc_start()` only runs when a host actually opens a stream.

## What is running that should not be

Inventory from a stock board, with resident set sizes on a machine that has
33 MB of usable RAM:

| Process | RSS | Why it is there |
|---------|-----|-----------------|
| `smbd` + `nmbd` + 2 helpers | ~12 MB | Samba, from the vendor image. Nothing uses it. |
| `telnetd` | 0.5 MB | Vendor image. A root shell over the network with a published password. |
| `adbd` | 0.25 MB | Our deployment channel. Wanted in development, not in production. |
| `rkaiq_3A_server` | 5 MB | **Required.** |
| `uvc_streamer` | 0.9 MB idle, ~6 MB streaming | **Required.** The streaming figure is the one that matters for headroom: it is MPI buffers, not the daemon's own code. |
| `luckfox_switch_rgb_resolution` | 0.75 MB | Vendor leftover. |

With both required processes running and a host streaming, `MemFree` sits at
about 2 MB and `MemAvailable` at about 6.5 MB. That is the headroom every
work package below has to fit inside.

Samba alone is about a third of the board's memory. The corresponding init
scripts are `S91smb`, `S50telnet`, `S50sshd`, `S49ntp`, `S99python`,
`S99hciinit` (Bluetooth) and `S99rtcinit`.

Note also that a load average around 6 on an idle board is **normal**: Rockit's
kernel threads sit in uninterruptible sleep, which Linux counts as load. The CPU
is over 80% idle. Do not chase this.

---

## Work packages

Ordered by value per unit of risk. Do one at a time, verify G5 after each, and
commit separately so any one can be reverted.

### WP0 — Measure the baseline (done)

Measured on 26 August 2026 with [boot-time.ps1](../tools/measure/boot-time.ps1),
three soft reboots, Windows host:

| Phase | Seconds | Share |
|-------|--------:|------:|
| Shutdown and bootloader | 3.71 | 39% |
| Kernel start to `USB_STATE=CONFIGURED` | 5.63 | 59% |
| Host enumeration to selectable | 0.25 | 3% |
| **Total, reboot to selectable** | **9.59** | |

Total across the three runs was 9.48–9.69 s and the bootloader figure was
3.68 / 3.73 / 3.72 s, so this is repeatable rather than one lucky boot.

The bootloader phase is the one neither clock can see on its own: `dmesg` starts
counting when the kernel starts, and the host sees nothing until USB enumerates.
The script recovers it by reading `/proc/uptime` at the moment ADB returns and
subtracting that from host-elapsed time, which leaves shutdown plus bootloader.

Two results are worth acting on:

- **The host is not the bottleneck.** A quarter of a second passes between the
  gadget being configured and the camera being selectable. Effort spent on the
  host side of enumeration is wasted effort.
- **The bootloader is 39% of the budget, and nothing in WP2 touches it.** WP2
  works on userspace sequencing, which sits inside the 5.63 s kernel phase. WP2
  alone therefore cannot reach G3's five-second stretch target; that needs
  bootloader work as well.

**Caveat:** this is measured from `adb reboot`, so the power rails never drop
and the ROM stage is skipped. A cold plug-in is slower by that much. G3's "under
10 s" is only just met from a soft reboot and is probably not met on a cold plug
— it should be re-measured with a switched USB hub before being called done.

### WP1 — Hardware watchdog

The biggest robustness win. It needs one line of device tree.

On a stock board there is **no `/dev/watchdog`, nothing under
`/sys/class/watchdog/`, and no watchdog node in the live device tree** — only the
character-device major, registered by the watchdog core. Chased through the SDK,
the reason is not a missing driver:

| Piece | Status in the SDK |
|-------|------------------|
| `CONFIG_WATCHDOG`, `CONFIG_DW_WATCHDOG` | Already `=y` in `luckfox_rv1106_linux_defconfig` |
| `drivers/watchdog/dw_wdt.c` | Present |
| `wdt: watchdog@ff5a0000` in `rv1106.dtsi` | Present, `compatible = "rockchip,rv1106-wdt", "snps,dw-wdt"` — but **`status = "disabled"`** |
| Any board DTS enabling it | None |

So the driver is compiled in and simply never probes. Enabling it is a one-line
addition to `arch/arm/boot/dts/rv1103g-luckfox-pico-mini.dts`:

```dts
&wdt {
    status = "okay";
};
```

That still means rebuilding and flashing the kernel image, so keep it grouped
with WP4 and **only do it with physical access to the board**, since recovery
needs the BOOT button.

Once the device exists:

- Open it at daemon start, set a timeout of around 30 s, and feed it from the
  poll loop. That loop already wakes every 50 ms, so feeding is free.
- Feed it from the **event loop**, not a timer thread. The liveness worth proving
  is "the daemon is still servicing UVC events", not "the kernel is alive".
- Use `NOWAYOUT` semantics, so a daemon that dies reboots the board rather than
  quietly disarming the watchdog on close.
- Verify with a debug path that stops feeding: the board should reboot and come
  back streaming.

Risk: too short a timeout turns a recoverable stall into a boot loop. Choose it
with margin over the worst stall observed in WP0.

### WP2 — Startup sequencing

Exploit the insight above: the daemon does not need the camera in order to
enumerate.

- Replace fixed `sleep`s with condition polling. `start_3a.sh` waits up to 30 s
  for `/dev/video11` and then sleeps a further 2 s unconditionally.
- Bring the gadget and the daemon up as early as possible; let the ISP and 3A
  finish in parallel.
- Handle the race that creates: a host that starts streaming before the ISP is
  ready. The daemon refuses the stream if hardware encode cannot start — make
  sure a later attempt succeeds once `/dev/video11` and Rockit are up, rather
  than leaving the host with a black preview and no retry path.

### WP3 — Read-only rootfs

Removes the whole class of power-fail corruption.

- Mount `/` read-only. `/tmp` is already tmpfs.
- `/oem` holds the daemon binary, `uvc_run.sh`, vendor libraries, and
  `/oem/.usb_config`. Deploying a new binary writes there today. For a read-only
  rootfs you either keep `/oem` writable for updates, stage binaries on
  `/userdata` and copy at boot, or accept that each deploy needs a remount.
  `/userdata` is 4.5 MB and nearly empty — the natural home for anything that
  must stay writable.
- Audit what else writes. Logs go to `/tmp` today, which is volatile and fine.

### WP4 — Kernel and rootfs trim

Pays off three ways: boot time, RAM, and the 96%-full rootfs.

Candidates: unused network drivers and the network stack, WiFi, filesystems
never mounted, debug and tracing infrastructure, media drivers outside our path.
Load-bearing and not to be touched: `rga`, `mpp_vcodec`, `video_rkisp`,
`video_rkcif`, `rockit`, and the sensor driver.

Do this last, together with WP1's device-tree change since both need a flash.
Highest effort, highest blast radius, needs physical access to recover.

### WP5 — Supervision (may not be possible)

If the daemon dies, restart it — except **the naive restart path is exactly the
one that panics the kernel**. A supervisor that respawns the daemon while the
gadget is still bound makes things worse.

Investigate whether the gadget can be torn down and rebuilt cleanly first. If it
cannot, the honest answer is that the WP1 watchdog reboot *is* the recovery
mechanism, and this package should be closed with that reason recorded rather
than forced.

### WP6 — Production versus development image

Two profiles:

- **Development** keeps ADB and the serial console.
- **Production** drops both and runs only the 3A server and the daemon, with the
  services listed above removed.

Document how to get a production board back into development mode — without ADB,
the only route in is the recovery procedure.

---

### WP7 — `BAY3D` denoiser fails to start

The ISP's Bayer-domain temporal denoiser is disabled for a whole streaming
session whenever its buffer cannot be allocated as the stream opens:

```
rkisp rkisp-vir0: no bay3d buffer available
```

The result is a visibly noisier picture that lasts until the application
reopens the stream, and it lands roughly at random from one session to the next.
In a dim room it is the difference between a clean image and one whose black
floor sits several levels off the bottom. It does **not** change brightness:
across 12 builds with the denoiser ON five times and OFF seven, mean luminance
was flat at about 53 either way. The brightness two-state effect is WP8. Measurements, and how to
tell which state a session is in, are in
[measuring.md](measuring.md#stream-probeps1); the user-facing symptom is in
[troubleshooting.md](troubleshooting.md#picture-noise-differs-between-sessions).

The kernel message is the cause and not a bystander. Clearing the ring buffer
before every stream and reading it back after, the denoiser was off in exactly
the streams that logged the failure and on in exactly those that did not —
**12 agreements out of 12**, with it failing in 10 of the 12.

What it is *not*: memory exhaustion (it fails with several megabytes free), and
not a teardown race either — a 45 s idle gap between streams failed just as often
as a 6 s one, so the previous session having finished cleanly is not the
variable. `rkisp-vir0: waiting on params stream off event timeout` appears in the
same windows but does not track the failure.

So the next step is in the driver: find where `no bay3d buffer available` is
emitted in the Rockchip ISP source, and establish what allocation is actually
being attempted and against which pool — the SRAM the block reports using
(`mode:(lo4x8 sram)`) is a much smaller and more contended resource than system
memory, which would explain a failure that is insensitive to both free RAM and
idle time.

Worth fixing before WP4 and WP6 trim anything: a change in memory layout could
plausibly make this more or less frequent, and without a way to detect the state
that would be invisible.

---

### WP8 — ISP gamma curve lost after about four pipeline builds

The ISP's output gamma curve, `GAMMA_OUT`, stops being programmed after roughly
four rebuilds of the capture pipeline, and stays off until the board is power
cycled. The picture goes dark — mid-grey lands near 17 of 255 instead of 74 —
while highlights are barely touched, which is the signature of a missing tone
curve rather than an exposure change.

This is the defect behind the user-visible report that the camera "starts fine
and goes dark later". It is **not** driven by uptime: two watches on fresh boots
put the failure at uptime 222 s / build 4 and uptime 112 s / build 5, so the
times differ twofold while the build counts do not. Twelve stream cycles that
reused one pipeline (2 builds) held gamma on throughout.

Every build re-runs the vendor 3A init — `RTIsp3x ... ispInitDevice` — and
something it allocates is never returned: `MemAvailable` drops about 100 kB per
build until the LUT can no longer be programmed, then stops dropping. Nothing
leaks in this daemon (fds, threads and `VmRSS` are all flat across seven
builds), and `ispInitDevice` lives in `librockit.so`, which ships without
source.

Three approaches have been tried and rejected, all measured:

- Leaving `RK_MPI_VI_DisableDev` uncalled so the device stays enabled.
  `ispInitDevice` still ran once per build, so the cycle follows the VI
  **channel**, not the device.
- `RK_MPI_VI_PauseChn` / `ResumeChn` in place of disabling the channel. Pausing
  works and silences the idle `jpeg overflow` noise completely, but the stream
  never recovers on resume and the board wedges, needing a replug.
- Rebuilding again to re-roll it. Unlike WP7 this is not probabilistic — twelve
  consecutive builds all came up off.

That leaves two routes, neither yet taken:

1. **Fewer builds.** Stop releasing the pipeline when the host goes idle, so a
   session costs one build instead of a dozen. This makes the bug invisible for
   ordinary open and close, but not for resolution changes, and it has a real
   cost: the encoder stays bound to a running VI, which emits about 20
   `jpeg overflow` kernel lines per second for as long as the camera is idle —
   roughly 72,000 an hour into a ring buffer that holds about 20 seconds, which
   would make `dmesg` useless for diagnosing anything else. Silencing that is
   what both rejected experiments above were trying to do.
2. **Never rebuild at all.** Run the VI channel permanently at the sensor's
   native 2304×1296 and do the downscale in VPSS or RGA, so a resolution change
   reconfigures only the later stages. Builds would then happen once per boot.
   Costs an extra stage and more CMA against a 24576 kB budget that already
   peaks at 18336 kB, so it needs measuring before it can be trusted.

The measurements behind this entry are in
[troubleshooting.md](troubleshooting.md#picture-goes-dark-after-a-few-reconnections).

---

## Open questions

- What does the bootloader contribute to time-to-enumerate? (WP0)
- Why does the `BAY3D` buffer allocation fail with megabytes of memory free,
  and can the daemon wait for the previous stream's teardown to complete before
  opening the next one? (WP7)
- What exactly does the vendor 3A init allocate per VI channel enable that it
  never returns, and is there any call that resets it short of a power cycle?
  (WP8)
- Can VPSS or RGA carry the downscale cheaply enough that the VI channel never
  has to be reconfigured for a resolution change? (WP8)
- Can the USB gadget be torn down and rebuilt without the `ffs_func_unbind`
  panic? This decides whether WP5 is possible at all.
- Does the vendor SDK's quick-boot support apply to this board, and is it worth
  the complexity if WP2 already gets under 10 s?
- Can the watchdog be enabled without reflashing the whole image — is a
  device-tree overlay applied at boot, or a `dtbo`, workable here? The change
  itself is one line (see WP1); the cost is entirely in how it has to be
  delivered.

## Explicitly not planned

- Bare-metal or RTOS firmware. See
  [architecture.md](architecture.md#why-not-bare-metal).
- A mainline kernel. The camera pipeline exists only in Rockchip's fork.
- Higher frame rate. 25 fps is the sensor mode; changing it means driver and
  device-tree work for one extra frame in six.
- Lens distortion correction. A worthwhile project, but a separate one.
