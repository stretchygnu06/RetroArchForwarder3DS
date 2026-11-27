// Forwarder stub: the program inside every forwarder CIA.
//
// It hands the core and the game to Luma3DS hb:ldr, then chainloads the
// Homebrew Launcher title, which hb:ldr replaces with the core. The PC tool
// patches the two paths below in the built CIA, so their layout is fixed:
// an 8-byte marker followed by 256 bytes.
//
// RetroArch on 3DS is a static build: it never learns which core it is from
// its arguments, only from retroarch-salamander.cfg. Without updating that
// file first, RetroArch labels the game with the last core used through its
// own menu, and records that core in its history.
#include <3ds.h>
#include <stdio.h>
#include <string.h>

#define PATH_MAX_LEN 256
#define HBL_TITLE 0x000400000D921E00ULL
#define SALAMANDER "sdmc:/retroarch/retroarch-salamander.cfg"
#define CORES_DIR "sdmc:/retroarch/cores/"

typedef struct { char magic[8]; char path[PATH_MAX_LEN]; } fwd_field;

__attribute__((used, aligned(4))) fwd_field fwd_rom = { "FWD0ROM!", "sdmc:/roms/placeholder.bin" };
__attribute__((used, aligned(4))) fwd_field fwd_core = { "FWD0CRE!", "sdmc:/3ds/pcsx_rearmed_libretro.3dsx" };

static Handle hbldr;
static u32 argbuf[0x400 / 4];

static void say(const char* s) { fputs(s, stdout); }

static void fail(const char* what, Result rc)
{
	static const char hex[] = "0123456789ABCDEF";
	char code[11] = "0x";
	int i;
	for (i = 0; i < 8; i++) code[2 + i] = hex[((u32)rc >> (28 - 4 * i)) & 0xF];
	code[10] = 0;

	say("\n  Error: "); say(what);
	say("\n  Code : "); say(code);
	say("\n\n  Check that Luma3DS is running and the\n");
	say("  Homebrew Launcher is installed.\n\n  START to exit.\n");
	while (aptMainLoop())
	{
		hidScanInput();
		if (hidKeysDown() & KEY_START) break;
		gfxFlushBuffers();
		gfxSwapBuffers();
		gspWaitForVBlank();
	}
}

// Points retroarch-salamander.cfg at this core. The .cia of the same core is
// preferred when installed, so RetroArch's own launcher stays on a core it can
// start; RetroArch matches cores by file name, so either one names the system.
static void set_salamander(const char* core)
{
	char path[PATH_MAX_LEN + 32];
	const char* base = strrchr(core, '/');
	const char* dot;
	size_t n;
	FILE* f;

	base = base ? base + 1 : core;
	dot = strrchr(base, '.');
	n = dot ? (size_t)(dot - base) : strlen(base);
	if (n == 0 || n + sizeof(CORES_DIR) + 4 > sizeof(path)) return;

	memcpy(path, CORES_DIR, sizeof(CORES_DIR) - 1);
	memcpy(path + sizeof(CORES_DIR) - 1, base, n);
	strcpy(path + sizeof(CORES_DIR) - 1 + n, ".cia");

	f = fopen(path, "rb");
	if (f) fclose(f);
	else
	{
		strncpy(path, core, sizeof(path) - 1);
		path[sizeof(path) - 1] = 0;
	}

	f = fopen(SALAMANDER, "w");
	if (!f) return;
	fputs("libretro_path = \"", f);
	fputs(path, f);
	fputs("\"\n", f);
	fclose(f);
}

// hb:ldr receives the target in static buffer 0 and the arguments in buffer 1.
static Result hbldr_call(u32 header, const void* buf, size_t len, int id)
{
	u32* cmd = getThreadCommandBuffer();
	Result rc;
	cmd[0] = header;
	cmd[1] = IPC_Desc_StaticBuffer(len, id);
	cmd[2] = (u32)buf;
	rc = svcSendSyncRequest(hbldr);
	return R_FAILED(rc) ? rc : (Result)cmd[1];
}

int main(void)
{
	const char* core = fwd_core.path;
	const char* rom = fwd_rom.path;
	const char* target = core;
	const char* name = strrchr(rom, '/');
	char* args = (char*)(argbuf + 1);
	size_t core_len = strlen(core) + 1, rom_len = strlen(rom) + 1;
	Result rc;
	int frames;

	gfxInitDefault();
	consoleInit(GFX_TOP, NULL);
	say("\x1b[2;3H"); say(name ? name + 1 : rom);
	say("\n\n  Starting RetroArch...\n");

	rc = srvGetServiceHandle(&hbldr, "hb:ldr");
	if (R_FAILED(rc)) { fail("connecting to hb:ldr", rc); gfxExit(); return 0; }

	// hb:ldr wants the target without the archive prefix.
	if (strncmp(core, "sdmc:/", 6) == 0) target = core + 5;

	memset(argbuf, 0, sizeof(argbuf));
	if (core_len + rom_len > sizeof(argbuf) - 4) { fail("paths too long", 0); gfxExit(); return 0; }
	memcpy(args, core, core_len);
	memcpy(args + core_len, rom, rom_len);
	argbuf[0] = 2;

	rc = hbldr_call(IPC_MakeHeader(2, 0, 2), target, strlen(target) + 1, 0);
	if (R_FAILED(rc)) { fail("hb:ldr SetTarget", rc); gfxExit(); return 0; }
	rc = hbldr_call(IPC_MakeHeader(3, 0, 2), argbuf, sizeof(argbuf), 1);
	if (R_FAILED(rc)) { fail("hb:ldr SetArgv", rc); gfxExit(); return 0; }
	// The handle stays open, as in the original stub, until the process ends.
	set_salamander(core);

	aptSetChainloader(HBL_TITLE, MEDIATYPE_SD);
	for (frames = 20; frames > 0 && aptMainLoop(); frames--)
	{
		gfxFlushBuffers();
		gfxSwapBuffers();
		gspWaitForVBlank();
	}
	gfxExit();
	return 0;
}
