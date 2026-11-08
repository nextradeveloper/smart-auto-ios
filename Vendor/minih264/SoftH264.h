// Software H.264 (Baseline) for the dash, built on minih264e (CC0, github.com/lieff/minih264).
// The hardware encoder is not available to an app in the background or with the phone locked;
// this runs on the CPU instead.
#ifndef SOFT_H264_H
#define SOFT_H264_H

#include <stdint.h>

typedef struct SoftH264 SoftH264;

/// width and height must be multiples of 16. Returns NULL on failure.
SoftH264 *softh264_create(int width, int height, int bitRate, int frameRate);

/// Encodes one I420 frame. A key frame (SPS + PPS + IDR) when forceKey is non-zero. On success
/// returns 0 and points `out` at Annex-B data owned by the encoder, valid until the next call.
int softh264_encode(SoftH264 *encoder,
                    const uint8_t *y, int strideY,
                    const uint8_t *u, const uint8_t *v, int strideUV,
                    int forceKey,
                    const uint8_t **out, int *outSize);

void softh264_destroy(SoftH264 *encoder);

#endif
