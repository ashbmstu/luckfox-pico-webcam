# uvc_streamer — cross-compiled UVC gadget daemon for Luckfox Pico (RV1103).
#
# Requires the Luckfox Pico SDK (https://github.com/LuckfoxTECH/luckfox-pico).
# Point at your checkout: make SDK=/path/to/luckfox-pico
# Or export SDK=... in the environment. Run `make help` for targets.

SDK ?= /home/luckfox/luckfox-pico-main

CC := $(SDK)/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin/arm-rockchip830-linux-uclibcgnueabihf-gcc
MPP_SDK := $(SDK)/media/mpp/release_mpp_rv1106_arm-rockchip830-linux-uclibcgnueabihf
ROCKIT_SDK := $(SDK)/media/rockit/rockit/mpi/sdk/include
ROCKIT_LIB := $(SDK)/media/rockit/rockit/lib/lib32
RGA_LIB := $(SDK)/media/rga/release_rga_rv1106_arm-rockchip830-linux-uclibcgnueabihf/lib

CFLAGS := -Wall -O2 -I. -I$(MPP_SDK)/include -I$(ROCKIT_SDK) -DUAPI2 -DRV1106_RV1103 -DRKAIQ
LDFLAGS := -L$(MPP_SDK)/lib -L$(ROCKIT_LIB) -L$(RGA_LIB) \
	-lrockit -lrockchip_mpp -lrga -lpthread -lm -lstdc++ \
	-Wl,-rpath,/oem/usr/lib

TARGET := uvc_streamer
SRCS := uvc_streamer.c rkmpi_venc.c
OBJS := $(SRCS:.c=.o)

# Preflight: cross-compiler required except for clean and help.
ifeq ($(MAKECMDGOALS),)
_CHECK_CC := 1
else
ifneq ($(filter-out clean help,$(MAKECMDGOALS)),)
_CHECK_CC := 1
endif
endif
ifdef _CHECK_CC
ifeq ($(wildcard $(CC)),)
$(error Cross-compiler not found: $(CC). Set SDK to your Luckfox Pico SDK root (e.g. make SDK=/path/to/luckfox-pico))
endif
endif

.PHONY: all clean help

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

%.o: %.c rkmpi_venc.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(TARGET)

help:
	@echo "uvc_streamer Makefile targets:"
	@echo "  all (default)  Build $(TARGET) for the board (cross-compile)"
	@echo "  clean          Remove build artefacts"
	@echo "  help           Show this message"
	@echo ""
	@echo "Variable:"
	@echo "  SDK            Luckfox Pico SDK root (default: $(SDK))"
	@echo "                 Override: make SDK=/path/to/luckfox-pico"
