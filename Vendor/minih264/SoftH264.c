#define MINIH264_IMPLEMENTATION
#include "minih264e.h"
#include "SoftH264.h"

#include <stdlib.h>

struct SoftH264 {
    H264E_persist_t *persist;
    H264E_scratch_t *scratch;
    int frameBytes;
};

SoftH264 *softh264_create(int width, int height, int bitRate, int frameRate) {
    if (width <= 0 || height <= 0 || (width & 15) || (height & 15) || frameRate <= 0) return NULL;

    H264E_create_param_t create;
    memset(&create, 0, sizeof create);
    create.width = width;
    create.height = height;
    create.gop = 0; // key frames are the caller's choice
    // One second of buffer. At 1280x528 this keeps the SPS at level 3.1, the most the
    // official app sends the 368G.
    create.vbv_size_bytes = bitRate / 8;
    create.const_input_flag = 1;
    create.num_layers = 1;
    create.max_threads = 0;

    int persistSize = 0, scratchSize = 0;
    if (H264E_sizeof(&create, &persistSize, &scratchSize) != H264E_STATUS_SUCCESS) return NULL;

    SoftH264 *encoder = calloc(1, sizeof *encoder);
    if (!encoder) return NULL;
    encoder->persist = malloc((size_t)persistSize);
    encoder->scratch = malloc((size_t)scratchSize);
    encoder->frameBytes = bitRate / 8 / frameRate;
    if (!encoder->persist || !encoder->scratch ||
        H264E_init(encoder->persist, &create) != H264E_STATUS_SUCCESS) {
        softh264_destroy(encoder);
        return NULL;
    }
    return encoder;
}

int softh264_encode(SoftH264 *encoder,
                    const uint8_t *y, int strideY,
                    const uint8_t *u, const uint8_t *v, int strideUV,
                    int forceKey,
                    const uint8_t **out, int *outSize) {
    if (!encoder || !out || !outSize) return H264E_STATUS_BAD_ARGUMENT;

    H264E_run_param_t run;
    memset(&run, 0, sizeof run);
    run.frame_type = forceKey ? H264E_FRAME_TYPE_KEY : H264E_FRAME_TYPE_P;
    run.encode_speed = 8; // 0 = best quality, 10 = fastest; 8 keeps 20 fps at 1280x528
    run.desired_frame_bytes = encoder->frameBytes;
    run.qp_min = 18;
    run.qp_max = 45;

    H264E_io_yuv_t frame;
    frame.yuv[0] = (unsigned char *)y;
    frame.yuv[1] = (unsigned char *)u;
    frame.yuv[2] = (unsigned char *)v;
    frame.stride[0] = strideY;
    frame.stride[1] = strideUV;
    frame.stride[2] = strideUV;

    unsigned char *coded = NULL;
    int size = 0;
    int status = H264E_encode(encoder->persist, encoder->scratch, &run, &frame, &coded, &size);
    *out = coded;
    *outSize = status == H264E_STATUS_SUCCESS ? size : 0;
    return status;
}

void softh264_destroy(SoftH264 *encoder) {
    if (!encoder) return;
    free(encoder->persist);
    free(encoder->scratch);
    free(encoder);
}
