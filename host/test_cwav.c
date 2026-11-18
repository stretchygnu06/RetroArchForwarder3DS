// CWAV building and banner sound swap, on synthetic WAV files.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../source/cwav.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static unsigned rd32(const unsigned char* p) { return p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24; }
static void wr32(unsigned char* p, unsigned v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void wr16(unsigned char* p, unsigned v) { p[0] = v; p[1] = v >> 8; }

// A WAV of `frames` frames; sample value = frame index (+ channel * 1000).
static unsigned char* makeWav(unsigned ch, unsigned rate, unsigned bits, unsigned frames, size_t* len)
{
	size_t data = (size_t)frames * ch * (bits / 8);
	unsigned char* w = calloc(44 + data, 1);
	unsigned f, c;
	memcpy(w, "RIFF", 4); wr32(w + 4, 36 + data); memcpy(w + 8, "WAVEfmt ", 8);
	wr32(w + 16, 16); wr16(w + 20, 1); wr16(w + 22, ch); wr32(w + 24, rate);
	wr32(w + 28, rate * ch * bits / 8); wr16(w + 32, ch * bits / 8); wr16(w + 34, bits);
	memcpy(w + 36, "data", 4); wr32(w + 40, data);
	for (f = 0; f < frames; f++)
		for (c = 0; c < ch; c++)
		{
			unsigned char* s = w + 44 + ((size_t)f * ch + c) * (bits / 8);
			if (bits == 16) wr16(s, (f + c * 1000) & 0xFFFF); else s[0] = (unsigned char)(128 + (c ? -1 : 1));
		}
	*len = 44 + data;
	return w;
}

int main(void)
{
	size_t len, n;
	unsigned char *wav, *cw;
	const char* err;

	// Stereo PCM16: header, INFO and planar DATA.
	wav = makeWav(2, 32000, 16, 1000, &len);
	n = cwavFromWav(wav, len, &cw, &err);
	CHECK(n > 0);
	CHECK(memcmp(cw, "CWAV", 4) == 0 && rd32(cw + 0x0C) == n);
	{
		unsigned info = rd32(cw + 0x18), data = rd32(cw + 0x24);
		unsigned c1 = rd32(cw + info + 0x20 + 2 * 8 + 0x14 + 4);
		CHECK(memcmp(cw + info, "INFO", 4) == 0 && cw[info + 8] == 1);
		CHECK(rd32(cw + info + 0x0C) == 32000 && rd32(cw + info + 0x14) == 1000 && rd32(cw + info + 0x1C) == 2);
		CHECK(memcmp(cw + data, "DATA", 4) == 0);
		// channel 0 sample 5 = 5, channel 1 sample 5 = 1005
		CHECK(cw[data + 0x20 + 10] == 5);
		CHECK((cw[data + 8 + c1 + 10] | cw[data + 8 + c1 + 11] << 8) == 1005);
	}
	free(cw); free(wav);

	// Longer than three seconds: trimmed.
	wav = makeWav(1, 22050, 16, 22050 * 5, &len);
	n = cwavFromWav(wav, len, &cw, &err);
	CHECK(n > 0 && rd32(cw + rd32(cw + 0x18) + 0x14) == 22050 * 3);
	free(cw); free(wav);

	// 8-bit is unsigned in a WAV: widened to signed 16-bit.
	wav = makeWav(2, 16000, 8, 10, &len);
	n = cwavFromWav(wav, len, &cw, &err);
	CHECK(n > 0);
	{
		unsigned data = rd32(cw + 0x24);
		short s0 = (short)(cw[data + 0x20] | cw[data + 0x21] << 8);
		CHECK(s0 == 256);
	}
	free(cw); free(wav);

	// Rejections.
	wav = makeWav(2, 32000, 16, 10, &len);
	wr16(wav + 20, 3);  // float
	CHECK(cwavFromWav(wav, len, &cw, &err) == 0 && err);
	wr16(wav + 20, 1); wr16(wav + 22, 6);
	CHECK(cwavFromWav(wav, len, &cw, &err) == 0);
	CHECK(cwavFromWav((const unsigned char*)"nope", 4, &cw, &err) == 0);
	free(wav);

	// Banner swap: keeps everything up to the old sound, appends the new one.
	{
		unsigned char bnr[0x400], out[0x800], small[0x80];
		memset(bnr, 0xAB, sizeof(bnr));
		memcpy(bnr, "CBMD", 4);
		wr32(bnr + 0x84, 0x300);
		CHECK(bannerSetSound(bnr, sizeof(bnr), (const unsigned char*)"SOUND", 5, out, sizeof(out)) == 0x305);
		CHECK(memcmp(out + 0x88, bnr + 0x88, 0x300 - 0x88) == 0 && memcmp(out + 0x300, "SOUND", 5) == 0);
		CHECK(rd32(out + 0x84) == 0x300);
		CHECK(bannerSetSound(bnr, sizeof(bnr), (const unsigned char*)"SOUND", 5, small, sizeof(small)) == 0);
		memcpy(bnr, "XXXX", 4);
		CHECK(bannerSetSound(bnr, sizeof(bnr), (const unsigned char*)"S", 1, out, sizeof(out)) == 0);
	}

	printf(fails ? "%d failure(s)\n" : "cwav: all tests passed\n", fails);
	return fails != 0;
}
