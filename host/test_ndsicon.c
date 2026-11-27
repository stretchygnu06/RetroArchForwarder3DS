// Host harness: prints the game code and the English title lines of a DS ROM
// and writes its 48x48 icon as raw RGB, to compare with YANBF's Pillow code.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../source/ndsicon.h"

int main(int argc, char** argv)
{
	uint8_t hdr[NDS_HEADER_SIZE], banner[NDS_BANNER_MAX], rgb[48 * 48 * 3];
	size_t blen;
	nds_info info;
	char line[512];
	FILE* f;
	int i;

	if (argc < 3) { fprintf(stderr, "usage: test_ndsicon rom.nds icon.rgb\n"); return 1; }
	f = fopen(argv[1], "rb");
	if (!f || fread(hdr, 1, sizeof(hdr), f) != sizeof(hdr)) return 2;
	fseek(f, (long)ndsBannerOffset(hdr), SEEK_SET);
	blen = fread(banner, 1, sizeof(banner), f);
	fclose(f);
	if (ndsReadInfo(hdr, banner, blen, &info) != 0) { printf("ERROR=no banner\n"); return 3; }
	printf("GAMECODE=%s\nLANGS=%d\n", info.gamecode, info.title_count);
	for (i = 0; i < ndsTitleLines(&info, 1); i++) { ndsTitleLine(&info, 1, i, line, sizeof(line)); printf("ENG%d=%s\n", i, line); }
	if (ndsIcon48(banner, blen, rgb) != 0) return 4;
	f = fopen(argv[2], "wb");
	fwrite(rgb, 1, sizeof(rgb), f);
	fclose(f);
	return 0;
}
