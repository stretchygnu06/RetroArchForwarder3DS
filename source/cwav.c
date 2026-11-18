// CWAV layout ported from bannertool's cwav.cpp (Steveice10, MIT).

#include <stdlib.h>
#include <string.h>

#include "cwav.h"

static uint16_t rd16(const uint8_t* p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t* p) { return p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static void wr16(uint8_t* p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void wr32(uint8_t* p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }

#define ALIGN32(v) (((v) + 0x1F) & ~(size_t)0x1F)

typedef struct
{
	unsigned channels, rate, bits;
	const uint8_t* data;
	size_t size;
} wav_t;

static const char* parseWav(const uint8_t* p, size_t len, wav_t* w)
{
	size_t pos = 12;
	int haveFmt = 0;

	memset(w, 0, sizeof(*w));
	if (len < 12 || memcmp(p, "RIFF", 4) != 0 || memcmp(p + 8, "WAVE", 4) != 0)
		return "not a WAV file";

	while (pos + 8 <= len)
	{
		const uint8_t* id = p + pos;
		size_t size = rd32(p + pos + 4);
		const uint8_t* body = p + pos + 8;
		if (size > len - pos - 8) size = len - pos - 8;

		if (memcmp(id, "fmt ", 4) == 0 && size >= 16)
		{
			unsigned format = rd16(body);
			// WAVE_FORMAT_EXTENSIBLE: the real format is the subformat GUID's first word.
			if (format == 0xFFFE && size >= 26) format = rd16(body + 24);
			if (format != 1) return "only uncompressed PCM WAV files are supported";
			w->channels = rd16(body + 2);
			w->rate = rd32(body + 4);
			w->bits = rd16(body + 14);
			haveFmt = 1;
		}
		else if (memcmp(id, "data", 4) == 0)
		{
			w->data = body;
			w->size = size;
		}
		pos += 8 + size + (size & 1);
	}

	if (!haveFmt || !w->data) return "WAV file without format or data";
	if (w->channels < 1 || w->channels > 2) return "the WAV must be mono or stereo";
	if (w->bits != 8 && w->bits != 16) return "the WAV must be 8 or 16 bit";
	if (w->rate < 8000 || w->rate > 48000) return "the WAV sample rate must be 8000-48000 Hz";
	return NULL;
}

size_t cwavFromWav(const uint8_t* wav, size_t len, uint8_t** out, const char** err)
{
	wav_t w;
	size_t frames, maxFrames, perChannel, headerSize, infoSize, dataSize, total, f;
	unsigned c, bytesIn;
	uint8_t *o, *info, *data;

	*out = NULL;
	if ((*err = parseWav(wav, len, &w)) != NULL) return 0;

	bytesIn = w.bits / 8;
	frames = w.size / (w.channels * bytesIn);
	maxFrames = (size_t)(w.rate * CWAV_MAX_SECONDS);
	if (frames > maxFrames) frames = maxFrames;
	if (!frames) { *err = "the WAV has no samples"; return 0; }

	perChannel = frames * 2;                            // PCM16
	headerSize = ALIGN32(0x2C);                         // CWAV header
	infoSize = ALIGN32(0x20 + w.channels * (8 + 0x14)); // INFO, refs, channel infos
	dataSize = ALIGN32(8) + perChannel * w.channels;    // DATA
	total = headerSize + infoSize + dataSize;

	o = calloc(total, 1);
	if (!o) { *err = "out of memory"; return 0; }

	memcpy(o, "CWAV", 4);
	wr16(o + 0x04, 0xFEFF);
	wr16(o + 0x06, (uint16_t)headerSize);
	wr32(o + 0x08, 0x02010000);
	wr32(o + 0x0C, (uint32_t)total);
	wr16(o + 0x10, 2);
	wr16(o + 0x14, 0x7000); wr32(o + 0x18, (uint32_t)headerSize); wr32(o + 0x1C, (uint32_t)infoSize);
	wr16(o + 0x20, 0x7001); wr32(o + 0x24, (uint32_t)(headerSize + infoSize)); wr32(o + 0x28, (uint32_t)dataSize);

	info = o + headerSize;
	memcpy(info, "INFO", 4);
	wr32(info + 0x04, (uint32_t)infoSize);
	info[0x08] = 1;                                     // PCM16
	info[0x09] = 0;                                     // no loop
	wr32(info + 0x0C, w.rate);
	wr32(info + 0x10, 0);                               // loop start
	wr32(info + 0x14, (uint32_t)frames);                // loop end = length
	wr32(info + 0x1C, w.channels);                      // channel info table
	for (c = 0; c < w.channels; c++)
	{
		uint8_t* ref = info + 0x20 + c * 8;
		uint8_t* ci = info + 0x20 + w.channels * 8 + c * 0x14;
		wr16(ref, 0x7100);
		wr32(ref + 4, (uint32_t)(4 + w.channels * 8 + c * 0x14));   // from the table start
		wr16(ci, 0x1F00);
		wr32(ci + 4, (uint32_t)(ALIGN32(8) - 8 + c * perChannel));  // from DATA's payload
		wr16(ci + 8, 0);
		wr32(ci + 12, 0xFFFFFFFF);                                  // no ADPCM info
	}

	data = o + headerSize + infoSize;
	memcpy(data, "DATA", 4);
	wr32(data + 4, (uint32_t)dataSize);

	// Interleaved in, one block per channel out. 8-bit WAV samples are
	// unsigned; they are widened to signed 16-bit.
	for (f = 0; f < frames; f++)
		for (c = 0; c < w.channels; c++)
		{
			const uint8_t* s = w.data + (f * w.channels + c) * bytesIn;
			int16_t v = (bytesIn == 2) ? (int16_t)rd16(s) : (int16_t)((s[0] - 128) << 8);
			wr16(data + ALIGN32(8) + c * perChannel + f * 2, (uint16_t)v);
		}

	*out = o;
	return total;
}

#define CBMD_CWAV_OFFSET 0x84

size_t bannerSetSound(const uint8_t* bnr, size_t bnr_len,
                      const uint8_t* cwav, size_t cwav_len,
                      uint8_t* out, size_t out_cap)
{
	uint32_t old;
	size_t keep, at;

	if (bnr_len < 0x88 || memcmp(bnr, "CBMD", 4) != 0) return 0;
	old = rd32(bnr + CBMD_CWAV_OFFSET);
	// No sound yet: append after the last CGFX, which ends where the file does.
	keep = (old && old <= bnr_len) ? old : bnr_len;
	at = ALIGN32(keep);
	if (at + cwav_len > out_cap) return 0;

	memmove(out, bnr, keep);
	memset(out + keep, 0, at - keep);
	memcpy(out + at, cwav, cwav_len);
	wr32(out + CBMD_CWAV_OFFSET, (uint32_t)at);
	return at + cwav_len;
}
