/*
 * uvc_streamer.c — UVC gadget userspace daemon for Luckfox Pico Mini B (RV1103)
 *
 * Pipeline: RK MPI VI→VENC MJPEG (hw) or /dev/video11 NV12 → sw JPEG (fallback)
 *           → UVC gadget V4L2 OUTPUT (USERPTR) → USB host (Windows)
 *
 * Modelled on Rockchip's uvc_app_tiny reference, a copy of which is carried
 * in ref/uvc-gadget.c; event subscription activates the gadget,
 * frames are supplied via V4L2 OUTPUT streaming (not write()).
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include <linux/usb/ch9.h>
#include <linux/usb/g_uvc.h>
#include <linux/usb/video.h>
#include <linux/videodev2.h>

#include "rkmpi_venc.h"

#define DEFAULT_FPS     25
#define FRAME_INTERVAL  (10000000U / DEFAULT_FPS)
#define N_UVC_BUFS      2
/* How long the encoder pipeline is kept after a host stops streaming, so that
 * an immediate restart reuses it. Long enough to cover an application closing
 * and reopening the camera, short enough that an idle camera does not sit with
 * the sensor running. */
#define VENC_IDLE_MS    5000
#define MJPEG_FORMAT_IDX 1

#define DEF_WIDTH  1920
#define DEF_HEIGHT 1080
#define DEF_FRAME_IDX 3

static const char *g_uvc_dev = NULL;
static volatile sig_atomic_t g_stop = 0;

static void on_signal(int s) { (void)s; g_stop = 1; }

static void logmsg(const char *fmt, ...) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    fprintf(stderr, "[%5ld.%03ld] ", (long)ts.tv_sec, ts.tv_nsec / 1000000L);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

/* ---------------- frame size table (MJPEG format 1) ---------------- */

/* Every mode is exactly 16:9, which is the sensor's own aspect ratio, so the
 * field of view and the geometry are identical at every resolution. A 4:3 mode
 * here would have to either crop the sides away - changing the angle when the
 * host changes resolution - or squeeze the full field into a narrower frame,
 * which is what the old 640x480 entry did: it stretched everything vertically
 * by 4/3. Neither is what someone picking a resolution in a video call expects.
 *
 * 2304x1296 is the sensor's native mode, so at that size nothing in the path
 * scales at all. Keep this table in step with the frame descriptors created by
 * board/init.d/S50usbdevice - the index is the host's bFrameIndex. */
static int mjpeg_frame_dims(int frame_idx, int *w, int *h) {
    switch (frame_idx) {
    case 1: *w = 640;  *h = 360;  return 1;
    case 2: *w = 1280; *h = 720;  return 2;
    case 3: *w = 1920; *h = 1080; return 3;
    case 4: *w = 2304; *h = 1296; return 4;
    default:
        *w = DEF_WIDTH; *h = DEF_HEIGHT; return DEF_FRAME_IDX;
    }
}

/* Clamp host probe/commit to nearest supported MJPEG frame. */
static int resolve_streaming(int fmt_idx, int frame_idx, int *w, int *h) {
    if (fmt_idx != MJPEG_FORMAT_IDX) {
        logmsg("unsupported format %d, using MJPEG %dx%d",
               fmt_idx, DEF_WIDTH, DEF_HEIGHT);
        *w = DEF_WIDTH;
        *h = DEF_HEIGHT;
        return DEF_FRAME_IDX;
    }
    int clamped = mjpeg_frame_dims(frame_idx, w, h);
    if (clamped != frame_idx) {
        logmsg("unsupported MJPEG frame %d, using %dx%d (frame %d)",
               frame_idx, *w, *h, clamped);
    }
    return clamped;
}

/* ---------------- UVC gadget (MJPEG OUTPUT, USERPTR) ---------------- */

struct uvc_dev {
    int fd;
    uint8_t *bufs[N_UVC_BUFS];
    size_t buf_cap;
    size_t bytesused[N_UVC_BUFS];
    int fill_slot;           /* uvc buffer index ready for encoding, or -1 */
    int inflight;            /* UVC buffers QBUF'd, not yet DQBUF'd */
    int streaming;
    int width;
    int height;
    struct uvc_streaming_control probe;
    struct uvc_streaming_control commit;
    uint8_t control;
    unsigned long frames_in, frames_out;
    unsigned long bytes_out;
    unsigned long stat_frames, stat_bytes, stat_timeouts;
    struct timespec stats_ts;
};

static char *find_uvc_node(void) {
    char *fallback = NULL;
    for (int n = 0; n < 32; n++) {
        char path[32];
        snprintf(path, sizeof path, "/dev/video%d", n);
        int fd = open(path, O_RDWR);
        if (fd < 0) continue;
        struct v4l2_capability cap = {0};
        if (ioctl(fd, VIDIOC_QUERYCAP, &cap) == 0 &&
            (cap.capabilities & V4L2_CAP_VIDEO_OUTPUT)) {
            if (strstr((const char *)cap.driver, "uvc")) {
                close(fd);
                return strdup(path);
            }
            if (!fallback) fallback = strdup(path);
        }
        close(fd);
    }
    return fallback;
}

static void uvc_fill_streaming_control(struct uvc_streaming_control *ctrl,
                                         int frame_idx, unsigned int interval) {
    int w, h;
    mjpeg_frame_dims(frame_idx, &w, &h);
    memset(ctrl, 0, sizeof(*ctrl));
    ctrl->bmHint = 1;
    ctrl->bFormatIndex = MJPEG_FORMAT_IDX;
    ctrl->bFrameIndex = (uint8_t)frame_idx;
    ctrl->dwFrameInterval = interval ? interval : FRAME_INTERVAL;
    ctrl->wDelay = 0;
    ctrl->dwMaxVideoFrameSize = (uint32_t)(w * h * 2);
    ctrl->dwMaxPayloadTransferSize = 1024;
    ctrl->bmFramingInfo = 3;
    ctrl->bPreferedVersion = 1;
    ctrl->bMinVersion = 1;
    ctrl->bMaxVersion = 1;
}

static void uvc_apply_host_control(struct uvc_dev *u,
                                   struct uvc_streaming_control *dst,
                                   const struct uvc_streaming_control *src) {
    int w, h;
    int frame_idx = resolve_streaming(src->bFormatIndex, src->bFrameIndex, &w, &h);
    unsigned int interval = src->dwFrameInterval;
    if (interval == 0) interval = FRAME_INTERVAL;

    memcpy(dst, src, sizeof(*dst));
    uvc_fill_streaming_control(dst, frame_idx, interval);
    u->width = w;
    u->height = h;
}

static int uvc_open(struct uvc_dev *u, const char *dev) {
    memset(u, 0, sizeof(*u));
    u->fd = open(dev, O_RDWR | O_NONBLOCK);
    if (u->fd < 0) {
        logmsg("uvc open %s: %s", dev, strerror(errno));
        return -1;
    }
    u->fill_slot = -1;

    struct v4l2_capability cap = {0};
    if (ioctl(u->fd, VIDIOC_QUERYCAP, &cap) < 0) {
        logmsg("uvc QUERYCAP: %s", strerror(errno));
        return -1;
    }
    if (!(cap.capabilities & V4L2_CAP_VIDEO_OUTPUT)) {
        logmsg("uvc %s is not VIDEO_OUTPUT (caps=0x%x)", dev, cap.capabilities);
        return -1;
    }
    logmsg("uvc opened %s (driver=%s card=%s)", dev, cap.driver, cap.card);

    u->width = DEF_WIDTH;
    u->height = DEF_HEIGHT;
    uvc_fill_streaming_control(&u->probe, DEF_FRAME_IDX, FRAME_INTERVAL);
    uvc_fill_streaming_control(&u->commit, DEF_FRAME_IDX, FRAME_INTERVAL);

    struct v4l2_event_subscription sub = {0};
    int ev[] = {UVC_EVENT_SETUP, UVC_EVENT_DATA, UVC_EVENT_STREAMON,
                UVC_EVENT_STREAMOFF, UVC_EVENT_DISCONNECT};
    for (size_t i = 0; i < sizeof(ev) / sizeof(ev[0]); i++) {
        sub.type = ev[i];
        if (ioctl(u->fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0)
            logmsg("uvc subscribe %d: %s", ev[i], strerror(errno));
    }
    logmsg("gadget activated, waiting for host");
    return 0;
}

static void uvc_free_buffers(struct uvc_dev *u) {
    for (int i = 0; i < N_UVC_BUFS; i++) {
        free(u->bufs[i]);
        u->bufs[i] = NULL;
        u->bytesused[i] = 0;
    }
    u->buf_cap = 0;
    u->fill_slot = -1;
}

static int uvc_alloc_buffers(struct uvc_dev *u, int w, int h) {
    uvc_free_buffers(u);
    u->buf_cap = (size_t)w * (size_t)h;

    for (int i = 0; i < N_UVC_BUFS; i++) {
        u->bufs[i] = malloc(u->buf_cap);
        if (!u->bufs[i]) {
            logmsg("uvc buf alloc %dx%d", w, h);
            uvc_free_buffers(u);
            return -1;
        }
    }
    return 0;
}

static int uvc_qbuf_slot(struct uvc_dev *u, int slot) {
    struct v4l2_buffer buf = {0};
    buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    buf.memory = V4L2_MEMORY_USERPTR;
    buf.index = (unsigned)slot;
    buf.m.userptr = (unsigned long)u->bufs[slot];
    buf.length = u->buf_cap;
    buf.bytesused = (unsigned)u->bytesused[slot];
    if (ioctl(u->fd, VIDIOC_QBUF, &buf) < 0) {
        logmsg("uvc QBUF[%d]: %s", slot, strerror(errno));
        return -1;
    }
    u->inflight++;
    return 0;
}

static void stream_stop(struct uvc_dev *u);

static int stream_start(struct uvc_dev *u) {
    /* A second STREAMON without a STREAMOFF in between would otherwise reach
     * uvc_alloc_buffers, which frees buffers the kernel still holds as USERPTR.
     * stream_stop is idempotent, so this costs nothing in the normal path. */
    if (u->streaming)
        stream_stop(u);

    int w, h;
    int frame_idx = resolve_streaming(u->commit.bFormatIndex,
                                      u->commit.bFrameIndex, &w, &h);
    u->width = w;
    u->height = h;
    logmsg("stream start %dx%d MJPEG (format %d frame %d)",
           w, h, MJPEG_FORMAT_IDX, frame_idx);

    if (uvc_alloc_buffers(u, w, h) < 0) return -1;

    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.width = (unsigned)w;
    fmt.fmt.pix.height = (unsigned)h;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_MJPEG;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    fmt.fmt.pix.sizeimage = (unsigned)(w * h);
    if (ioctl(u->fd, VIDIOC_S_FMT, &fmt) < 0) {
        logmsg("uvc S_FMT: %s", strerror(errno));
        return -1;
    }

    struct v4l2_requestbuffers req = {0};
    req.count = N_UVC_BUFS;
    req.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    req.memory = V4L2_MEMORY_USERPTR;
    if (ioctl(u->fd, VIDIOC_REQBUFS, &req) < 0) {
        logmsg("uvc REQBUFS: %s", strerror(errno));
        return -1;
    }

    if (rkmpi_venc_start(w, h, DEFAULT_FPS) != 0) {
        logmsg("RK MPI VENC start failed for %dx%d - refusing the stream", w, h);
        return -1;
    }

    /* Fill every UVC buffer before STREAMON so the host has data waiting the
     * moment it polls. Bailing out here rather than limping on matters: a
     * half-filled queue cannot be recovered without tearing the encoder down,
     * and a host that is handed a broken stream reports a working camera with
     * a black picture, which is far harder to diagnose than a clean refusal. */
    for (int i = 0; i < N_UVC_BUFS; i++) {
        size_t sz = 0;
        if (rkmpi_venc_get_frame(u->bufs[i], u->buf_cap, &sz, 1000) != 0) {
            logmsg("RK MPI prefill failed at buffer %d - refusing the stream", i);
            rkmpi_venc_stop();
            return -1;
        }
        u->bytesused[i] = sz;
        if (uvc_qbuf_slot(u, i) < 0) {
            logmsg("uvc queue failed at buffer %d - refusing the stream", i);
            rkmpi_venc_stop();
            return -1;
        }
    }
    logmsg("using RK MPI VI->VENC hardware MJPEG");

    int type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    if (ioctl(u->fd, VIDIOC_STREAMON, &type) < 0) {
        logmsg("uvc STREAMON: %s", strerror(errno));
        return -1;
    }

    u->streaming = 1;
    u->fill_slot = -1;
    u->inflight = N_UVC_BUFS;
    u->frames_in = u->frames_out = u->bytes_out = 0;
    u->stat_frames = u->stat_bytes = u->stat_timeouts = 0;
    clock_gettime(CLOCK_MONOTONIC, &u->stats_ts);
    logmsg("uvc streamon");
    return 0;
}

static void stream_stop(struct uvc_dev *u) {
    if (u->streaming) {
        int type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
        ioctl(u->fd, VIDIOC_STREAMOFF, &type);
        struct v4l2_requestbuffers req = {0};
        req.count = 0;
        req.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
        req.memory = V4L2_MEMORY_USERPTR;
        ioctl(u->fd, VIDIOC_REQBUFS, &req);
        u->streaming = 0;
        logmsg("uvc streamoff (in=%lu out=%lu)", u->frames_in, u->frames_out);
    }

    /* Paused, not torn down: a host that stops the stream is usually about to
     * start it again, and rebuilding the pipeline each time fragments CMA until
     * an allocation fails fatally. The idle check in the main loop releases it
     * once the host really has gone. stream_start's own failure paths still
     * call rkmpi_venc_stop() directly, so a half-built pipeline is never kept. */
    rkmpi_venc_pause();
    uvc_free_buffers(u);
    u->fill_slot = -1;
    u->inflight = 0;
}

static int uvc_try_dqbuf(struct uvc_dev *u) {
    if (u->fill_slot >= 0)
        return 0;
    struct v4l2_buffer buf = {0};
    buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    buf.memory = V4L2_MEMORY_USERPTR;
    if (ioctl(u->fd, VIDIOC_DQBUF, &buf) < 0) {
        if (errno != EAGAIN && errno != ENODEV)
            logmsg("uvc DQBUF: %s", strerror(errno));
        return -1;
    }
    u->frames_out++;
    u->bytes_out += u->bytesused[buf.index];
    u->stat_frames++;
    u->stat_bytes += u->bytesused[buf.index];
    if (u->inflight > 0)
        u->inflight--;
    u->fill_slot = (int)buf.index;
    return 0;
}

static void stream_maybe_log_stats(struct uvc_dev *u) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double elapsed = (now.tv_sec - u->stats_ts.tv_sec) +
                     (now.tv_nsec - u->stats_ts.tv_nsec) / 1e9;
    if (elapsed < 5.0) return;

    double fps = u->stat_frames / elapsed;
    double kbps = (u->stat_bytes * 8.0) / elapsed / 1000.0;
    /* timeouts counts polls where the encoder had no frame ready inside
     * 100 ms, i.e. the sensor/ISP/encoder side starving - nothing to do with
     * USB. fps is measured over the real elapsed interval, so a healthy 1080p
     * stream reads 25.0 because delivery genuinely is the sensor rate. */
    logmsg("streaming: %.1f fps, %.0f kbps, %lu timeouts",
           fps, kbps, u->stat_timeouts);
    u->stat_frames = u->stat_bytes = u->stat_timeouts = 0;
    u->stats_ts = now;
}

/* ---------------- UVC event handlers ---------------- */

static void handle_streaming_get(struct uvc_dev *u, uint8_t cs, uint8_t req,
                                 struct uvc_request_data *resp) {
    if (cs != UVC_VS_PROBE_CONTROL && cs != UVC_VS_COMMIT_CONTROL) {
        resp->length = -EL2HLT;
        return;
    }
    struct uvc_streaming_control *ctrl = (struct uvc_streaming_control *)&resp->data;
    resp->length = (int)sizeof(*ctrl);
    switch (req) {
    case UVC_GET_CUR:
        memcpy(ctrl, (cs == UVC_VS_PROBE_CONTROL) ? &u->probe : &u->commit, sizeof(*ctrl));
        break;
    case UVC_GET_MIN:
    case UVC_GET_DEF:
        uvc_fill_streaming_control(ctrl, 1, FRAME_INTERVAL);
        break;
    case UVC_GET_MAX:
        uvc_fill_streaming_control(ctrl, DEF_FRAME_IDX, 1);
        break;
    case UVC_GET_RES:
        memset(ctrl, 0, sizeof(*ctrl));
        break;
    case UVC_GET_LEN:
        resp->data[0] = 26;     /* UVC 1.0 probe/commit size */
        resp->data[1] = 0x00;
        resp->length = 2;
        break;
    case UVC_GET_INFO:
        resp->data[0] = 0x03;
        resp->length = 1;
        break;
    default:
        resp->length = -EL2HLT;
    }
}

static void handle_control_iface(const struct usb_ctrlrequest *ctrl,
                                 struct uvc_request_data *resp) {
    switch (ctrl->bRequest) {
    case UVC_GET_INFO:
        resp->data[0] = 0x03;
        resp->length = 1;
        break;
    case UVC_GET_LEN:
        resp->data[0] = 0x01;
        resp->data[1] = 0x00;
        resp->length = 2;
        break;
    case UVC_GET_CUR:
    case UVC_GET_MIN:
    case UVC_GET_MAX:
    case UVC_GET_DEF:
    case UVC_GET_RES: {
        unsigned len = ctrl->wLength;
        if (len > sizeof(resp->data)) len = sizeof(resp->data);
        memset(resp->data, 0, len);
        resp->length = (int)len;
        break;
    }
    case UVC_SET_CUR:
        resp->length = (int)ctrl->wLength;
        memset(resp->data, 0, sizeof(resp->data));
        break;
    default:
        resp->length = -EL2HLT;
    }
}

static void handle_setup(struct uvc_dev *u, const struct usb_ctrlrequest *ctrl,
                         struct uvc_request_data *resp) {
    u->control = 0;
    if ((ctrl->bRequestType & USB_TYPE_MASK) != USB_TYPE_CLASS) {
        resp->length = -EL2HLT;
        return;
    }
    if ((ctrl->bRequestType & USB_RECIP_MASK) != USB_RECIP_INTERFACE) {
        resp->length = -EL2HLT;
        return;
    }

    uint8_t intf = ctrl->wIndex & 0xff;
    uint8_t cs = ctrl->wValue >> 8;

    if (intf == 0) {
        handle_control_iface(ctrl, resp);
        return;
    }

    u->control = cs;
    if (ctrl->bRequest == UVC_SET_CUR) {
        resp->length = (int)ctrl->wLength;
        memset(resp->data, 0, sizeof(resp->data));
    } else {
        handle_streaming_get(u, cs, ctrl->bRequest, resp);
    }
}

static void handle_data(struct uvc_dev *u, const struct uvc_request_data *data) {
    if (u->control != UVC_VS_PROBE_CONTROL &&
        u->control != UVC_VS_COMMIT_CONTROL)
        return;
    /* UVC 1.0 hosts (Windows) send 26-byte probe/commit; 1.1 sends 34.
     * All fields we consume live in the first 26 bytes. */
    if ((unsigned)data->length < 26)
        return;

    struct uvc_streaming_control full = {0};
    memcpy(&full, data->data,
           (unsigned)data->length < sizeof(full) ? (unsigned)data->length
                                                 : sizeof(full));
    struct uvc_streaming_control *target =
        (u->control == UVC_VS_PROBE_CONTROL) ? &u->probe : &u->commit;
    const struct uvc_streaming_control *src = &full;

    uvc_apply_host_control(u, target, src);
    if (u->control == UVC_VS_COMMIT_CONTROL) {
        logmsg("uvc COMMIT: MJPEG %dx%d interval %u",
               u->width, u->height, target->dwFrameInterval);
    }
}

/* ---------------- main ---------------- */

static void usage(const char *p) {
    fprintf(stderr,
        "Usage: %s [-u UVC_DEV]\n"
        "  -u UVC_DEV  UVC gadget V4L2 OUTPUT. Default: auto-discover.\n"
        "MJPEG %dx%d, %dx%d, %dx%d, %dx%d @ %d fps, hardware encoded.\n",
        p, 640, 360, 1280, 720, 1920, 1080, 2304, 1296, DEFAULT_FPS);
}

int main(int argc, char **argv) {
    int opt;
    while ((opt = getopt(argc, argv, "u:h")) != -1) {
        switch (opt) {
        case 'u': g_uvc_dev = optarg; break;
        case 'h': usage(argv[0]); return 0;
        default:  usage(argv[0]); return 1;
        }
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    char *uvc_path = NULL;
    if (!g_uvc_dev) {
        uvc_path = find_uvc_node();
        if (!uvc_path) {
            logmsg("could not find UVC gadget node — is it bound?");
            return 1;
        }
        g_uvc_dev = uvc_path;
    }
    logmsg("using uvc=%s", g_uvc_dev);

    struct uvc_dev uvc = {.fd = -1};

    if (uvc_open(&uvc, g_uvc_dev) < 0) goto out;

    while (!g_stop) {
        struct pollfd pfds[1];
        int npfd = 1;
        pfds[0].fd = uvc.fd;
        pfds[0].events = POLLPRI;
        if (uvc.streaming) {
            /* POLLOUT reclaims a buffer the host has finished with. Only worth
             * waiting for when one is actually out and there is nowhere to put
             * the next encoded frame. */
            if (uvc.fill_slot < 0 && uvc.inflight > 0)
                pfds[0].events |= POLLOUT;
        }

        int poll_ms = uvc.streaming ? 50 : 1000;

        int r = poll(pfds, npfd, poll_ms);
        if (r < 0) {
            if (errno == EINTR) continue;
            logmsg("poll: %s", strerror(errno));
            break;
        }

        if (pfds[0].revents & POLLPRI) {
            struct v4l2_event ev = {0};
            while (ioctl(uvc.fd, VIDIOC_DQEVENT, &ev) == 0) {
                struct uvc_request_data resp = {.length = -EL2HLT};
                switch (ev.type) {
                case UVC_EVENT_DISCONNECT:
                    logmsg("uvc DISCONNECT");
                    stream_stop(&uvc);
                    break;
                case UVC_EVENT_STREAMON:
                    logmsg("uvc STREAMON event");
                    if (stream_start(&uvc) < 0)
                        stream_stop(&uvc);
                    break;
                case UVC_EVENT_STREAMOFF:
                    logmsg("uvc STREAMOFF event");
                    stream_stop(&uvc);
                    break;
                case UVC_EVENT_SETUP: {
                    struct usb_ctrlrequest *req =
                        &((struct uvc_event *)&ev.u.data)->req;
                    handle_setup(&uvc, req, &resp);
                    if (ioctl(uvc.fd, UVCIOC_SEND_RESPONSE, &resp) < 0)
                        logmsg("UVCIOC_SEND_RESPONSE: %s", strerror(errno));
                    break;
                }
                case UVC_EVENT_DATA: {
                    struct uvc_request_data *d =
                        &((struct uvc_event *)&ev.u.data)->data;
                    handle_data(&uvc, d);
                    break;
                }
                default:
                    break;
                }
            }
        }

        if (uvc.streaming) {
            if (pfds[0].revents & POLLOUT)
                uvc_try_dqbuf(&uvc);

            if (uvc.fill_slot >= 0) {
                size_t sz = 0;
                int ret = rkmpi_venc_get_frame(uvc.bufs[uvc.fill_slot],
                        uvc.buf_cap, &sz, 100);
                if (ret == 0) {
                    uvc.bytesused[uvc.fill_slot] = sz;
                    if (uvc_qbuf_slot(&uvc, uvc.fill_slot) == 0) {
                        uvc.frames_in++;
                        uvc.fill_slot = -1;
                    }
                } else if (ret == 1) {
                    uvc.stat_timeouts++;
                }
            }

            stream_maybe_log_stats(&uvc);
        } else {
            /* Nothing is watching. Release the pipeline once the host has been
             * away long enough that this is not simply another restart. */
            int idle = rkmpi_venc_idle_ms();
            if (idle >= 0 && idle > VENC_IDLE_MS) {
                logmsg("encoder idle %d ms, releasing pipeline", idle);
                rkmpi_venc_stop();
            }
        }
    }

    logmsg("shutting down");
out:
    stream_stop(&uvc);
    rkmpi_venc_shutdown();
    if (uvc.fd >= 0) close(uvc.fd);
    free(uvc_path);
    return 0;
}
