/*
 * rkmpi_venc.c — RK MPI VI→VENC bind MJPEG encoder (hardware path).
 *
 * Initialises the Rockchip camera pipeline, binds VI to VENC, and delivers
 * MJPEG frames from kernel zero-copy buffers to the caller.
 */

#include "rkmpi_venc.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

#include "rk_comm_rc.h"
#include "rk_comm_venc.h"
#include "rk_comm_vi.h"
#include "rk_mpi_mb.h"
#include "rk_mpi_sys.h"
#include "rk_mpi_venc.h"
#include "rk_mpi_vi.h"

#define RKLOG(fmt, ...) fprintf(stderr, "[rkmpi] " fmt "\n", ##__VA_ARGS__)

#define VI_DEV_ID   0
#define VI_CHN_ID   0
#define VENC_CHN_ID 0
#define JPEG_Q_FACTOR 80

static int g_sys_init;
static int g_running;

/* Geometry of the pipeline currently built, so that a restart at the same size
 * can reuse it instead of tearing everything down and building it again. See
 * rkmpi_venc_pause() for why that matters. */
static int g_w, g_h, g_fps;
static int g_paused;
static struct timespec g_pause_ts;
/* One-shot copy of the first encoded frame this process produces, written to
 * /tmp/venc-first.jpg for support reports. Once per run, not once per stream. */
static int g_dumped;

static VENC_PACK_S g_pack;

static int vi_dev_init(void)
{
    int ret;
    int devId = VI_DEV_ID;
    int pipeId = devId;
    VI_DEV_ATTR_S stDevAttr;
    VI_DEV_BIND_PIPE_S stBindPipe;

    memset(&stDevAttr, 0, sizeof(stDevAttr));
    memset(&stBindPipe, 0, sizeof(stBindPipe));

    ret = RK_MPI_VI_GetDevAttr(devId, &stDevAttr);
    if (ret == RK_ERR_VI_NOT_CONFIG) {
        ret = RK_MPI_VI_SetDevAttr(devId, &stDevAttr);
        if (ret != RK_SUCCESS) {
            RKLOG("RK_MPI_VI_SetDevAttr %x", ret);
            return -1;
        }
    }

    ret = RK_MPI_VI_GetDevIsEnable(devId);
    if (ret != RK_SUCCESS) {
        ret = RK_MPI_VI_EnableDev(devId);
        if (ret != RK_SUCCESS) {
            RKLOG("RK_MPI_VI_EnableDev %x", ret);
            return -1;
        }
        stBindPipe.u32Num = 1;
        stBindPipe.PipeId[0] = pipeId;
        ret = RK_MPI_VI_SetDevBindPipe(devId, &stBindPipe);
        if (ret != RK_SUCCESS) {
            RKLOG("RK_MPI_VI_SetDevBindPipe %x", ret);
            return -1;
        }
    }

    return 0;
}

static int vi_chn_init(int width, int height)
{
    int ret;
    VI_CHN_ATTR_S vi_chn_attr;

    memset(&vi_chn_attr, 0, sizeof(vi_chn_attr));
    /* Two NV12 buffers, not three. At 2304x1296 each is 4374 kB of CMA, out of
     * a 24576 kB region shared with the encoder's w*h buffers and the ISP's own
     * working set. Measured with two, a soak of restarts across all four modes
     * peaks at 18336 kB, leaving 6240 kB for a 2916 kB contiguous request; the
     * third buffer would spend most of what is left. Two is also the minimum a
     * bound VI->VENC pipeline needs - one filling while the other encodes.
     * Verified at 25.0 fps with 0 timeouts at 2304x1296; if that ever
     * regresses, this is the first thing to look at. */
    vi_chn_attr.stIspOpt.u32BufCount = 2;
    vi_chn_attr.stIspOpt.enMemoryType = VI_V4L2_MEMORY_TYPE_DMABUF;
    vi_chn_attr.stSize.u32Width = (RK_U32)width;
    vi_chn_attr.stSize.u32Height = (RK_U32)height;
    vi_chn_attr.enPixelFormat = RK_FMT_YUV420SP;
    vi_chn_attr.enCompressMode = COMPRESS_MODE_NONE;
    vi_chn_attr.u32Depth = 0;

    ret = RK_MPI_VI_SetChnAttr(VI_DEV_ID, VI_CHN_ID, &vi_chn_attr);
    if (ret != RK_SUCCESS) {
        RKLOG("RK_MPI_VI_SetChnAttr %x", ret);
        return -1;
    }
    ret = RK_MPI_VI_EnableChn(VI_DEV_ID, VI_CHN_ID);
    if (ret != RK_SUCCESS) {
        RKLOG("RK_MPI_VI_EnableChn %x", ret);
        return -1;
    }
    return 0;
}

static int venc_init(int width, int height, int fps)
{
    VENC_RECV_PIC_PARAM_S stRecvParam;
    VENC_CHN_ATTR_S stAttr;

    memset(&stAttr, 0, sizeof(stAttr));
    stAttr.stRcAttr.enRcMode = VENC_RC_MODE_MJPEGFIXQP;
    stAttr.stRcAttr.stMjpegFixQp.u32SrcFrameRateNum = (RK_U32)fps;
    stAttr.stRcAttr.stMjpegFixQp.u32SrcFrameRateDen = 1;
    stAttr.stRcAttr.stMjpegFixQp.fr32DstFrameRateNum = (RK_U32)fps;
    stAttr.stRcAttr.stMjpegFixQp.fr32DstFrameRateDen = 1;
    stAttr.stRcAttr.stMjpegFixQp.u32Qfactor = JPEG_Q_FACTOR;

    stAttr.stVencAttr.enType = RK_VIDEO_ID_MJPEG;
    stAttr.stVencAttr.enPixelFormat = RK_FMT_YUV420SP;
    stAttr.stVencAttr.u32PicWidth = (RK_U32)width;
    stAttr.stVencAttr.u32PicHeight = (RK_U32)height;
    stAttr.stVencAttr.u32VirWidth = (RK_U32)width;
    stAttr.stVencAttr.u32VirHeight = (RK_U32)height;
    stAttr.stVencAttr.u32StreamBufCnt = 2;

    /* Size of each MJPEG output buffer, and it has to be w*h even though the
     * encoder never emits anything close to that. Measured output is about 0.08
     * bytes per pixel, so w/2 looks like a four to six fold margin - but at
     * w*h/2 the hardware raises
     *
     *   rkvenc_540c: jpeg overflow
     *   hal_jpege_v540c:hal_jpege_vepu540c_status_check:480: JPEG BIT_STREAM_OVERFLOW
     *
     * on frames of about 250 kB. The VEPU sizes its own requirement from the
     * pixel count rather than from what it produces, so this is a hardware
     * minimum, not a heuristic worth tuning. The CMA pressure it causes is dealt
     * with in vi_chn_init and by keeping the pipeline across restarts instead.
     */
    stAttr.stVencAttr.u32BufSize = (RK_U32)width * (RK_U32)height;
    stAttr.stVencAttr.enMirror = MIRROR_NONE;

    if (RK_MPI_VENC_CreateChn(VENC_CHN_ID, &stAttr) != RK_SUCCESS) {
        RKLOG("RK_MPI_VENC_CreateChn failed");
        return -1;
    }

    memset(&stRecvParam, 0, sizeof(stRecvParam));
    stRecvParam.s32RecvPicNum = -1;
    if (RK_MPI_VENC_StartRecvFrame(VENC_CHN_ID, &stRecvParam) != RK_SUCCESS) {
        RKLOG("RK_MPI_VENC_StartRecvFrame failed");
        RK_MPI_VENC_DestroyChn(VENC_CHN_ID);
        return -1;
    }
    return 0;
}

static void bind_pair(MPP_CHN_S *src, MPP_CHN_S *dst)
{
    src->enModId = RK_ID_VI;
    src->s32DevId = VI_DEV_ID;
    src->s32ChnId = VI_CHN_ID;

    dst->enModId = RK_ID_VENC;
    dst->s32DevId = 0;
    dst->s32ChnId = VENC_CHN_ID;
}

static int vi_bind_venc(void)
{
    MPP_CHN_S stSrcChn, stDestChn;
    RK_S32 ret;

    bind_pair(&stSrcChn, &stDestChn);
    ret = RK_MPI_SYS_Bind(&stSrcChn, &stDestChn);
    if (ret != RK_SUCCESS) {
        RKLOG("RK_MPI_SYS_Bind %x", ret);
        return -1;
    }
    return 0;
}

static void vi_unbind_venc(void)
{
    MPP_CHN_S stSrcChn, stDestChn;

    bind_pair(&stSrcChn, &stDestChn);
    if (RK_MPI_SYS_UnBind(&stSrcChn, &stDestChn) != RK_SUCCESS)
        RKLOG("RK_MPI_SYS_UnBind failed");
}

/* Defined below, next to the other stream handling. */
static void venc_drain(void);

int rkmpi_venc_start(int width, int height, int fps)
{
    /* A paused pipeline of the right shape is reused rather than rebuilt. This
     * is what keeps the camera alive: building the pipeline allocates the VI
     * NV12 pool and the encoder buffers from CMA, which at 2304x1296 is around
     * 18 MB of a 24 MB region, and doing that on every stream start fragments
     * CMA until a contiguous allocation cannot be found. When that happens the
     * vendor mpp_vcodec module starts the encoder on a channel it failed to
     * create and oopses, killing this process while the USB gadget is bound,
     * which takes the whole device down. Hosts restart the stream constantly -
     * Media Foundation does it three times for a single photo - so the restarts
     * cannot be avoided, only stopped from churning CMA. */
    if (g_running && !g_paused && width == g_w && height == g_h && fps == g_fps)
        return 0;

    if (g_running && width == g_w && height == g_h && fps == g_fps) {
        /* Drain the stale frames, then let the encoder receive again. The bind
         * is still up, so nothing else is needed. */
        venc_drain();
        if (RK_MPI_VENC_StartRecvFrame(VENC_CHN_ID, &(VENC_RECV_PIC_PARAM_S){
                .s32RecvPicNum = -1 }) != RK_SUCCESS) {
            RKLOG("StartRecvFrame on resume failed, rebuilding");
            rkmpi_venc_stop();
        } else {
            g_paused = 0;
            RKLOG("resume ok %dx%d @ %d fps (pipeline reused)", width, height, fps);
            return 0;
        }
    }

    /* Different geometry, or the pipeline is not up: build it. */
    if (g_running)
        rkmpi_venc_stop();

    if (!g_sys_init) {
        if (RK_MPI_SYS_Init() != RK_SUCCESS) {
            RKLOG("RK_MPI_SYS_Init failed");
            return -1;
        }
        g_sys_init = 1;
        memset(&g_pack, 0, sizeof(g_pack));
    }

    if (vi_dev_init() < 0)
        goto fail;
    if (vi_chn_init(width, height) < 0)
        goto fail;
    if (venc_init(width, height, fps) < 0)
        goto fail;
    if (vi_bind_venc() < 0)
        goto fail;

    g_running = 1;
    g_paused = 0;
    g_w = width;
    g_h = height;
    g_fps = fps;
    RKLOG("start ok %dx%d @ %d fps", width, height, fps);
    return 0;

fail:
    rkmpi_venc_stop();
    return -1;
}

/* Discard whatever the encoder still holds. Called when resuming a paused
 * pipeline, so the host is not handed frames of a scene from before the pause.
 * Bounded because u32StreamBufCnt frames is all there can be. */
static void venc_drain(void)
{
    VENC_STREAM_S stFrame;
    int n;

    for (n = 0; n < 8; n++) {
        memset(&stFrame, 0, sizeof(stFrame));
        stFrame.pstPack = &g_pack;
        if (RK_MPI_VENC_GetStream(VENC_CHN_ID, &stFrame, 0) != RK_SUCCESS)
            return;
        RK_MPI_VENC_ReleaseStream(VENC_CHN_ID, &stFrame);
    }
}

int rkmpi_venc_get_frame(uint8_t *out, size_t cap, size_t *out_size, int timeout_ms)
{
    VENC_STREAM_S stFrame;
    void *pData;
    RK_S32 ret;

    if (!g_running || !out || !out_size)
        return -1;

    memset(&stFrame, 0, sizeof(stFrame));
    stFrame.pstPack = &g_pack;

    ret = RK_MPI_VENC_GetStream(VENC_CHN_ID, &stFrame, timeout_ms);
    if (ret == RK_SUCCESS) {
        if (!stFrame.pstPack || stFrame.pstPack->u32Len == 0) {
            RK_MPI_VENC_ReleaseStream(VENC_CHN_ID, &stFrame);
            return -1;
        }
        if (stFrame.pstPack->u32Len > cap) {
            RKLOG("frame %u bytes exceeds cap %zu, dropping",
                  stFrame.pstPack->u32Len, cap);
            RK_MPI_VENC_ReleaseStream(VENC_CHN_ID, &stFrame);
            return -1;
        }
        pData = RK_MPI_MB_Handle2VirAddr(stFrame.pstPack->pMbBlk);
        if (!pData) {
            RKLOG("Handle2VirAddr failed");
            RK_MPI_VENC_ReleaseStream(VENC_CHN_ID, &stFrame);
            return -1;
        }
        memcpy(out, pData, stFrame.pstPack->u32Len);
        *out_size = stFrame.pstPack->u32Len;
        if (!g_dumped) {
            FILE *fp = fopen("/tmp/venc-first.jpg", "wb");
            if (fp) {
                fwrite(pData, 1, stFrame.pstPack->u32Len, fp);
                fclose(fp);
            }
            g_dumped = 1;
        }
        ret = RK_MPI_VENC_ReleaseStream(VENC_CHN_ID, &stFrame);
        if (ret != RK_SUCCESS) {
            RKLOG("ReleaseStream %x", ret);
            return -1;
        }
        return 0;
    }

    if (ret == RK_ERR_VENC_BUF_EMPTY)
        return 1;

    RKLOG("GetStream %x", ret);
    return -1;
}

/* Stop producing frames but keep the channels, and with them their CMA
 * allocations. This is what a host stopping the stream now does; the pipeline
 * is only really torn down once the host has stayed away (see
 * rkmpi_venc_idle_ms) or asks for a different size. */
void rkmpi_venc_pause(void)
{
    if (!g_running || g_paused)
        return;

    /* Stop the encoder but leave the VI->VENC bind alone. VI carries on pushing
     * frames into a stopped encoder, which the hardware reports once per frame:
     *   rkvenc_540c: jpeg overflow
     *   hal_jpege_v540c:...: JPEG BIT_STREAM_OVERFLOW
     *   mpp_vcodec: enc 0 handle int err
     * That is noisy - thousands of lines across a long session - but harmless:
     * 144 stream cycles ran through it at 25.0 fps with 0 timeouts and no
     * allocation failure. Unbinding here to silence it does NOT work: the
     * matching RK_MPI_SYS_Bind on the next resume never returns, and the board
     * hangs on the first restart. Measured, not assumed. */
    if (RK_MPI_VENC_StopRecvFrame(VENC_CHN_ID) != RK_SUCCESS)
        RKLOG("StopRecvFrame on pause failed");
    g_paused = 1;
    clock_gettime(CLOCK_MONOTONIC, &g_pause_ts);
}

/* Milliseconds since the pipeline was paused, or -1 if it is not paused - so
 * either nothing is built, or a host is streaming right now. */
int rkmpi_venc_idle_ms(void)
{
    struct timespec now;

    if (!g_running || !g_paused)
        return -1;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int)((now.tv_sec - g_pause_ts.tv_sec) * 1000 +
                 (now.tv_nsec - g_pause_ts.tv_nsec) / 1000000L);
}

void rkmpi_venc_stop(void)
{
    RK_S32 ret;

    if (!g_running && !g_sys_init)
        return;

    vi_unbind_venc();

    ret = RK_MPI_VI_DisableChn(VI_DEV_ID, VI_CHN_ID);
    if (ret != RK_SUCCESS && g_running)
        RKLOG("VI_DisableChn %x", ret);

    ret = RK_MPI_VENC_StopRecvFrame(VENC_CHN_ID);
    if (ret != RK_SUCCESS && g_running)
        RKLOG("VENC_StopRecvFrame %x", ret);

    ret = RK_MPI_VENC_DestroyChn(VENC_CHN_ID);
    if (ret != RK_SUCCESS && g_running)
        RKLOG("VENC_DestroyChn %x", ret);

    ret = RK_MPI_VI_DisableDev(VI_DEV_ID);
    if (ret != RK_SUCCESS && g_running)
        RKLOG("VI_DisableDev %x", ret);

    g_running = 0;
    g_paused = 0;
    g_w = g_h = g_fps = 0;
}

void rkmpi_venc_shutdown(void)
{
    rkmpi_venc_stop();
    if (g_sys_init) {
        RK_MPI_SYS_Exit();
        g_sys_init = 0;
    }
}
