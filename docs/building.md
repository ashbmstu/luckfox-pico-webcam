# Building

How to cross-compile `uvc_streamer` for the Luckfox Pico Mini B. The daemon
targets Rockchip RV1103 with uClibc and links against vendor libraries that
ship on the board — it cannot be built natively on the device, and CI does not
build it (see [Host-side test](#host-side-test) below).

For what the binary does once it is running, see [architecture.md](architecture.md).
To deploy a built binary, see [installing.md](installing.md).

## What you need

| Requirement | Notes |
|-------------|-------|
| Linux build host | Cross-compilation only. On Windows, use WSL2. |
| Luckfox Pico SDK | Clone [LuckfoxTECH/luckfox-pico](https://github.com/LuckfoxTECH/luckfox-pico). The checkout is large. |
| This repository | You need `src/streamer/` and a configured SDK path (see below). |

Keep the SDK on a **Linux filesystem**. On Windows, clone and build inside WSL
(for example under `/home/you/luckfox-pico`), not on `/mnt/c/...`. The build is
I/O-heavy and the tree is case-sensitive; building on the Windows mount is slow
and can fail in subtle ways.

## The toolchain

The SDK ships a 32-bit ARM cross-compiler:

`arm-rockchip830-linux-uclibcgnueabihf`

It lives under `tools/linux/toolchain/` inside the SDK checkout. Binaries are
linked against **uClibc**, not glibc — do not substitute a generic
`arm-linux-gnueabihf` toolchain.

## Configuring the paths

`src/streamer/Makefile` takes a single SDK root. All other paths (toolchain,
MPP, Rockit, RGA) are derived from it automatically.

Point at your checkout on the command line or in the environment:

```bash
make SDK=/path/to/luckfox-pico
```

The default is `/home/luckfox/luckfox-pico-main` if you omit `SDK`.

| Variable | Purpose |
|----------|---------|
| `SDK` | Root of your Luckfox Pico SDK checkout — the only path you need to set |
| *(derived)* | `CC`, `MPP_SDK`, `ROCKIT_SDK`, `ROCKIT_LIB`, and `RGA_LIB` are expanded from `SDK` |

Run `make help` in `src/streamer/` to see available targets and the current
default for `SDK`.

## Building

From `src/streamer/` on your Linux host (or inside WSL):

```bash
make SDK=/path/to/luckfox-pico
```

If your SDK is already at the default path, a plain `make` is enough. On success
you get `uvc_streamer` in the same directory. To clean:

```bash
make clean
```

If the cross-compiler is missing, `make` fails with a message naming `SDK` and
how to set it — not a raw "command not found".

### Building from Windows via WSL

Run the build through your WSL distro from PowerShell, pointing at the repo
path **inside** WSL (adjust the distro name and path):

```powershell
wsl.exe -d Ubuntu -e bash -lc "cd /home/you/projects/ai-camera/src/streamer && make SDK=/home/you/luckfox-pico"
```

Replace `Ubuntu` with your installed distro and use the WSL path to this
repository, not a `/mnt/c/...` path.

## Host-side test

CI does not build `uvc_streamer` — the daemon needs the vendor SDK and cannot
be built on a host at all. What CI runs instead is `tools/test/check-modes.py`,
which verifies that `mjpeg_frame_dims()` in `src/streamer/uvc_streamer.c` agrees
with the `configure_uvc_resolution_mjpeg` calls in
`board/init.d/S50usbdevice`, that every mode is 16:9, and that the advertised
frame interval matches `DEFAULT_FPS`.

Anyone can run the same check locally:

```bash
python3 tools/test/check-modes.py
```

It needs nothing installed beyond Python 3.

## The build is reproducible

The Makefile compiles each object in place, so no absolute source paths are
baked into the binary. Two builds of the same commit against the same SDK
produce byte-identical output regardless of where the tree was checked out.

Verified on 26 August 2026: a fresh `git clone` of this repository, built with
the same SDK, produced a binary matching the one already running on the board.

```bash
md5sum src/streamer/uvc_streamer
adb shell "md5sum /oem/uvc_streamer"
```

If those two differ, the board is running something other than this commit —
which is worth knowing before you spend time debugging behaviour that your
source does not explain.

## What links against what

The daemon links:

| Library | Role |
|---------|------|
| `librockit` | Rockit MPI (`RK_MPI_*`) — VI→VENC bind |
| `librockchip_mpp` | MPP support pulled in by Rockit |
| `librga` | RGA (2D blit) support in the vendor stack |

`LDFLAGS` includes `-Wl,-rpath,/oem/usr/lib` so the binary finds the vendor
`.so` files already on the board at runtime. **This project does not ship those
libraries**; they come from the Luckfox OEM partition.

## Next step

[installing.md](installing.md) — push the binary to the board and verify the
camera enumerates on the host.
