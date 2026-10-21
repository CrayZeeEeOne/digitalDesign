#include "dsp/demod_chain.h"

void demod_chain_init(demod_chain_t *c, uint16_t nco_inc, uint16_t bit_inc)
{
    uint32_t n;

    for (n = 0u; n < sizeof(*c); n++) ((uint8_t *)c)[n] = 0u;
    nco_mixer_init(&c->nco, nco_inc);
    burst_detect_init(&c->bd);
    bit_decoder_init(&c->bit, bit_inc);
}

void demod_chain_step(demod_chain_t *c, int16_t i, int16_t q, demod_sample_t *o)
{
    uint8_t was_burst;

    o->i = i;
    o->q = q;
    o->burst_rise = o->burst_fall = o->bit_valid = o->bit = 0u;
    nco_mixer_step(&c->nco, i, q, &o->mi, &o->mq);

    o->dec_valid = (uint8_t)decimator_push(&c->dec, o->mi, o->mq, &o->di, &o->dq);
    if (!o->dec_valid) return;

    o->dphi = discriminator_step(&c->disc, o->di, o->dq);

    was_burst = c->bd.burst;
    burst_detect_step(&c->bd, o->di, o->dq);
    o->burst = c->bd.burst;
    o->burst_rise = (uint8_t)(o->burst && !was_burst);
    o->burst_fall = (uint8_t)(!o->burst && was_burst);

    if (o->burst_rise) bit_decoder_start(&c->bit);
    o->bit_valid = (uint8_t)(o->burst && bit_decoder_step(&c->bit, o->dphi, &o->bit));
}
