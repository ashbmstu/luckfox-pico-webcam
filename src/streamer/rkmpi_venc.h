#ifndef RKMPI_VENC_H
#define RKMPI_VENC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int rkmpi_venc_start(int width, int height, int fps);
int rkmpi_venc_get_frame(uint8_t *out, size_t cap, size_t *out_size, int timeout_ms);
void rkmpi_venc_pause(void);
int rkmpi_venc_idle_ms(void);
void rkmpi_venc_stop(void);
void rkmpi_venc_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
