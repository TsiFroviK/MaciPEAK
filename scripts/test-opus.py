"""Exercise the fixed P/Invoke signatures used by PEAK's voice codec."""
import ctypes as c
import math
import sys

def tone_correlation(pcm):
    # Compare across a period to allow for the codec's algorithmic delay.
    reference = [math.sin(i * math.tau * 400 / 48000) for i in range(len(pcm))]
    norm = math.sqrt(sum(x * x for x in reference) * sum(y * y for y in pcm))
    return max(sum(pcm[i] * reference[(i + lag) % len(pcm)] for i in range(len(pcm)))
               for lag in range(120)) / norm


def test(path):
    lib = c.CDLL(path)
    integer, pointer = c.c_int, c.c_void_p

    def bind(name, result, *arguments):
        return c.CFUNCTYPE(result, *arguments)((name, lib))

    enc_size = bind("opus_encoder_get_size", integer, integer)(1)
    dec_size = bind("opus_decoder_get_size", integer, integer)(1)
    assert 0 < enc_size < 1 << 20 and 0 < dec_size < 1 << 20, (enc_size, dec_size)
    encoder, decoder = c.create_string_buffer(enc_size), c.create_string_buffer(dec_size)
    assert bind("opus_encoder_init", integer, pointer, integer, integer, integer)(encoder, 48000, 1, 2048) == 0
    assert bind("opus_decoder_init", integer, pointer, integer, integer)(decoder, 48000, 1) == 0
    rate, sample_rate = integer(), integer()
    assert bind("opus_encoder_ctl", integer, pointer, integer, integer)(encoder, 4002, 24000) == 0
    assert bind("opus_encoder_ctl", integer, pointer, integer, pointer)(encoder, 4003, c.byref(rate)) == 0
    assert bind("opus_decoder_ctl", integer, pointer, integer, integer)(decoder, 4034, -128) == 0
    assert bind("opus_decoder_ctl", integer, pointer, integer, pointer)(decoder, 4029, c.byref(sample_rate)) == 0
    assert rate.value == 24000 and sample_rate.value == 48000, (rate.value, sample_rate.value)

    encode = bind("opus_encode", integer, pointer, pointer, integer, pointer, integer)
    decode = bind("opus_decode", integer, pointer, pointer, integer, pointer, integer, integer)
    packet, pcm = c.create_string_buffer(1275), (c.c_int16 * 960)()
    # RFC 7587 section 3.1.3 gives the three-byte Opus silence frame.
    assert decode(decoder, b"\xf8\xff\xfe", 3, pcm, 960, 0) == 960
    reference = [12000 * math.sin(i * math.tau * 400 / 48000) for i in range(960)]
    tone = (c.c_int16 * 960)(*(int(x) for x in reference))
    for _ in range(8):
        size = encode(encoder, tone, 960, packet, len(packet))
        assert 0 < size <= len(packet), size
        assert decode(decoder, packet, size, pcm, 960, 0) == 960
    correlation = tone_correlation(pcm)
    assert correlation > 0.9, correlation
    print(f"Opus 400 Hz test tone at {rate.value} bps, round-trip correlation {correlation:.3f}.")


if __name__ == "__main__":
    if not __debug__:
        sys.exit("Run the codec test with Python assertions enabled.")
    test(sys.argv[1])
