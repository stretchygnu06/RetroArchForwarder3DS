// Recomputes every hash of a CIA in place, with the same cia_reseal the apps
// use. Used after tools/grow_banner.py.
#include <stdio.h>
#include <stdlib.h>
#include "../source/cia_patch.h"

int main(int argc, char** argv)
{
	FILE* f;
	long n;
	unsigned char* d;
	cia_t cia;

	if (argc < 2) { fprintf(stderr, "usage: reseal <file.cia>\n"); return 1; }
	f = fopen(argv[1], "rb");
	if (!f) return 2;
	fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
	d = malloc(n);
	if (fread(d, 1, n, f) != (size_t)n) return 2;
	fclose(f);
	if (cia_open(&cia, d, n) != CIA_OK) { fprintf(stderr, "not a CIA\n"); return 3; }
	cia_reseal(&cia);
	f = fopen(argv[1], "wb");
	fwrite(d, 1, n, f);
	fclose(f);
	printf("resealed %s\n", argv[1]);
	return 0;
}
