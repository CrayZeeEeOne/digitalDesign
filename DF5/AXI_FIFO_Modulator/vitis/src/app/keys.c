#include "app/keys.h"

static const key_action_t short_action[2] = { KEY_NEXT, KEY_ZOOM };
static const key_action_t hold_action[2]  = { KEY_PAN_BACK, KEY_PAN_FWD };

void keys_init(keys_t *k)
{
    uint32_t n;
    for (n = 0u; n < sizeof(*k); n++) ((uint8_t *)k)[n] = 0u;
}

key_action_t keys_poll(keys_t *k, uint32_t pressed, uint32_t now_ms)
{
    int i;

    /* both down: one KEY_BOTH, then nothing until both are released */
    if ((pressed & 3u) == 3u && !k->chord) {
        k->chord = 1u;
        return KEY_BOTH;
    }
    if (k->chord) {
        if ((pressed & 3u) == 0u) {
            k->chord = 0u;
            k->down[0] = k->down[1] = 0u;
        }
        return KEY_NONE;
    }

    for (i = 0; i < 2; i++) {
        uint8_t is_down = (uint8_t)((pressed >> i) & 1u);

        if (is_down && !k->down[i]) {
            k->down[i] = 1u;
            k->held[i] = 0u;
            k->t_down[i] = now_ms;
        } else if (is_down) {
            if (!k->held[i] && now_ms - k->t_down[i] >= KEYS_HOLD_MS) {
                k->held[i] = 1u;
                k->t_rep[i] = now_ms;
                return hold_action[i];
            }
            if (k->held[i] && now_ms - k->t_rep[i] >= KEYS_REPEAT_MS) {
                k->t_rep[i] = now_ms;
                return hold_action[i];
            }
        } else if (k->down[i]) {
            k->down[i] = 0u;
            if (!k->held[i]) return short_action[i];
        }
    }
    return KEY_NONE;
}
