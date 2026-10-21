#include "app/view_sd.h"
#include "gfx/plot.h"

#define LINE_H 11u

static const char *type_name(uint8_t t)
{
    switch (t) {
    case SD_TYPE_V1:    return "SD V1 (SDSC)";
    case SD_TYPE_V2_SC: return "SD V2 (SDSC)";
    case SD_TYPE_SDHC:  return "SDHC/SDXC";
    default:            return "-";
    }
}

static char hex_digit(uint8_t v) { return (char)(v < 10u ? '0' + (int)v : 'A' + (int)v - 10); }

/* Simple line builder: append text / numbers to a buffer. */
typedef struct { char buf[56]; char *p; } line_t;

static void l_start(line_t *l) { l->p = l->buf; *l->p = '\0'; }
static void l_str(line_t *l, const char *s) { while (*s && l->p < l->buf + sizeof(l->buf) - 1) *l->p++ = *s++; *l->p = '\0'; }
static void l_u32(line_t *l, uint32_t v) { char t[12]; plot_u32_to_str(t, v); l_str(l, t); }
static void l_hex8(line_t *l, uint8_t v) { char t[3] = { hex_digit((uint8_t)(v >> 4)), hex_digit((uint8_t)(v & 15u)), 0 }; l_str(l, t); }

/* Capacity as "7.4 GB" / "512 MB". */
static void l_size(line_t *l, uint32_t sectors)
{
    uint32_t mb = sectors / 2048u;

    if (mb >= 1024u) {
        l_u32(l, mb / 1024u);
        l_str(l, ".");
        l_u32(l, (mb % 1024u) * 10u / 1024u);
        l_str(l, " GB");
    } else {
        l_u32(l, mb);
        l_str(l, " MB");
    }
}

void view_sd_formatting(tft_t *tft)
{
    tft_clear(tft, TFT_BLACK);
    tft_draw_rect(tft, 0, 0, tft->w, tft->h, TFT_RED);
    tft_draw_text(tft, 20, 80, "FORMATTING", TFT_WHITE, TFT_BLACK, 2);
    tft_draw_text(tft, 20, 110, "FAT32, WHOLE CARD. DO NOT REMOVE THE CARD.", TFT_YELLOW, TFT_BLACK, 1);
}

/* Last line: result of the last format, or how to start one. */
static void format_line(tft_t *tft, uint16_t x, uint16_t y, const sd_format_result_t *f)
{
    line_t l;

    l_start(&l);
    if (!f || !f->done) {
        tft_draw_text(tft, x, y, "HOLD K2 3 S: FORMAT FAT32 (ERASES THE CARD)", TFT_GRAY, TFT_BLACK, 1);
        return;
    }
    if (f->ok) {
        l_str(&l, "FORMAT OK: FAT");
        l_u32(&l, f->fat_bits);
        l_str(&l, ", ");
        l_u32(&l, f->ms / 1000u);
        l_str(&l, " S, TEST FILE WRITTEN + READ BACK");
        tft_draw_text(tft, x, y, l.buf, TFT_GREEN, TFT_BLACK, 1);
    } else {
        l_str(&l, "FORMAT FAILED AT ");
        l_str(&l, f->step);
        l_str(&l, ": ");
        l_str(&l, sd_fresult_text(f->fr));
        tft_draw_text(tft, x, y, l.buf, TFT_RED, TFT_BLACK, 1);
    }
}

void view_sd(tft_t *tft, const sd_info_t *s, const sd_format_result_t *fmt)
{
    uint16_t x = 8u, y = 32u;
    line_t l;
    uint8_t i;

    if (!s) return;
    format_line(tft, x, (uint16_t)(tft->h - 14u), fmt);

    l_start(&l);
    l_str(&l, "CARD:  ");
    l_str(&l, type_name(s->type));
    if (s->sectors) { l_str(&l, "  "); l_size(&l, s->sectors); }
    tft_draw_text(tft, x, y, l.buf, TFT_WHITE, TFT_BLACK, 1);
    y += LINE_H;

    if (s->err != SD_OK || s->fat_bits == 0u) {
        l_start(&l);
        l_str(&l, "ERROR: ");
        l_str(&l, s->step);
        l_str(&l, ": ");
        l_str(&l, s->err != SD_OK ? sd_err_text(s->err) : "NOT A FAT VOLUME");
        tft_draw_text(tft, x, y, l.buf, TFT_RED, TFT_BLACK, 1);
        y += LINE_H;
        l_start(&l);
        l_str(&l, "LAST R1: ");
        l_hex8(&l, s->last_r1);
        if (s->err == SD_ERR_NO_CARD) l_str(&l, "  (FF = NO ANSWER)");
        tft_draw_text(tft, x, y, l.buf, TFT_GRAY, TFT_BLACK, 1);
        y += 2u * LINE_H;
        tft_draw_text(tft, x, y, "K2: TEST AGAIN", TFT_YELLOW, TFT_BLACK, 1);
        return;
    }

    l_start(&l);
    if (s->part_type) {
        l_str(&l, "MBR:   PART 1 TYPE ");
        l_hex8(&l, s->part_type);
        l_str(&l, "  AT BLOCK ");
        l_u32(&l, s->part_lba);
    } else {
        l_str(&l, "MBR:   NONE, FAT AT BLOCK 0");
    }
    tft_draw_text(tft, x, y, l.buf, TFT_WHITE, TFT_BLACK, 1);
    y += LINE_H;

    l_start(&l);
    l_str(&l, "FS:    FAT");
    l_u32(&l, s->fat_bits);
    l_str(&l, "  CLUSTER ");
    l_u32(&l, s->cluster_bytes / 1024u);
    l_str(&l, " KB  LABEL ");
    l_str(&l, s->label[0] ? s->label : "-");
    tft_draw_text(tft, x, y, l.buf, TFT_WHITE, TFT_BLACK, 1);
    y += LINE_H;

    l_start(&l);
    l_str(&l, "READ:  ");
    l_u32(&l, s->read_kbps);
    l_str(&l, " KB/S (512 B BLOCKS)");
    tft_draw_text(tft, x, y, l.buf, TFT_GREEN, TFT_BLACK, 1);
    y += LINE_H + 6u;

    tft_draw_text(tft, x, y, "ROOT DIRECTORY (8.3 NAMES):", TFT_YELLOW, TFT_BLACK, 1);
    y += LINE_H;
    if (s->nfiles == 0u)
        tft_draw_text(tft, x, y, "(EMPTY)", TFT_GRAY, TFT_BLACK, 1);
    for (i = 0u; i < s->nfiles; i++) {
        l_start(&l);
        l_str(&l, s->name[i]);
        while (l.p < l.buf + 14) { *l.p++ = ' '; *l.p = '\0'; }
        if (s->is_dir[i]) l_str(&l, "<DIR>");
        else { l_u32(&l, s->size[i]); l_str(&l, " B"); }
        tft_draw_text(tft, x, y, l.buf, TFT_CYAN, TFT_BLACK, 1);
        y += LINE_H;
    }
}
