#!/usr/bin/env python3
"""Check that the daemon's frame table matches the board's USB descriptors.

The host does not send a resolution when it starts a stream. It sends a
bFrameIndex, and that index means whatever position the frame descriptor was
created in by board/init.d/S50usbdevice. The daemon turns the index back into a
width and height using its own table in src/streamer/uvc_streamer.c.

Nothing at build time connects those two files. If they drift apart, the daemon
happily encodes at one size while the host has been told to expect another, and
the failure is quiet: Media Foundation rescales mismatched frames, so the
picture looks right in some apps and is black in DirectShow ones. That is the
bug fixed in 2717e3d, arrived at the slow way. This check is the cheap way.

Run it directly, or via CI. No SDK, no board, no dependencies.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DAEMON = os.path.join(ROOT, 'src', 'streamer', 'uvc_streamer.c')
INITD = os.path.join(ROOT, 'board', 'init.d', 'S50usbdevice')


def read(path):
    with open(path, encoding='utf-8') as fh:
        return fh.read()


def daemon_table(src):
    """Frame index -> (width, height), from mjpeg_frame_dims()."""
    body = re.search(r'mjpeg_frame_dims\s*\([^)]*\)\s*\{(.*?)\n\}', src, re.S)
    if not body:
        return None, 'could not find mjpeg_frame_dims() in %s' % DAEMON
    table = {}
    for idx, w, h, ret in re.findall(
            r'case\s+(\d+):\s*\*w\s*=\s*(\d+);\s*\*h\s*=\s*(\d+);\s*return\s+(\d+);',
            body.group(1)):
        if idx != ret:
            return None, 'case %s returns %s - a frame index must return itself' % (idx, ret)
        table[int(idx)] = (int(w), int(h))
    if not table:
        return None, 'mjpeg_frame_dims() has no case labels'
    return table, None


def descriptor_list(script):
    """(width, height) in creation order, which is bFrameIndex order."""
    return [(int(w), int(h)) for w, h in re.findall(
        r'^\s*configure_uvc_resolution_mjpeg\s+(\d+)\s+(\d+)\s*$', script, re.M)]


def main():
    src, script = read(DAEMON), read(INITD)
    errors = []

    table, err = daemon_table(src)
    if err:
        print('check-modes: ' + err)
        return 1

    descs = descriptor_list(script)
    if not descs:
        print('check-modes: no configure_uvc_resolution_mjpeg calls in %s' % INITD)
        return 1

    print('%-7s %-13s %-13s' % ('index', 'descriptor', 'daemon'))
    for i, (w, h) in enumerate(descs, start=1):
        got = table.get(i)
        mark = 'ok'
        if got is None:
            mark = 'MISSING from daemon table'
            errors.append('frame index %d (%dx%d) has no case in mjpeg_frame_dims()' % (i, w, h))
        elif got != (w, h):
            mark = 'MISMATCH'
            errors.append('frame index %d: descriptor says %dx%d, daemon says %dx%d'
                          % (i, w, h, got[0], got[1]))
        print('%-7d %-13s %-13s %s' % (i, '%dx%d' % (w, h),
                                       '%dx%d' % got if got else '-', mark))

    for i in sorted(set(table) - set(range(1, len(descs) + 1))):
        errors.append('daemon has frame index %d (%dx%d) that the board never creates'
                      % (i, table[i][0], table[i][1]))

    # Every mode must be 16:9. A 4:3 entry would either crop the sides away,
    # changing the angle when the host changes resolution, or squeeze the full
    # field into a narrower frame and stretch the picture vertically.
    for w, h in descs:
        if w * 9 != h * 16:
            errors.append('%dx%d is not 16:9, so it cannot show the sensor field undistorted' % (w, h))

    # The advertised interval has to be the rate the daemon actually encodes at,
    # or the host displays a frame rate it never receives.
    fps = re.search(r'#define\s+DEFAULT_FPS\s+(\d+)', src)
    intervals = set(re.findall(r'echo\s+(\d+)\s*>\s*\$\{DIR\}/dwFrameInterval', script))
    if fps and intervals:
        want = 10000000 // int(fps.group(1))
        for iv in sorted(intervals):
            if int(iv) != want:
                errors.append('dwFrameInterval %s but DEFAULT_FPS %s wants %d'
                              % (iv, fps.group(1), want))
        print('\nframe interval %s (= %s fps), matching DEFAULT_FPS' % (want, fps.group(1)))

    if errors:
        print('\ncheck-modes FAILED:')
        for e in errors:
            print('  ' + e)
        return 1
    print('\ncheck-modes: %d modes consistent between daemon and board.' % len(descs))
    return 0


if __name__ == '__main__':
    sys.exit(main())
