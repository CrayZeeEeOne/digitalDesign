/* sd_host_stub.c -- host build: an SD bus with no card on it (every command
   times out), so the SD CARD screen shows "no card". */
#include "hal/sd_host.h"

int sd_host_init(sd_host_t *h, uint32_t base) { h->base = base; h->ctrl = 0u; return 0; }
void sd_host_clock(sd_host_t *h, uint8_t div, uint8_t sdly, int free) { (void)h; (void)div; (void)sdly; (void)free; }
uint32_t sd_host_cmd(sd_host_t *h, uint8_t idx, uint32_t arg, int rsp, int busy, int crc, int data)
{
    (void)h; (void)idx; (void)arg; (void)rsp; (void)busy; (void)crc; (void)data;
    return SDH_ST_CMD_TMO;
}
uint32_t sd_host_resp(const sd_host_t *h, int word) { (void)h; (void)word; return 0u; }
void sd_host_buf_read(const sd_host_t *h, uint8_t *dst) { uint32_t i; (void)h; for (i = 0u; i < 512u; i++) dst[i] = 0xFFu; }
void sd_host_buf_write(const sd_host_t *h, const uint8_t *src) { (void)h; (void)src; }
void sd_host_stream_format(sd_host_t *h, uint32_t rate, int fmt8) { (void)h; (void)rate; (void)fmt8; }
void sd_host_stream(sd_host_t *h, uint32_t lba, uint32_t count) { (void)h; (void)lba; (void)count; }
void sd_host_stream_stop(sd_host_t *h) { (void)h; }
void sd_host_stream_flush(sd_host_t *h) { (void)h; }
int sd_host_stream_busy(const sd_host_t *h) { (void)h; return 0; }
uint32_t sd_host_status(const sd_host_t *h) { (void)h; return 0u; }
uint32_t sd_host_out_count(const sd_host_t *h) { (void)h; return 0u; }
void sd_host_out_clear(sd_host_t *h) { (void)h; }
uint32_t sd_host_underruns(const sd_host_t *h) { (void)h; return 0u; }
