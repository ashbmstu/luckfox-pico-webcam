#!/bin/sh
# Deploy uvc_streamer to a Luckfox Pico Mini B.
#
# The sequence is push, chmod, mv, reboot — not stop-and-restart. Stopping
# the daemon while the USB gadget is bound deactivates the UVC function,
# which re-runs /etc/init.d/S50usbdevice, rewrites the UDC, and panics the
# kernel in ffs_func_unbind. configfs wedges, a soft reboot hangs, and the
# board needs a physical power cycle. Renaming a running executable with mv
# is safe on Linux while the process still has the old inode mapped. Anyone
# editing this script needs to know that before they "improve" it with a
# kill-and-restart path.

set -eu

# Git Bash and other MSYS shells rewrite arguments that look like Unix absolute
# paths into Windows paths before the program sees them, so
#   adb push uvc_streamer /tmp/uvc_streamer
# silently becomes a push to C:/Users/<you>/AppData/Local/Temp/uvc_streamer on
# the device. The push appears to succeed, the following mv finds nothing, and
# the board reboots still running the old binary. Verified on Git Bash.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'


script_dir=$(
    cd -- "$(dirname -- "$0")" || exit 1
    pwd
)
repo_root=$(
    cd -- "$script_dir/.." || exit 1
    pwd
)
binary="$repo_root/src/streamer/uvc_streamer"
adb_cmd=${ADB:-adb}
dry_run=0

usage() {
    cat <<'EOF'
Usage: deploy.sh [options] [binary]

Deploy uvc_streamer to /oem on a Luckfox Pico Mini B.

Options:
  --dry-run       Print commands without running them
  --adb PATH      adb executable (default: adb, or $ADB)
  -h, --help      Show this help

binary defaults to src/streamer/uvc_streamer relative to the repository root.
EOF
}

run() {
    if [ "$dry_run" -eq 1 ]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

adb_device_count() {
    "$adb_cmd" devices 2>/dev/null | awk 'NR>1 && $2=="device" {n++} END {print n+0}'
}

while [ $# -gt 0 ]; do
    case $1 in
        --dry-run)
            dry_run=1
            shift
            ;;
        --adb)
            if [ $# -lt 2 ]; then
                echo "deploy.sh: --adb requires an argument" >&2
                exit 1
            fi
            adb_cmd=$2
            shift 2
            ;;
        --adb=*)
            adb_cmd=${1#*=}
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "deploy.sh: unknown option: $1" >&2
            exit 1
            ;;
        *)
            binary=$1
            shift
            ;;
    esac
done

if [ ! -f "$binary" ]; then
    echo "deploy.sh: binary not found: $binary" >&2
    exit 1
fi

if ! command -v "$adb_cmd" >/dev/null 2>&1; then
    echo "deploy.sh: adb is not runnable: $adb_cmd" >&2
    exit 1
fi

if ! "$adb_cmd" version >/dev/null 2>&1; then
    echo "deploy.sh: adb is not runnable: $adb_cmd" >&2
    exit 1
fi

if [ "$dry_run" -eq 0 ]; then
    device_count=$(adb_device_count)
    if [ "$device_count" -eq 0 ]; then
        echo "deploy.sh: no ADB devices attached. Plug in the board and run 'adb devices'." >&2
        exit 1
    fi
    if [ "$device_count" -gt 1 ]; then
        echo "deploy.sh: multiple ADB devices attached ($device_count). Disconnect extras or set ANDROID_SERIAL." >&2
        exit 1
    fi
fi

run "$adb_cmd" push "$binary" /tmp/uvc_streamer
run "$adb_cmd" shell "chmod +x /tmp/uvc_streamer && mv /tmp/uvc_streamer /oem/uvc_streamer"
run "$adb_cmd" shell reboot

if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] wait up to 60 s for device, then tail /tmp/uvc.log\n'
    exit 0
fi

# adbd takes a moment to go down after 'adb reboot'. Without waiting for the
# device to disappear first, the poll below matches the still-running
# pre-reboot adbd, returns immediately, and tails a stale log.
printf 'Waiting for board to go down...
'
gone_deadline=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$gone_deadline" ]; do
    if [ "$(adb_device_count)" -eq 0 ]; then
        break
    fi
    sleep 1
done

printf 'Waiting for board to come back (up to 60 s)...\n'
deadline=$(( $(date +%s) + 60 ))
back=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(adb_device_count)" -eq 1 ]; then
        back=1
        break
    fi
    sleep 1
done

if [ "$back" -eq 0 ]; then
    echo "deploy.sh: board did not reappear on ADB within 60 seconds." >&2
    exit 1
fi

printf 'Last lines of /tmp/uvc.log:\n'
log=$("$adb_cmd" shell "tail -n 15 /tmp/uvc.log" 2>&1) || log=""
printf '%s\n' "$log"

case $log in
    *gadget\ activated*)
        printf 'Daemon reached gadget activated.\n'
        ;;
    *)
        printf 'gadget activated not seen yet — the daemon may still be starting.\n'
        ;;
esac
