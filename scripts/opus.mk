# Invoke within a freshly extracted Xiph Opus 1.5.2 source release.
include opus_sources.mk celt_sources.mk silk_sources.mk
sources = $(OPUS_SOURCES) $(OPUS_SOURCES_FLOAT) $(CELT_SOURCES) $(SILK_SOURCES) $(SILK_SOURCES_FLOAT)
objects = $(sources:.c=.o)

ARCHFLAGS ?= -arch arm64 -arch x86_64 -mmacosx-version-min=11.0
DYLIBFLAGS ?= -dynamiclib -Wl,-install_name,@rpath/libopus_egpv.dylib
includes = -I. -Iinclude -Icelt -Isilk -Isilk/float -Isilk/fixed -Idnn
defines = -DOPUS_BUILD -DVAR_ARRAYS -DHAVE_LRINT -DHAVE_LRINTF -DPACKAGE_VERSION='"1.5.2"'
rename_ctl = -Dopus_encoder_ctl=xiph_encoder_ctl -Dopus_decoder_ctl=xiph_decoder_ctl

libopus_egpv.dylib: $(objects) opus-abi.o
	$(CC) $(ARCHFLAGS) $(DYLIBFLAGS) -o $@ $^ -lm

$(objects): %.o: %.c
	$(CC) $(ARCHFLAGS) -std=c99 -O2 -fPIC $(includes) $(defines) $(rename_ctl) -c $< -o $@

opus-abi.o: opus-abi.c
	$(CC) $(ARCHFLAGS) -std=c99 -O2 -fPIC -Iinclude -c $< -o $@
