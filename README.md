# RetroArch Forwarder Generator for 3DS

> Fork of [Fadgiras/RetroArchForwarder3DS](https://github.com/Fadgiras/RetroArchForwarder3DS).
> The forwarders are prepared on Windows instead of on the console, with safe
> title ids, SteamGridDB and libretro artwork, a live preview, banner sounds
> and whole folders at once. The on-console generator (`fwdgen.3dsx`) was
> removed; v1.0.0 is the last release that has it.

Turns a ROM on your SD card into a HOME menu icon that launches it straight in
**your installed RetroArch**, with your own settings, overrides and saves.
The game stays on the SD card; the forwarder is a small CIA (about 700 KB)
that only starts it.

**RetroArch Forwarder PC** prepares everything on the PC, each picture chosen
by eye, and saves the finished CIA to the SD card, to be installed with FBI.

## Requirements

- **Luma3DS**, and the **Homebrew Launcher title installed** (`hblauncher_loader`,
  title id `000400000D921E00`). The forwarder jumps to it, see below.
- The RetroArch core as a **`.3dsx`**, not as a CIA — for example
  `sdmc:/retroarch/cores/pcsx_rearmed_libretro.3dsx`. Both that directory and
  `sdmc:/3ds/` are scanned. A RetroArch installed as a CIA has its cores as
  `.cia` only: the `.3dsx` ones ship inside `RetroArch_3dsx.7z`, one archive
  per release on the [libretro buildbot](https://buildbot.libretro.com/stable/).
  Take the archive matching the RetroArch you run, rather than the nightly
  cores: mixing a recent core with older assets leaves the bottom screen
  mislabelled.
- The game on the SD card. For multi-disc games pick the **`.m3u`**: discs
  can be swapped from RetroArch's *Disc Control* and they share one memory
  card.
- Windows with PowerShell 5.1 (any current Windows 10 or 11), and the SD card
  in the PC.

## Usage

The interface is in Spanish. Download `RetroArch-Forwarder-PC.zip` from the
[releases](../../releases), unzip it anywhere and double-click
`RetroArch Forwarder PC.bat`. The folder holds:

- `RetroArch Forwarder PC.bat`, `RetroArchForwarderPC.ps1` and a short guide
  (`LEEME.txt`, in Spanish), from `pc/`
- `fwdgen-pc.exe`, see [Getting fwdgen-pc.exe](#getting-fwdgen-pcexe)
- `template.cia`, from `template/`

Then, with the console's SD card in the PC:

1. **SD**: detected by its `Nintendo 3DS` folder. The cores found on it fill
   the *Core* list.
2. **Game**: pick it on that card, since the forwarder opens it from there.
   Its file name, without region or disc tags, becomes the title, the
   platform (*PlayStation*, *Game Boy*, *Super Nintendo*...) the publisher
   shown on the HOME menu, and the title id
   it will get is shown with the reason: free, an update of this game's
   forwarder, or moved because another title holds the hashed id.
3. **Artwork**, in order of priority:
   - local files: `logos\<game>.png`, `covers\<game>.png|jpg` (background),
     `icons\<game>.png`;
   - SteamGridDB: with an API key, the game is searched and its *Logos*,
     *Heroes* (backgrounds), *Grids* (covers) and *Icons* appear as thumbnails;
     click one to use it. The first of each can be picked automatically;
   - the libretro title screen, as the background, when nothing else is set.
   - **libretro covers**: *Icono: portada de libretro* makes the icon from the
     game's `Named_Boxarts`, whole, over a blurred copy of itself (a file in
     `icons\` still wins); *Banner: portada de libretro* does the same for the
     banner, instead of logo and background, or alone on a transparent banner.
     libretro images come from the
     [libretro-thumbnails](https://github.com/libretro-thumbnails) repositories
     on GitHub, following their renamed-game symlinks, with
     thumbnails.libretro.com as the fallback.
4. **Banner**: the logo over the background, blurred and dimmed, or the
   background alone. The **transparent banner** option keeps only the logo, so the
   HOME menu shows through. The icon always has a background: icons carry
   no alpha.
5. **Sound**: the jingle played when the icon is selected on the HOME menu,
   **one per system**: a sound picked with a PlayStation game open only goes
   on PlayStation games. Pick any WAV (PCM, 8 or 16 bit, mono or stereo, up
   to 3 seconds, longer ones are cut). No system has one at first: until one
   is picked the icon stays silent (the template's sound is one second of
   silence).
6. **Build the CIA**: it is saved by default to `<SD>\cias\`. Install it
   with FBI.

**Several games at once**: *Varios juegos...* lists every game of a folder on
the SD card (subfolders optional) and builds them all into `<SD>\cias\`.

- A `.m3u` stands for the discs it lists, which are hidden; a `.cue` hides
  its tracks. Discs named `(Disc 1)`, `(Disc 2)`... without a `.m3u` get one,
  written when the CIAs are built.
- A game found in several formats (`Game.chd` and `Game.cue`) is listed once
  checked, in the best format (`.m3u`, `.chd`, `.pbp`, `.cue`, ...).
- Games the registry already gives a forwarder start unchecked.
- Each game takes its local images first, the first SteamGridDB logo, hero and
  icon for what is missing, and the libretro title screen as a last resort
  background. The transparent banner option and the sound apply to all.
- Double-click a game to open it in the main window and adjust it by hand.

**Cartridge games**: the core follows the file extension, among the `.3dsx`
cores on the card: `.gb`/`.gbc` gambatte, `.gba` gpsp, `.nes` nestopia,
`.sfc`/`.smc` snes9x2005_plus, `.a26` stella2014, and so on, falling back to
the next installed core for that system. A `.zip` is judged by the ROM inside.
Extensions that say nothing (`.bin`, `.7z`) keep the core chosen by hand. The
extension also picks the libretro thumbnail folder, so a `.gb` game looks in
*Game Boy*, not *Game Boy Color*. In *Varios juegos...* each game gets its own
core, so one folder can mix systems.

Rebuilding a game keeps its title id and raises the title version, so the
HOME menu refreshes the icon when the new CIA is installed over the old one.
The API key is kept in `settings.json`, next to the script, in plain text;
on first run it is taken from a neighbouring *PS1 Forwarder Creator Plus*
folder if there is one. Folders picked last are remembered, relative to the
SD card. Problems are logged to `log.txt`.

### Getting fwdgen-pc.exe

`fwdgen-pc.exe` is the command line the GUI drives, built from `pc/` and
`source/`. Build it with [zig](https://ziglang.org) (`pip install ziglang`):

```
sh pc/build.sh
```

or take `RetroArch-Forwarder-PC.zip` from the releases, or the `fwdgen-pc`
artifact of the *build* workflow, which bundle it with the GUI, the guide and
`template.cia`.

It can be used on its own:

```
fwdgen-pc tid   --sd E: --rom "sdmc:/roms/psx/Game.chd"
fwdgen-pc build --sd E: --template template.cia --rom "sdmc:/roms/psx/Game.chd" ^
                --core "sdmc:/retroarch/cores/pcsx_rearmed_libretro.3dsx" ^
                --name "Game" --tid 000400000FF1C100 --icon icon.png ^
                --banner banner.png [--transparent] [--sound jingle.wav] --out Game.cia
```

`tid` prints the id the game would get; `build` refuses an id that belongs
to another title, then records it in the registry.

## How the forwarder launches the game

**Not** through the APT deliver argument. RetroArch does receive it but never
acts on it — its own *Restart RetroArch* loses the loaded content the same way,
on 1.9.14 as on 1.22.2. That is a RetroArch defect, not something a forwarder
can work around.

So the forwarder calls Luma3DS's **`hb:ldr`**, the very service that makes the
Homebrew Launcher CIA work. It sets the target (the core `.3dsx`) and the
arguments (`argv[0]` the core, `argv[1]` the ROM), then chainloads the Homebrew
Launcher title `000400000D921E00`. Luma's loader recognises that title id and
loads the `.3dsx` with those arguments — the 3dsx loader argv channel, which
does work.

## How the CIA is built

Every forwarder starts from `template/template.cia`, and only fixed-size
fields are rewritten, so nothing downstream in the file ever moves:

| Field | Marker / location |
| --- | --- |
| ROM path | `FWD0ROM!` in `.code`, 256 reserved bytes |
| Core path | `FWD0CRE!` in `.code`, 256 reserved bytes |
| SMDH titles and icon | `icon` section, always 14016 bytes |
| Banner | `banner` section, oversized to 512 KB on purpose |
| Title id and version | NCCH header, ExHeader, TMD and ticket |

The whole hash chain is then recomputed, leaf to root:

```
sha256(.code)            -> ExeFS header, slots stored in reverse order
sha256(ExeFS header)     -> NCCH 0x1C0
sha256(ExHeader)         -> NCCH 0x160
sha256(NCCH content)     -> TMD content chunk record
sha256(chunk record)     -> TMD info record
sha256(64 info records)  -> TMD 0xA4
```

The RSA signature is not recomputed: custom firmware does not check it.

`.code` is left uncompressed (`EnableCompress: false` in the RSF) so the path
fields can be rewritten in place.

### Banner format

A banner is a **CBMD**: a header pointing at an LZ11-compressed CGFX (offset at
`0x08`) and at the audio (offset at `0x84`). The CGFX ends with the texture:
**256x128 in RGBA4444**, tiled in 8x8 blocks whose pixels follow a Morton
order — the same tiling as icons, which are RGB565.

`fwdgen-pc` inflates the CGFX, swaps the texture (alpha kept for a
transparent banner), recompresses and re-appends the audio with its offset
fixed. The LZ11 encoder emits literals only, never back
references: eight times simpler to implement, at the cost of 12.5% in size.
That, and room for a 3-second sound, is why the banner section is reserved at
512 KB.

### Banner sound

The sound sits after the CGFX in the CBMD, as a CWAV (offset at `0x84`). A WAV
becomes a PCM16 CWAV laid out exactly as bannertool writes it (checked byte for
byte against it), and replaces the template's. Three seconds of stereo PCM16
at 32 kHz is 375 KB, so the template reserves **512 KB** for the banner
(`tools/grow_banner.py` enlarged it from 256 KB). Each forwarder is about
700 KB as a result.

### Title version

The HOME menu caches icons and only reloads them when the title version
changes. The installed version cannot be read from the PC (the SD copy is
encrypted), so `sdmc:/forwarders/versions.txt` keeps a count per title id,
starting at 2048: every rebuild installs over the previous one and refreshes
the icon without uninstalling first.

## Safety

The `0xFF000-0xFFFFF` unique id range is not reserved for these forwarders:
NDS forwarders and homebrew built with a default RSF install titles there too.
So the id hashed from the ROM path is only a starting point:

- The titles installed on the SD card are read first: the folders under
  `Nintendo 3DS\...\title\00040000`. With none at all, the build stops: that is
  the wrong drive.
- An id that holds another installed title is **never** reused. The game moves
  on to the next free id, and the window says so. Since the PC cannot read a
  title's product code (the SD copy is encrypted), an installed title counts as
  this game's forwarder only when the registry says so.
- `sdmc:/forwarders/registry.txt` records the id each ROM received, one
  `TITLEID|path` line per forwarder. Rebuilding a game updates its own
  forwarder, and an id once given to a game is never handed to another, even
  after that forwarder is uninstalled.
- `fwdgen-pc build` checks all this again just before writing, whatever the
  GUI decided.
- Nothing outside the range is ever touched.

## Building

```
sh pc/build.sh
```

needs [zig](https://ziglang.org) (`pip install ziglang`), which cross-compiles
`fwdgen-pc.exe` for Windows from Linux, macOS or Windows. The GUI is a plain
PowerShell script and needs no build.

`template/template.cia` carries the forwarder itself (the code that calls
`hb:ldr`). It was produced by Python tooling that is not part of this
repository; `tools/grow_banner.py` enlarged its banner section to 512 KB.

## Tests

The patching routines compile on any PC, where their output was compared byte
for byte against a Python reference, and the CWAV against bannertool's.

```
gcc -O2 -o host/test_sha host/test_sha.c source/sha256.c
./host/test_sha

gcc -O2 -o host/test_idalloc host/test_idalloc.c source/idalloc.c source/sha256.c
./host/test_idalloc

gcc -O2 -o host/test_cwav host/test_cwav.c source/cwav.c
./host/test_cwav

gcc -O2 -o host/test_icon host/test_icon.c source/icongen.c -lm
gcc -O2 -o host/test_banner host/test_banner.c source/bannergen.c source/icongen.c -lm
gcc -O2 -o host/test_patch host/test_patch.c source/cia_patch.c source/sha256.c
gcc -O2 -o host/test_compose host/test_compose.c source/bannergen.c source/icongen.c -lm
gcc -O2 -o host/reseal host/reseal.c source/cia_patch.c source/sha256.c
```

## Limitations

- The banner reservation (512 KB, to fit a 3-second sound) makes every
  forwarder about 700 KB.
- Names are reduced to ASCII in the SMDH titles.
- ROM and core paths are limited to 255 bytes each.
- The forwarder targets a **path**: moving or renaming the game or the core
  breaks it until it is rebuilt. Replacing the core with a newer one under the
  same name needs nothing.

## License

MIT, see [LICENSE](LICENSE).

`source/stb_image.h` is vendored third party code, released by its author into
the public domain (or under MIT, at your option) — either way compatible.
`source/cwav.c` follows the CWAV layout of
[bannertool](https://github.com/Steveice10/bannertool) (MIT).

## Credits

Image decoding uses [stb_image](https://github.com/nothings/stb). Artwork comes
from [SteamGridDB](https://www.steamgriddb.com) and the
[libretro thumbnail repositories](https://github.com/libretro-thumbnails).
