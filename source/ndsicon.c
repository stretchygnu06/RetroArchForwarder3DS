#include <math.h>
#include <string.h>

#include "ndsicon.h"

static uint16_t rd16(const uint8_t* p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t* p) { return p[0] | (p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

// GBATEK swiCRC16, as YANBF checks it.
static uint16_t crc16(const uint8_t* d, size_t n)
{
	uint32_t crc = 0xFFFF;
	size_t i;
	int b;
	for (i = 0; i < n; i++)
	{
		crc ^= d[i];
		for (b = 0; b < 8; b++)
			crc = (crc & 1) ? (crc >> 1) ^ 0xA001 : crc >> 1;
	}
	return (uint16_t)crc;
}

uint32_t ndsBannerOffset(const uint8_t header[NDS_HEADER_SIZE])
{
	return rd32(header + 0x68);
}

int ndsReadInfo(const uint8_t header[NDS_HEADER_SIZE], const uint8_t* banner, size_t banner_len, nds_info* out)
{
	int version, langs, lang, i;

	memset(out, 0, sizeof(*out));
	memcpy(out->gamecode, header + 0x0C, 4);
	for (i = 0; i < 4; i++)
		if (out->gamecode[i] < 0x20 || out->gamecode[i] > 0x7E) out->gamecode[i] = '_';
	if (!banner || banner_len < 0x840) return -1;

	// Version 2 adds Chinese, version 3 Korean, each behind its own checksum.
	version = rd16(banner) & 3;
	langs = version == 3 ? 8 : version == 2 ? 7 : 6;
	if (version >= 2)
	{
		if (banner_len < 0x940 || rd16(banner + 4) != crc16(banner + 0x20, 0x940 - 0x20)) langs = 6;
		else if (version == 3 && (banner_len < 0xA40 || rd16(banner + 6) != crc16(banner + 0x20, 0xA40 - 0x20))) langs = 7;
	}
	for (lang = 0; lang < langs; lang++)
	{
		const uint8_t* t = banner + 0x240 + (size_t)lang * 0x100;
		for (i = 0; i < NDS_TITLE_CHARS; i++)
		{
			uint16_t c = rd16(t + i * 2);
			if (!c) break;
			out->titles[lang][i] = c;
		}
		out->titles[lang][i] = 0;
	}
	out->title_count = langs;
	return 0;
}

static size_t putUtf8(char* out, size_t pos, size_t cap, uint32_t c)
{
	char b[4];
	size_t n, i;
	if (c < 0x80) { b[0] = (char)c; n = 1; }
	else if (c < 0x800) { b[0] = (char)(0xC0 | (c >> 6)); b[1] = (char)(0x80 | (c & 0x3F)); n = 2; }
	else { b[0] = (char)(0xE0 | (c >> 12)); b[1] = (char)(0x80 | ((c >> 6) & 0x3F)); b[2] = (char)(0x80 | (c & 0x3F)); n = 3; }
	if (pos + n >= cap) return pos;
	for (i = 0; i < n; i++) out[pos + i] = b[i];
	return pos + n;
}

int ndsTitleLines(const nds_info* info, int lang)
{
	int i, n = 1;
	if (lang < 0 || lang >= info->title_count) return 0;
	for (i = 0; info->titles[lang][i]; i++)
		if (info->titles[lang][i] == '\n') n++;
	return n;
}

void ndsTitleLine(const nds_info* info, int lang, int n, char* out, size_t out_len)
{
	int i, line = 0, lines = ndsTitleLines(info, lang);
	size_t pos = 0;

	if (out_len) out[0] = 0;
	if (!lines || !out_len) return;
	if (n < 0) n = lines + n;
	for (i = 0; info->titles[lang][i]; i++)
	{
		uint32_t c = info->titles[lang][i];
		if (c == '\n') { line++; continue; }
		if (line != n || c == '\r') continue;
		if (c >= 0xD800 && c <= 0xDFFF) c = '?';
		pos = putUtf8(out, pos, out_len, c);
	}
	out[pos] = 0;
}

// The 32x32 4-bit bitmap of 4x4 tiles of 8x8, and its 16-colour palette.
static void decodeIcon(const uint8_t* bitmap, const uint8_t* palette, int hflip, int vflip, uint8_t rgb[32 * 32 * 3])
{
	uint8_t idx[32 * 32];
	uint8_t pal[16][3];
	int ty, tx, y, x, i;
	const uint8_t* p = bitmap;

	for (ty = 0; ty < 4; ty++)
		for (tx = 0; tx < 4; tx++)
			for (y = 0; y < 8; y++)
				for (x = 0; x < 4; x++)
				{
					uint8_t b = *p++;
					idx[(ty * 8 + y) * 32 + tx * 8 + x * 2] = b & 0xF;
					idx[(ty * 8 + y) * 32 + tx * 8 + x * 2 + 1] = b >> 4;
				}
	for (i = 0; i < 16; i++)
	{
		uint16_t c = rd16(palette + i * 2);
		// round(c * 255 / 31): no value of c lands on a tie.
		pal[i][0] = (uint8_t)(((c & 0x1F) * 510 + 31) / 62);
		pal[i][1] = (uint8_t)((((c >> 5) & 0x1F) * 510 + 31) / 62);
		pal[i][2] = (uint8_t)((((c >> 10) & 0x1F) * 510 + 31) / 62);
	}
	// YANBF turns the transparent colour white.
	pal[0][0] = pal[0][1] = pal[0][2] = 0xFF;

	for (y = 0; y < 32; y++)
		for (x = 0; x < 32; x++)
		{
			int sx = hflip ? 31 - x : x, sy = vflip ? 31 - y : y;
			memcpy(rgb + (y * 32 + x) * 3, pal[idx[sy * 32 + sx]], 3);
		}
}

int ndsIcon32(const uint8_t* banner, size_t banner_len, uint8_t rgb[32 * 32 * 3])
{
	int version;

	if (!banner || banner_len < 0x240) return -1;
	version = rd16(banner);
	if ((version & 0x100) && (banner_len < 0x23C0 || rd16(banner + 8) != crc16(banner + 0x1240, 0x1180)))
		version &= ~0x100;

	if (version == 0x103)
	{
		// The first frame of the animation. YANBF reads its palette number as
		// (value >> 11) >> 7, always 0 for 16 bits: palette 0 it is.
		uint16_t seq = rd16(banner + 0x2340);
		int bmp = (seq >> 8) & 7;
		if ((seq & 0xFF) == 0) { bmp = 0; seq = 0; }
		decodeIcon(banner + 0x1240 + bmp * 0x200, banner + 0x2240, (seq >> 14) & 1, (seq >> 15) & 1, rgb);
	}
	else
		decodeIcon(banner + 0x20, banner + 0x220, 0, 0, rgb);
	return 0;
}

// ---------------------------------------------------------------- Pillow's resample
#define PRECISION_BITS (32 - 8 - 2)
#define KMAX 16

static double triangle(double x)
{
	if (x < 0) x = -x;
	return x < 1.0 ? 1.0 - x : 0.0;
}

// Same as precompute_coeffs + normalize_coeffs_8bpc in Pillow's Resample.c.
static int coeffs(int in, int outSize, int* bounds, int* kk)
{
	double scale = (double)in / outSize;
	double filterscale = scale < 1.0 ? 1.0 : scale;
	double support = 1.0 * filterscale;
	int ksize = (int)ceil(support) * 2 + 1;
	int xx, x;
	double k[KMAX];

	if (ksize > KMAX) return 0;
	for (xx = 0; xx < outSize; xx++)
	{
		double center = (xx + 0.5) * scale, ww = 0.0, ss = 1.0 / filterscale;
		int xmin = (int)(center - support + 0.5), xmax = (int)(center + support + 0.5);
		if (xmin < 0) xmin = 0;
		if (xmax > in) xmax = in;
		xmax -= xmin;
		for (x = 0; x < xmax; x++) { k[x] = triangle((x + xmin - center + 0.5) * ss); ww += k[x]; }
		for (x = 0; x < ksize; x++)
		{
			double v = x < xmax ? (ww != 0.0 ? k[x] / ww : k[x]) : 0.0;
			kk[xx * ksize + x] = v < 0 ? (int)(-0.5 + v * (1 << PRECISION_BITS)) : (int)(0.5 + v * (1 << PRECISION_BITS));
		}
		bounds[xx * 2] = xmin;
		bounds[xx * 2 + 1] = xmax;
	}
	return ksize;
}

static uint8_t clip8(int v)
{
	v >>= PRECISION_BITS;
	return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
}

void ndsResizeBilinear(const uint8_t* src, int sw, int sh, uint8_t* dst, int dw, int dh)
{
	int bx[2 * 256], by[2 * 256], kx[256 * KMAX], ky[256 * KMAX];
	uint8_t tmp[256 * 256 * 3];
	int ksx, ksy, x, y, c, i;

	if (sw > 256 || sh > 256 || dw > 256 || dh > 256) return;
	ksx = coeffs(sw, dw, bx, kx);
	ksy = coeffs(sh, dh, by, ky);
	if (!ksx || !ksy) return;

	// Horizontal first, as Pillow does, rounding to 8 bits in between.
	for (y = 0; y < sh; y++)
		for (x = 0; x < dw; x++)
			for (c = 0; c < 3; c++)
			{
				int ss = 1 << (PRECISION_BITS - 1);
				for (i = 0; i < bx[x * 2 + 1]; i++)
					ss += src[(y * sw + bx[x * 2] + i) * 3 + c] * kx[x * ksx + i];
				tmp[(y * dw + x) * 3 + c] = clip8(ss);
			}
	for (y = 0; y < dh; y++)
		for (x = 0; x < dw; x++)
			for (c = 0; c < 3; c++)
			{
				int ss = 1 << (PRECISION_BITS - 1);
				for (i = 0; i < by[y * 2 + 1]; i++)
					ss += tmp[((by[y * 2] + i) * dw + x) * 3 + c] * ky[y * ksy + i];
				dst[(y * dw + x) * 3 + c] = clip8(ss);
			}
}

int ndsIcon48(const uint8_t* banner, size_t banner_len, uint8_t rgb[48 * 48 * 3])
{
	uint8_t small[32 * 32 * 3];
	if (ndsIcon32(banner, banner_len, small) != 0) return -1;
	ndsResizeBilinear(small, 32, 32, rgb, 48, 48);
	return 0;
}
