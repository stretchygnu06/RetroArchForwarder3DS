// fwdgen-pc: writes the forwarder CIA from the template, with the artwork
// prepared on the PC. RetroArchForwarderPC.ps1 drives it.
//
//   fwdgen-pc tid   --sd E:\ --rom "sdmc:/roms/psx/Game.chd"
//   fwdgen-pc build --sd E:\ --template template.cia --rom ... --core ...
//                   --name "Game" [--publisher ...] --tid 000400000FF1C100
//                   --icon icon.png --banner banner.png [--transparent]
//                   [--sound jingle.wav]
//                   --out Game.cia
//   fwdgen-pc ndsinfo --rom Game.nds [--icon-bmp icon.bmp]
//   fwdgen-pc ds    --template template.cia --rom Game.nds --name "Game"
//                   [--publisher ...] [--banner banner.png [--transparent]]
//                   [--sound boot.wav] --banner-out banner.bin --smdh-out icon.smdh
//
// ds writes the two pieces a DS forwarder takes from here, for makerom: the
// banner (the template's, with the image and the sound) and the SMDH (the
// template's, with the titles and the DS icon of the ROM, made as YANBF makes
// it).
//
// The SD card is read for two things: the titles installed on it (the
// folder names under "Nintendo 3DS\...\title\00040000") and the registry
// sdmc:/forwarders/registry.txt. A game keeps its id, and an id held by
// another title is never reused. The PC cannot read a title's product code
// (the SD copy is encrypted), so an installed title the registry does not
// attribute to this ROM always counts as someone else's.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#endif

#include "../source/cia_patch.h"
#include "../source/bannergen.h"
#include "../source/icongen.h"
#include "../source/idalloc.h"
#include "../source/cwav.h"
#include "../source/ndsicon.h"

#define MAX_INSTALLED 4096

static uint64_t s_installed[MAX_INSTALLED];
static int s_installedCount;
static char* s_registry;

// ---------------------------------------------------------------- files

static FILE* ufopen(const char* path, const char* mode)
{
#ifdef _WIN32
	wchar_t wpath[1024], wmode[8];
	if (!MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, 1024)) return NULL;
	if (!MultiByteToWideChar(CP_UTF8, 0, mode, -1, wmode, 8)) return NULL;
	return _wfopen(wpath, wmode);
#else
	return fopen(path, mode);
#endif
}

static uint8_t* readAll(const char* path, size_t* len)
{
	FILE* f = ufopen(path, "rb");
	long n;
	uint8_t* buf;

	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	fseek(f, 0, SEEK_SET);
	buf = malloc((size_t)n + 1);
	if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n)
	{
		fclose(f);
		free(buf);
		return NULL;
	}
	fclose(f);
	buf[n] = 0;
	*len = (size_t)n;
	return buf;
}

#ifdef _WIN32
#define SEP "\\"
#else
#define SEP "/"
#endif

static void joinPath(char* out, size_t len, const char* a, const char* b)
{
	size_t n = strlen(a);
	char* c;
	snprintf(out, len, "%s%s%s", a, (n && (a[n - 1] == '\\' || a[n - 1] == '/')) ? "" : SEP, b);
#ifndef _WIN32
	for (c = out; *c; c++) if (*c == '\\') *c = '/';
#else
	(void)c;
#endif
}

// ---------------------------------------------------------------- SD card

static int hex8(const char* s, uint32_t* v)
{
	int i;
	*v = 0;
	for (i = 0; i < 8; i++)
	{
		char c = s[i];
		int d = (c >= '0' && c <= '9') ? c - '0'
			: (c >= 'a' && c <= 'f') ? c - 'a' + 10
			: (c >= 'A' && c <= 'F') ? c - 'A' + 10 : -1;
		if (d < 0) return 0;
		*v = (*v << 4) | (uint32_t)d;
	}
	return s[8] == 0;
}

static void addInstalled(const char* name)
{
	uint32_t low;
	if (s_installedCount < MAX_INSTALLED && hex8(name, &low))
		s_installed[s_installedCount++] = 0x0004000000000000ULL | low;
}

#ifdef _WIN32
// Calls fn for every subfolder of dir (UTF-8 in, UTF-8 names out).
static void eachDir(const char* dir, void (*fn)(const char* parent, const char* name, void* ctx), void* ctx)
{
	wchar_t wpat[1024];
	char pattern[1024], name[512];
	WIN32_FIND_DATAW fd;
	HANDLE h;

	joinPath(pattern, sizeof(pattern), dir, "*");
	if (!MultiByteToWideChar(CP_UTF8, 0, pattern, -1, wpat, 1024)) return;
	h = FindFirstFileW(wpat, &fd);
	if (h == INVALID_HANDLE_VALUE) return;
	do
	{
		if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
		if (fd.cFileName[0] == L'.') continue;
		if (!WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, name, sizeof(name), NULL, NULL)) continue;
		fn(dir, name, ctx);
	} while (FindNextFileW(h, &fd));
	FindClose(h);
}
#else
static void eachDir(const char* dir, void (*fn)(const char* parent, const char* name, void* ctx), void* ctx)
{
	DIR* d = opendir(dir);
	struct dirent* e;
	if (!d) return;
	while ((e = readdir(d)))
		if (e->d_name[0] != '.' && e->d_type == DT_DIR) fn(dir, e->d_name, ctx);
	closedir(d);
}
#endif

static void onTitle(const char* parent, const char* name, void* ctx)
{
	(void)parent; (void)ctx;
	addInstalled(name);
}

static void onId1(const char* parent, const char* name, void* ctx)
{
	char p[1024], q[1024];
	(void)ctx;
	joinPath(p, sizeof(p), parent, name);
	joinPath(q, sizeof(q), p, "title\\00040000");
	eachDir(q, onTitle, NULL);
}

static void onId0(const char* parent, const char* name, void* ctx)
{
	char p[1024];
	(void)ctx;
	if (strlen(name) != 32) return;
	joinPath(p, sizeof(p), parent, name);
	eachDir(p, onId1, NULL);
}

static int loadSd(const char* sd)
{
	char root[1024], reg[1024];
	size_t len;

	joinPath(root, sizeof(root), sd, "Nintendo 3DS");
	s_installedCount = 0;
	eachDir(root, onId0, NULL);

	joinPath(reg, sizeof(reg), sd, "forwarders\\registry.txt");
	s_registry = (char*)readAll(reg, &len);
	if (!s_registry) { s_registry = malloc(1); s_registry[0] = 0; }
	return s_installedCount > 0;
}

static bool isInstalled(uint64_t tid)
{
	int i;
	for (i = 0; i < s_installedCount; i++)
		if (s_installed[i] == tid) return true;
	return false;
}

static bool idTaken(uint64_t tid, void* ctx)
{
	(void)ctx;
	return isInstalled(tid) || idRegistryHasTitle(s_registry, tid);
}

// ---------------------------------------------------------------- versions

// The HOME menu only refreshes a cached icon when the title version changes.
// The installed version cannot be read from the PC (the SD copy is
// encrypted), so a count is kept in sdmc:/forwarders/versions.txt, starting
// at 2048.
static unsigned nextVersion(const char* sd, uint64_t tid)
{
	char path[1024], want[20];
	size_t len;
	char* text;
	unsigned best = 0;

	joinPath(path, sizeof(path), sd, "forwarders\\versions.txt");
	text = (char*)readAll(path, &len);
	snprintf(want, sizeof(want), "%08lX%08lX|", (unsigned long)(tid >> 32), (unsigned long)(tid & 0xFFFFFFFF));
	if (text)
	{
		char* p = text;
		while ((p = strstr(p, want)))
		{
			unsigned v = (unsigned)strtoul(p + 17, NULL, 10);
			if (v > best) best = v;
			p += 17;
		}
		free(text);
	}
	if (!best) return 2048;
	return best + 1 > 0xFFFF ? 2048 : best + 1;
}

static int appendLine(const char* sd, const char* file, const char* line)
{
	char dir[1024], path[1024];
	FILE* f;

	joinPath(dir, sizeof(dir), sd, "forwarders");
#ifdef _WIN32
	{
		wchar_t w[1024];
		if (MultiByteToWideChar(CP_UTF8, 0, dir, -1, w, 1024)) CreateDirectoryW(w, NULL);
	}
#else
	mkdir(dir, 0777);
#endif
	joinPath(path, sizeof(path), dir, file);
	f = ufopen(path, "ab");
	if (!f) return 0;
	fputs(line, f);
	fclose(f);
	return 1;
}

// ---------------------------------------------------------------- commands

static const char* arg(int argc, char** argv, const char* name)
{
	int i;
	for (i = 2; i + 1 < argc; i++)
		if (strcmp(argv[i], name) == 0) return argv[i + 1];
	return NULL;
}

static int flag(int argc, char** argv, const char* name)
{
	int i;
	for (i = 2; i < argc; i++)
		if (strcmp(argv[i], name) == 0) return 1;
	return 0;
}

static int cmdTid(int argc, char** argv)
{
	const char* sd = arg(argc, argv, "--sd");
	const char* rom = arg(argc, argv, "--rom");
	uint64_t preferred, tid;
	const char* status;

	if (!sd || !rom) { fprintf(stderr, "tid: --sd and --rom are required\n"); return 2; }
	if (!loadSd(sd)) { printf("ERROR=no titles found under %s\\Nintendo 3DS\n", sd); return 3; }

	preferred = idPreferredTitle(rom);
	if (idRegistryFind(s_registry, rom, &tid))
		status = isInstalled(tid) ? "update" : "new";
	else
	{
		tid = idPickFree(preferred, idTaken, NULL);
		if (!tid) { printf("ERROR=no free title id left\n"); return 4; }
		status = (tid == preferred) ? "new" : "moved";
	}
	printf("TID=%08lX%08lX\n", (unsigned long)(tid >> 32), (unsigned long)(tid & 0xFFFFFFFF));
	printf("PREFERRED=%08lX%08lX\n", (unsigned long)(preferred >> 32), (unsigned long)(preferred & 0xFFFFFFFF));
	printf("STATUS=%s\n", status);
	printf("INSTALLED=%d\n", s_installedCount);
	return 0;
}

static int parseTid(const char* s, uint64_t* tid)
{
	uint32_t hi, lo;
	char a[9], b[9];
	if (!s || strlen(s) != 16) return 0;
	memcpy(a, s, 8); a[8] = 0;
	memcpy(b, s + 8, 8); b[8] = 0;
	if (!hex8(a, &hi) || !hex8(b, &lo)) return 0;
	*tid = ((uint64_t)hi << 32) | lo;
	return idInRange(*tid);
}

static int cmdBuild(int argc, char** argv)
{
	const char* sd = arg(argc, argv, "--sd");
	const char* tpl = arg(argc, argv, "--template");
	const char* rom = arg(argc, argv, "--rom");
	const char* core = arg(argc, argv, "--core");
	const char* name = arg(argc, argv, "--name");
	const char* pub = arg(argc, argv, "--publisher");
	const char* tidArg = arg(argc, argv, "--tid");
	const char* icon = arg(argc, argv, "--icon");
	const char* banner = arg(argc, argv, "--banner");
	const char* out = arg(argc, argv, "--out");
	const char* sound = arg(argc, argv, "--sound");
	uint8_t* data;
	size_t len;
	cia_t cia;
	uint64_t tid, known;
	unsigned version;
	int err;
	FILE* f;

	if (!sd || !tpl || !rom || !core || !name || !tidArg || !out)
	{
		fprintf(stderr, "build: --sd --template --rom --core --name --tid --out are required\n");
		return 2;
	}
	if (!parseTid(tidArg, &tid)) { printf("ERROR=bad title id %s\n", tidArg); return 2; }
	if (strncmp(rom, "sdmc:/", 6) != 0 || strncmp(core, "sdmc:/", 6) != 0)
	{
		printf("ERROR=rom and core must be sdmc:/ paths\n");
		return 2;
	}

	// Checked again here, not only in the GUI: the id must still be ours.
	// No titles at all means the wrong drive: better to stop than to guess.
	if (!loadSd(sd)) { printf("ERROR=no titles found under %s\\Nintendo 3DS\n", sd); return 3; }
	if (isInstalled(tid) && !(idRegistryFind(s_registry, rom, &known) && known == tid))
	{
		printf("ERROR=%s belongs to another installed title\n", tidArg);
		return 5;
	}
	if (idRegistryHasTitle(s_registry, tid) && !(idRegistryFind(s_registry, rom, &known) && known == tid))
	{
		printf("ERROR=%s is registered to another game\n", tidArg);
		return 5;
	}

	data = readAll(tpl, &len);
	if (!data) { printf("ERROR=template not found\n"); return 3; }
	if ((err = cia_open(&cia, data, len)) != CIA_OK) { printf("ERROR=template unreadable (%d)\n", err); return 3; }
	if ((err = cia_set_rom_path(&cia, rom)) != CIA_OK) { printf("ERROR=rom path too long (%d)\n", err); return 3; }
	if ((err = cia_set_core_path(&cia, core)) != CIA_OK) { printf("ERROR=core path too long (%d)\n", err); return 3; }
	if ((err = cia_set_titles(&cia, name, pub ? pub : "RetroArch forwarder")) != CIA_OK) { printf("ERROR=titles (%d)\n", err); return 3; }

	if (icon)
	{
		uint8_t* smdh = cia_icon_data(&cia);
		if (!smdh || !iconApply(smdh, icon)) { printf("ERROR=icon image unreadable\n"); return 3; }
	}
	if (banner)
	{
		size_t reserved = 0;
		uint8_t* bnr = cia_banner_data(&cia, &reserved);
		uint8_t* rebuilt = bnr ? malloc(reserved) : NULL;
		size_t n = !rebuilt ? 0
			: flag(argc, argv, "--transparent") ? bannerReplaceImageAlpha(bnr, cia_banner_size(&cia), banner, rebuilt, reserved)
			: bannerReplaceImage(bnr, cia_banner_size(&cia), banner, rebuilt, reserved);
		if (!n || cia_set_banner(&cia, rebuilt, n) != CIA_OK) { free(rebuilt); printf("ERROR=banner image unreadable\n"); return 3; }
		free(rebuilt);
	}
	if (sound)
	{
		size_t wlen = 0, clen, reserved = 0, n;
		uint8_t* wav = readAll(sound, &wlen);
		uint8_t *cw = NULL, *bnr, *rebuilt;
		const char* why = "file not found";

		if (!wav || !(clen = cwavFromWav(wav, wlen, &cw, &why)))
		{
			free(wav);
			printf("ERROR=sound: %s\n", why);
			return 3;
		}
		free(wav);
		bnr = cia_banner_data(&cia, &reserved);
		rebuilt = bnr ? malloc(reserved) : NULL;
		n = rebuilt ? bannerSetSound(bnr, cia_banner_size(&cia), cw, clen, rebuilt, reserved) : 0;
		free(cw);
		if (!n || cia_set_banner(&cia, rebuilt, n) != CIA_OK)
		{
			free(rebuilt);
			printf("ERROR=sound too long for the banner (%lu KB free)\n", (unsigned long)(reserved / 1024));
			return 3;
		}
		free(rebuilt);
	}

	version = nextVersion(sd, tid);
	cia_set_title_id(&cia, tid);
	cia_set_version(&cia, (uint16_t)version);
	cia_set_process_name(&cia, name);
	cia_reseal(&cia);

	f = ufopen(out, "wb");
	if (!f || fwrite(data, 1, len, f) != len) { if (f) fclose(f); printf("ERROR=could not write %s\n", out); return 4; }
	fclose(f);
	free(data);

	// Reserve the id for this game before it is even installed.
	{
		char line[1200];
		if (!(idRegistryFind(s_registry, rom, &known) && known == tid))
		{
			if (idRegistryLine(line, sizeof(line), tid, rom))
				if (!appendLine(sd, "registry.txt", line)) printf("WARN=registry not updated\n");
		}
		snprintf(line, sizeof(line), "%08lX%08lX|%u\n",
			(unsigned long)(tid >> 32), (unsigned long)(tid & 0xFFFFFFFF), version);
		appendLine(sd, "versions.txt", line);
	}

	printf("OK=%s\n", out);
	printf("VERSION=%u\n", version);
	return 0;
}

// ---------------------------------------------------------------- DS
static int readNds(const char* path, uint8_t hdr[NDS_HEADER_SIZE], uint8_t banner[NDS_BANNER_MAX], size_t* blen)
{
	FILE* f = ufopen(path, "rb");
	uint32_t off;
	if (!f) return 0;
	if (fread(hdr, 1, NDS_HEADER_SIZE, f) != NDS_HEADER_SIZE) { fclose(f); return 0; }
	off = ndsBannerOffset(hdr);
	if (!off || off > 0x7FFFFFFF || fseek(f, (long)off, SEEK_SET) != 0) { fclose(f); return 0; }
	*blen = fread(banner, 1, NDS_BANNER_MAX, f);
	fclose(f);
	return *blen > 0;
}

static int writeBmp(const char* path, const uint8_t* rgb, int w, int h)
{
	uint8_t hd[54] = { 'B', 'M' };
	int row = (w * 3 + 3) & ~3, y, x;
	uint32_t size = 54 + (uint32_t)row * h;
	FILE* f = ufopen(path, "wb");
	uint8_t line[1024] = { 0 };
	if (!f || row > (int)sizeof(line)) { if (f) fclose(f); return 0; }
#define W32(o, v) (hd[o] = (uint8_t)(v), hd[o + 1] = (uint8_t)((v) >> 8), hd[o + 2] = (uint8_t)((v) >> 16), hd[o + 3] = (uint8_t)((v) >> 24))
	W32(2, size); W32(10, 54); W32(14, 40); W32(18, w); W32(22, h);
	hd[26] = 1; hd[28] = 24;
#undef W32
	fwrite(hd, 1, 54, f);
	for (y = h - 1; y >= 0; y--)
	{
		for (x = 0; x < w; x++)
		{
			line[x * 3] = rgb[(y * w + x) * 3 + 2];
			line[x * 3 + 1] = rgb[(y * w + x) * 3 + 1];
			line[x * 3 + 2] = rgb[(y * w + x) * 3];
		}
		fwrite(line, 1, (size_t)row, f);
	}
	fclose(f);
	return 1;
}

static int cmdNdsInfo(int argc, char** argv)
{
	const char* rom = arg(argc, argv, "--rom");
	const char* bmp = arg(argc, argv, "--icon-bmp");
	static uint8_t banner[NDS_BANNER_MAX];
	uint8_t hdr[NDS_HEADER_SIZE], rgb[48 * 48 * 3];
	static nds_info info;
	char line[512], name[1024];
	size_t blen = 0;
	int lines, i;

	if (!rom) { fprintf(stderr, "ndsinfo: --rom is required\n"); return 2; }
	if (!readNds(rom, hdr, banner, &blen)) { printf("ERROR=not a DS ROM\n"); return 3; }
	if (ndsReadInfo(hdr, banner, blen, &info) != 0) { printf("ERROR=the ROM has no banner\n"); return 3; }
	printf("GAMECODE=%s\n", info.gamecode);

	// "Star Wars\nThe Force Unleashed\nLucasArts": the last line is the
	// publisher, the others the name.
	lines = ndsTitleLines(&info, 1);
	name[0] = 0;
	for (i = 0; i < (lines > 1 ? lines - 1 : lines); i++)
	{
		ndsTitleLine(&info, 1, i, line, sizeof(line));
		if (name[0] && line[0]) strncat(name, " ", sizeof(name) - strlen(name) - 1);
		strncat(name, line, sizeof(name) - strlen(name) - 1);
	}
	printf("TITLE=%s\n", name);
	if (lines > 1) { ndsTitleLine(&info, 1, -1, line, sizeof(line)); printf("MAKER=%s\n", line); }

	if (bmp)
	{
		if (ndsIcon48(banner, blen, rgb) != 0 || !writeBmp(bmp, rgb, 48, 48)) { printf("ERROR=icon\n"); return 4; }
		printf("ICON=%s\n", bmp);
	}
	return 0;
}

static int writeFile(const char* path, const uint8_t* d, size_t n)
{
	FILE* f = ufopen(path, "wb");
	if (!f) return 0;
	if (fwrite(d, 1, n, f) != n) { fclose(f); return 0; }
	return fclose(f) == 0;
}

static int cmdDs(int argc, char** argv)
{
	const char* tpl = arg(argc, argv, "--template");
	const char* rom = arg(argc, argv, "--rom");
	const char* name = arg(argc, argv, "--name");
	const char* pub = arg(argc, argv, "--publisher");
	const char* banner = arg(argc, argv, "--banner");
	const char* sound = arg(argc, argv, "--sound");
	const char* bannerOut = arg(argc, argv, "--banner-out");
	const char* smdhOut = arg(argc, argv, "--smdh-out");
	static uint8_t nb[NDS_BANNER_MAX];
	uint8_t hdr[NDS_HEADER_SIZE], rgb[48 * 48 * 3], smdh[0x36C0];
	uint8_t *data, *icon, *bnr, *cur;
	size_t len, blen = 0, reserved = 0, curLen;
	cia_t cia;
	int err;

	if (!tpl || !rom || !name || !bannerOut || !smdhOut)
	{
		fprintf(stderr, "ds: --template --rom --name --banner-out --smdh-out are required\n");
		return 2;
	}
	if (!readNds(rom, hdr, nb, &blen) || ndsIcon48(nb, blen, rgb) != 0) { printf("ERROR=not a DS ROM with an icon\n"); return 3; }

	data = readAll(tpl, &len);
	if (!data) { printf("ERROR=template not found\n"); return 3; }
	if ((err = cia_open(&cia, data, len)) != CIA_OK) { printf("ERROR=template unreadable (%d)\n", err); return 3; }

	// The SMDH: the template's, with this game's titles and DS icon.
	icon = cia_icon_data(&cia);
	if (!icon) { printf("ERROR=template has no icon\n"); return 3; }
	memcpy(smdh, icon, sizeof(smdh));
	if (smdh_set_titles(smdh, name, pub ? pub : "Nintendo DS") != CIA_OK || !iconApplyRgb(smdh, rgb, 48))
	{
		printf("ERROR=icon\n");
		return 3;
	}

	// The banner: the template's, worked on in a buffer of its own.
	bnr = cia_banner_data(&cia, &reserved);
	if (!bnr) { printf("ERROR=template has no banner\n"); return 3; }
	curLen = cia_banner_size(&cia);
	cur = malloc(reserved);
	if (!cur) return 3;
	memcpy(cur, bnr, curLen);
	if (banner)
	{
		uint8_t* rebuilt = malloc(reserved);
		size_t n = !rebuilt ? 0
			: flag(argc, argv, "--transparent") ? bannerReplaceImageAlpha(cur, curLen, banner, rebuilt, reserved)
			: bannerReplaceImage(cur, curLen, banner, rebuilt, reserved);
		if (!n) { free(rebuilt); printf("ERROR=banner image unreadable\n"); return 3; }
		free(cur); cur = rebuilt; curLen = n;
	}
	if (sound)
	{
		size_t wlen = 0, clen, n;
		uint8_t* wav = readAll(sound, &wlen);
		uint8_t *cw = NULL, *rebuilt;
		const char* why = "file not found";
		if (!wav || !(clen = cwavFromWav(wav, wlen, &cw, &why))) { free(wav); printf("ERROR=sound: %s\n", why); return 3; }
		free(wav);
		rebuilt = malloc(reserved);
		n = rebuilt ? bannerSetSound(cur, curLen, cw, clen, rebuilt, reserved) : 0;
		free(cw);
		if (!n) { free(rebuilt); printf("ERROR=sound too long for the banner\n"); return 3; }
		free(cur); cur = rebuilt; curLen = n;
	}

	if (!writeFile(bannerOut, cur, curLen) || !writeFile(smdhOut, smdh, sizeof(smdh)))
	{
		printf("ERROR=could not write the output files\n");
		return 4;
	}
	free(cur);
	free(data);
	printf("OK=%s\nBANNER_SIZE=%lu\n", bannerOut, (unsigned long)curLen);
	return 0;
}

static int run(int argc, char** argv)
{
	if (argc >= 2 && strcmp(argv[1], "tid") == 0) return cmdTid(argc, argv);
	if (argc >= 2 && strcmp(argv[1], "build") == 0) return cmdBuild(argc, argv);
	if (argc >= 2 && strcmp(argv[1], "ndsinfo") == 0) return cmdNdsInfo(argc, argv);
	if (argc >= 2 && strcmp(argv[1], "ds") == 0) return cmdDs(argc, argv);
	fprintf(stderr, "usage: fwdgen-pc tid|build|ndsinfo|ds ...\n");
	return 1;
}

#ifdef _WIN32
// Arguments arrive as UTF-16 and are handed on as UTF-8, so game names and
// paths with accents survive.
int wmain(int argc, wchar_t** wargv)
{
	char** argv = calloc((size_t)argc + 1, sizeof(char*));
	int i, n;
	SetConsoleOutputCP(CP_UTF8);
	for (i = 0; i < argc; i++)
	{
		n = WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, NULL, 0, NULL, NULL);
		argv[i] = malloc((size_t)n);
		WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, argv[i], n, NULL, NULL);
	}
	return run(argc, argv);
}
#else
int main(int argc, char** argv) { return run(argc, argv); }
#endif
