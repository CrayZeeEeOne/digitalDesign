/*
 * keys.h -- two buttons, short press vs hold.
 *
 *   K1 short press  -> KEY_NEXT       (next screen)
 *   K2 short press  -> KEY_ZOOM       (x1 -> x2 -> x4 -> x8 -> x16 -> x1)
 *   K1 held         -> KEY_PAN_BACK   repeated while held (towards the start)
 *   K2 held         -> KEY_PAN_FWD    repeated while held (towards the end)
 *   K1 + K2 together -> KEY_BOTH      once (nothing else until both are released)
 *
 * A press counts as "short" if released before KEYS_HOLD_MS; the short action
 * fires on release, so a hold never also changes the screen or the zoom.
 */
#ifndef KEYS_H
#define KEYS_H

#include <stdint.h>

#define KEYS_HOLD_MS    400u
#define KEYS_REPEAT_MS  120u

typedef enum {
    KEY_NONE = 0,
    KEY_NEXT,
    KEY_ZOOM,
    KEY_PAN_BACK,
    KEY_PAN_FWD,
    KEY_BOTH
} key_action_t;

typedef struct {
    uint8_t down[2];
    uint8_t held[2];
    uint32_t t_down[2];
    uint32_t t_rep[2];
    uint8_t chord;             /* both keys went down: wait for both to be released */
} keys_t;

void keys_init(keys_t *k);

/* pressed: bit 0 = K1, bit 1 = K2 (debounced). now_ms: free-running milliseconds. */
key_action_t keys_poll(keys_t *k, uint32_t pressed, uint32_t now_ms);

#endif
