#!/bin/sh
# Builds the forwarder stub and puts it into template/template.cia.
# Needs devkitARM and libctru (DEVKITPRO set, as in the devkitpro/devkitarm
# Docker image) and a host gcc for the reseal tool.
set -eu
cd "$(dirname "$0")/.."
: "${DEVKITPRO:?set DEVKITPRO}"
CC="$DEVKITPRO/devkitARM/bin/arm-none-eabi-gcc"
ARCH="-march=armv6k -mtune=mpcore -mfloat-abi=hard -mtp=soft"
mkdir -p build-stub
# -Os and no printf keep the code inside the room the template reserves
# before the banner.
$CC -Os -Wall -mword-relocations -ffunction-sections -fdata-sections $ARCH -D__3DS__ \
	-I"$DEVKITPRO/libctru/include" -c stub/source/main.c -o build-stub/main.o
$CC -specs=3dsx.specs $ARCH -Wl,--gc-sections build-stub/main.o \
	-L"$DEVKITPRO/libctru/lib" -lctru -lm -o build-stub/stub.elf
gcc -O2 -o build-stub/reseal host/reseal.c source/cia_patch.c source/sha256.c
python3 tools/inject_stub.py build-stub/stub.elf template/template.cia
./build-stub/reseal template/template.cia
