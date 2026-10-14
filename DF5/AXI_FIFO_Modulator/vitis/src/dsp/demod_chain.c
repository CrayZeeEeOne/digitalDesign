#include "dsp/demod_chain.h"

void demod_chain_init(demod_chain_t *c, uint16_t nco_inc)
{
    uint32_t n;

    for (n = 0u; n < sizeof(*c); n++) ((uint8_t *)c)[n] = 0u;
    nco_mixer_init(&c->nco, nco_inc);
    burst_detect_init(&c->bd);
}

void demod_chain_step(demod_chain_t *c, int16_t i, int16_t q, demod_sample_t *o)
{
    o->i = i;
    o->q = q;
    nco_mixer_step(&c->nco, i, q, &o->mi, &o->mq);

    o->dec_valid = (uint8_t)decimator_push(&c->dec, o->mi, o->mq, &o->di, &o->dq);
    if (!o->dec_valid) return;

    o->dec_count = ++c->dec_count;
    o->dphi = discriminator_step(&c->disc, o->di, o->dq);
    o->burst_rise = (uint8_t)burst_detect_step(&c->bd, o->di, o->dq);
    o->pavg = c->bd.pavg;
    o->noise = c->bd.noise;
    o->flags = bit_decoder_step(&c->bit, o->dphi, c->bd.burst, o->burst_rise, o->dec_count);
    o->favg = c->bit.favg;
    o->dev = c->bit.dev;
}
