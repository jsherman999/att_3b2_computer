/* C interface to the DMD 5620 core (dmd_ffi/src/lib.rs). */
#ifndef ATT_DMD_H
#define ATT_DMD_H
#include <stddef.h>
#include <stdint.h>

#define ATT_DMD_WIDTH 800
#define ATT_DMD_HEIGHT 1024
#define ATT_DMD_VIDEO_BYTES (100 * 1024)
#define ATT_DMD_NVRAM_BYTES 8192

typedef struct AttDmd AttDmd;

AttDmd *att_dmd_create(void);
void att_dmd_destroy(AttDmd *h);
int att_dmd_reset(AttDmd *h);
void att_dmd_run(AttDmd *h, uint32_t steps);
uint8_t att_dmd_copy_video(AttDmd *h, uint8_t *out, size_t len);
void att_dmd_rx_char(AttDmd *h, uint8_t c);
void att_dmd_rx_keyboard(AttDmd *h, uint8_t c);
void att_dmd_mouse_move(AttDmd *h, uint16_t x, uint16_t y);
void att_dmd_mouse_down(AttDmd *h, uint8_t button);
void att_dmd_mouse_up(AttDmd *h, uint8_t button);
size_t att_dmd_rs232_tx(AttDmd *h, uint8_t *out, size_t max);
int att_dmd_kb_tx(AttDmd *h);
void att_dmd_set_nvram(AttDmd *h, const uint8_t *data);
void att_dmd_get_nvram(AttDmd *h, uint8_t *out);

#endif
