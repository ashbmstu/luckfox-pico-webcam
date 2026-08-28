# Contributing to luckfox-pico-webcam

Thank you for considering a contribution. This project turns a Luckfox Pico
Mini B into a standard USB webcam; most changes only make sense on real
hardware.

## Before you open a pull request

You need the board, sensor module, and a host PC to test anything meaningful.
The daemon cross-compiles against the Luckfox Pico SDK (a large external
download). There is no way to build or exercise the full streaming path in CI.

If your change touches the streaming path, say in the PR which resolutions you
verified and on which host stack. Windows Media Foundation and DirectShow behave
differently; both matter for this project.

## Build

Cross-compile only, using the Luckfox Pico SDK on WSL or Linux. See
[docs/building.md](docs/building.md) for setup and the exact build commands.

## Deploying to the board

Deploy over ADB. The supported workflow:

1. Push the new binary to `/tmp` on the board.
2. `chmod +x` the file in `/tmp`.
3. `mv` it over the installed binary (renaming a running binary is safe).
4. `reboot`.

**Never run `killall uvc_streamer` while the USB gadget is bound.** If the
daemon exits while the gadget is active, the UVC function is torn down, the
gadget setup script runs again, the UDC is rewritten, and the kernel can panic
in `ffs_func_unbind`. Recovery requires a physical power cycle. Use the
deploy steps above instead.

## Code style

- C99, 4-space indent, no tabs.
- `snake_case` for functions and variables.
- Match the style of existing files under `src/streamer/`.
- Comments explain why, not what.

## Commit messages

Use an imperative subject line under about 72 characters. In the body, explain
the reasoning. When a change is driven by measurement or a log line, reference
that evidence so reviewers can follow the trail.

## Reporting hardware-specific bugs

Useful reports include:

- Board revision
- Sensor module
- Host OS and the application used (browser, OBS, Teams, etc.)
- Resolution in use when the problem appeared
- Contents of `/tmp/uvc.log`

Open bugs via GitHub Issues on this repository.
