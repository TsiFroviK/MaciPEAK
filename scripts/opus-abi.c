/* Adapt Xiph's variadic ctl entry points to the fixed-signature imports in
 * PEAK's POpusCodec.Wrapper. Apple's arm64 ABI passes variadic arguments on
 * the stack while fixed integer/pointer arguments use the argument registers. */
#include <stdint.h>
#define opus_encoder_ctl xiph_encoder_ctl
#define opus_decoder_ctl xiph_decoder_ctl
#include "opus.h"
#undef opus_encoder_ctl
#undef opus_decoder_ctl

int opus_encoder_ctl(OpusEncoder *state, int request, uintptr_t argument) {
    if (request == OPUS_RESET_STATE)
        return xiph_encoder_ctl(state, request);
    if (request == OPUS_GET_FINAL_RANGE_REQUEST)
        return xiph_encoder_ctl(state, request, (opus_uint32 *)argument);
    if (request & 1)
        return xiph_encoder_ctl(state, request, (opus_int32 *)argument);
    return xiph_encoder_ctl(state, request, (opus_int32)argument);
}

int opus_decoder_ctl(OpusDecoder *state, int request, uintptr_t argument) {
    /* POpusCodec encodes GET_GAIN as 4035. Xiph's released API uses 4045. */
    if (request == 4035)
        request = OPUS_GET_GAIN_REQUEST;
    if (request == OPUS_RESET_STATE)
        return xiph_decoder_ctl(state, request);
    if (request == OPUS_GET_FINAL_RANGE_REQUEST)
        return xiph_decoder_ctl(state, request, (opus_uint32 *)argument);
    if (request & 1)
        return xiph_decoder_ctl(state, request, (opus_int32 *)argument);
    return xiph_decoder_ctl(state, request, (opus_int32)argument);
}
