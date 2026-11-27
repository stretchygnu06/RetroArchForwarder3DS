#pragma once
#include <stddef.h>
#include <stdint.h>

// What a DS forwarder takes from the ROM itself: the game code, the titles
// and the icon. The icon is made exactly as YANBF makes it, so a forwarder
// rebuilt here keeps the icon its owner already knows.
//
// Only two pieces of the ROM are needed, so a 256 MB game is never loaded:
// the header (NDS_HEADER_SIZE bytes at 0) and the banner (up to
// NDS_BANNER_MAX bytes at the offset ndsBannerOffset gives).

#define NDS_HEADER_SIZE 0x200
#define NDS_BANNER_MAX 0x23C0
#define NDS_LANGS 8          // jpn eng fra ger ita spa chn kor
#define NDS_TITLE_CHARS 0x80

typedef struct
{
	char gamecode[5];
	uint16_t titles[NDS_LANGS][NDS_TITLE_CHARS + 1];   // UTF-16, zero ended
	int title_count;                                 // languages present
} nds_info;

// Offset of the banner in the ROM, 0 when there is none.
uint32_t ndsBannerOffset(const uint8_t header[NDS_HEADER_SIZE]);

// 0 on success, -1 when the banner is missing or too short.
int ndsReadInfo(const uint8_t header[NDS_HEADER_SIZE], const uint8_t* banner, size_t banner_len, nds_info* out);

// Line n of a title (0 first, -1 last), as UTF-8.
void ndsTitleLine(const nds_info* info, int lang, int n, char* out, size_t out_len);

// Number of lines of a title.
int ndsTitleLines(const nds_info* info, int lang);

// The 48x48 RGB icon: the DS icon, or the first frame of the DSi animated one
// when its checksum holds, on white, scaled up with Pillow's bilinear filter.
// 0 on success.
int ndsIcon48(const uint8_t* banner, size_t banner_len, uint8_t rgb[48 * 48 * 3]);

// The 32x32 RGB icon before scaling (for the tests).
int ndsIcon32(const uint8_t* banner, size_t banner_len, uint8_t rgb[32 * 32 * 3]);

// Pillow's Image.resize(..., BILINEAR) on 8-bit RGB, same rounding.
void ndsResizeBilinear(const uint8_t* src, int sw, int sh, uint8_t* dst, int dw, int dh);
