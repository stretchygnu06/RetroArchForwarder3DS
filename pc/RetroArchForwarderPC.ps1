#Requires -Version 5.1
<#
  RetroArch Forwarder PC
  ---------------------------------------------------------------
  Crea en Windows el mismo CIA que fwdgen.3dsx (RetroArch Forwarder
  Generator): un icono en el menu HOME que abre un juego de la SD en tu
  RetroArch instalado, con tu configuracion y tus partidas.

  - Logo, fondo e icono desde SteamGridDB (API key) o archivos locales.
  - Vista previa del banner (256x128) y del icono (48x48).
  - Lee la SD para elegir un Title ID libre: nunca reutiliza el de otro
    titulo instalado (por ejemplo tus forwarders de DS).
  - El CIA lo arma fwdgen-pc.exe con el mismo codigo que la app de 3DS.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$script:Root     = $PSScriptRoot
$script:Cli      = Join-Path $script:Root 'fwdgen-pc.exe'
$script:Template = Join-Path $script:Root 'template.cia'
$script:CacheDir = Join-Path $script:Root 'cache'
$script:Settings = Join-Path $script:Root 'settings.json'
$script:LogFile  = Join-Path $script:Root 'log.txt'
$script:ApiBase  = 'https://www.steamgriddb.com/api/v2'
$script:Thumbs   = 'http://thumbnails.libretro.com'
$script:AppName  = 'RetroArch Forwarder PC'

function Show-Error([string]$msg) { [void][System.Windows.Forms.MessageBox]::Show($msg, $script:AppName, 'OK', 'Error') }
function Write-Log([string]$msg) {
    try { Add-Content -LiteralPath $script:LogFile -Value ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

foreach ($f in @($script:Cli, $script:Template)) {
    if (-not (Test-Path -LiteralPath $f)) { Show-Error "Falta $([IO.Path]::GetFileName($f)) junto a este programa."; exit 1 }
}
foreach ($d in @('logos', 'covers', 'icons', 'cache')) {
    $p = Join-Path $script:Root $d
    if (-not (Test-Path -LiteralPath $p)) { [void](New-Item -ItemType Directory -Path $p) }
}

# ---------------------------------------------------------------- image helpers (C#)
if (-not ('FwdArt' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class FwdArt
{
    static byte[] Get(Bitmap b)
    {
        BitmapData d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] a = new byte[d.Stride * b.Height];
        Marshal.Copy(d.Scan0, a, 0, a.Length);
        b.UnlockBits(d);
        return a;
    }

    static void Put(Bitmap b, byte[] a)
    {
        BitmapData d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(a, 0, d.Scan0, a.Length);
        b.UnlockBits(d);
    }

    static Graphics Hq(Bitmap b)
    {
        Graphics g = Graphics.FromImage(b);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.SmoothingMode = SmoothingMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;
        return g;
    }

    // Fills w x h, cropping the excess around the centre.
    public static Bitmap Cover(Image src, int w, int h)
    {
        Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Hq(b))
        using (ImageAttributes ia = new ImageAttributes())
        {
            ia.SetWrapMode(WrapMode.TileFlipXY);
            double s = Math.Max((double)w / src.Width, (double)h / src.Height);
            int dw = (int)Math.Ceiling(src.Width * s), dh = (int)Math.Ceiling(src.Height * s);
            g.Clear(Color.Black);
            g.DrawImage(src, new Rectangle((w - dw) / 2, (h - dh) / 2, dw, dh), 0, 0, src.Width, src.Height, GraphicsUnit.Pixel, ia);
        }
        return b;
    }

    // Three box blur passes, then multiplies the colour by keep (0..1).
    public static void BlurDarken(Bitmap b, int radius, double keep)
    {
        int w = b.Width, h = b.Height, x, y, c, k, pass;
        byte[] a = Get(b);
        byte[] t = new byte[a.Length];
        for (pass = 0; pass < 3 && radius > 0; pass++)
        {
            for (y = 0; y < h; y++)
                for (x = 0; x < w; x++)
                    for (c = 0; c < 3; c++)
                    {
                        int sum = 0, n = 0;
                        for (k = -radius; k <= radius; k++)
                        {
                            int xx = x + k;
                            if (xx < 0 || xx >= w) continue;
                            sum += a[(y * w + xx) * 4 + c]; n++;
                        }
                        t[(y * w + x) * 4 + c] = (byte)(sum / n);
                    }
            for (y = 0; y < h; y++)
                for (x = 0; x < w; x++)
                    for (c = 0; c < 3; c++)
                    {
                        int sum = 0, n = 0;
                        for (k = -radius; k <= radius; k++)
                        {
                            int yy = y + k;
                            if (yy < 0 || yy >= h) continue;
                            sum += t[(yy * w + x) * 4 + c]; n++;
                        }
                        a[(y * w + x) * 4 + c] = (byte)(sum / n);
                    }
        }
        for (int i = 0; i < a.Length; i += 4)
        {
            a[i] = (byte)(a[i] * keep); a[i + 1] = (byte)(a[i + 1] * keep); a[i + 2] = (byte)(a[i + 2] * keep);
            a[i + 3] = 255;
        }
        Put(b, a);
    }

    public static Bitmap Gradient(int w, int h)
    {
        Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(b))
        using (LinearGradientBrush br = new LinearGradientBrush(new Rectangle(0, 0, w, h),
                   Color.FromArgb(48, 48, 60), Color.FromArgb(20, 20, 28), LinearGradientMode.Vertical))
            g.FillRectangle(br, 0, 0, w, h);
        return b;
    }

    // Drops the fully transparent margins around a logo.
    public static Bitmap Trim(Image src)
    {
        Bitmap b = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(b)) g.DrawImage(src, 0, 0, src.Width, src.Height);
        byte[] a = Get(b);
        int w = b.Width, h = b.Height, minx = w, miny = h, maxx = -1, maxy = -1;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (a[(y * w + x) * 4 + 3] > 8)
                {
                    if (x < minx) minx = x; if (x > maxx) maxx = x;
                    if (y < miny) miny = y; if (y > maxy) maxy = y;
                }
        if (maxx < 0) return b;
        Bitmap r = b.Clone(new Rectangle(minx, miny, maxx - minx + 1, maxy - miny + 1), PixelFormat.Format32bppArgb);
        b.Dispose();
        return r;
    }

    // Draws a logo inside the box, centred, aspect kept, with a soft shadow.
    public static void DrawLogo(Bitmap dst, Image logo, int boxW, int boxH, bool shadow)
    {
        using (Bitmap t = Trim(logo))
        {
            double s = Math.Min((double)boxW / t.Width, (double)boxH / t.Height);
            if (s > 2.0) s = 2.0;
            int dw = Math.Max(1, (int)Math.Round(t.Width * s)), dh = Math.Max(1, (int)Math.Round(t.Height * s));
            int ox = (dst.Width - dw) / 2, oy = (dst.Height - dh) / 2;
            using (Bitmap fit = new Bitmap(dw, dh, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Hq(fit)) g.DrawImage(t, 0, 0, dw, dh);
                using (Graphics g = Hq(dst))
                {
                    if (shadow)
                    {
                        Bitmap sh = Silhouette(fit, dst.Width, dst.Height, ox, oy + 1);
                        g.DrawImage(sh, 0, 0);
                        sh.Dispose();
                    }
                    g.DrawImage(fit, ox, oy, dw, dh);
                }
            }
        }
    }

    static Bitmap Silhouette(Bitmap logo, int w, int h, int ox, int oy)
    {
        Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        byte[] src = Get(logo);
        byte[] a = new byte[w * h * 4];
        byte[] t = new byte[w * h];
        byte[] al = new byte[w * h];
        int lw = logo.Width, lh = logo.Height, x, y, k, r = 2;
        for (y = 0; y < lh; y++)
            for (x = 0; x < lw; x++)
            {
                int X = x + ox, Y = y + oy;
                if (X < 0 || Y < 0 || X >= w || Y >= h) continue;
                al[Y * w + X] = src[(y * lw + x) * 4 + 3];
            }
        for (int pass = 0; pass < 2; pass++)
        {
            for (y = 0; y < h; y++) for (x = 0; x < w; x++)
            { int s = 0, n = 0; for (k = -r; k <= r; k++) { int xx = x + k; if (xx < 0 || xx >= w) continue; s += al[y * w + xx]; n++; } t[y * w + x] = (byte)(s / n); }
            for (y = 0; y < h; y++) for (x = 0; x < w; x++)
            { int s = 0, n = 0; for (k = -r; k <= r; k++) { int yy = y + k; if (yy < 0 || yy >= h) continue; s += t[yy * w + x]; n++; } al[y * w + x] = (byte)(s / n); }
        }
        for (int i = 0; i < w * h; i++) a[i * 4 + 3] = (byte)(al[i] * 0.8);
        Put(b, a);
        return b;
    }

    // Banner or icon: logo over the background (blurred, dimmed), or the
    // background alone, filling the frame.
    public static Bitmap Compose(Image bg, Image logo, int w, int h, int boxW, int boxH, int blur)
    {
        Bitmap b;
        if (bg != null)
        {
            b = Cover(bg, w, h);
            if (logo != null) BlurDarken(b, blur, 0.6);
        }
        else
            b = Gradient(w, h);
        if (logo != null) DrawLogo(b, logo, boxW, boxH, true);
        return b;
    }

    // A dedicated icon fitted over the (blurred, dimmed) background.
    public static Bitmap ComposeIcon(Image bg, Image icon)
    {
        Bitmap b = bg != null ? Cover(bg, 48, 48) : Gradient(48, 48);
        if (bg != null) BlurDarken(b, 1, 0.6);
        using (Graphics g = Hq(b))
        {
            double s = Math.Min(48.0 / icon.Width, 48.0 / icon.Height);
            int dw = Math.Max(1, (int)Math.Round(icon.Width * s)), dh = Math.Max(1, (int)Math.Round(icon.Height * s));
            g.DrawImage(icon, (48 - dw) / 2, (48 - dh) / 2, dw, dh);
        }
        return b;
    }

    // Only the logo, on a fully transparent banner: the HOME menu shows
    // through around it.
    public static Bitmap LogoOnly(Image logo, int w, int h, int boxW, int boxH)
    {
        Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(b)) g.Clear(Color.Transparent);
        DrawLogo(b, logo, boxW, boxH, false);
        return b;
    }

    public static void SaveAlpha(Bitmap b, string path)
    {
        b.Save(path, ImageFormat.Png);
    }

    // Icons store no alpha: save flattened, the way it will look.
    public static void SaveOpaque(Bitmap b, string path)
    {
        using (Bitmap o = new Bitmap(b.Width, b.Height, PixelFormat.Format24bppRgb))
        {
            using (Graphics g = Graphics.FromImage(o)) { g.Clear(Color.Black); g.DrawImage(b, 0, 0, b.Width, b.Height); }
            o.Save(path, ImageFormat.Png);
        }
    }
}
'@
}

# ---------------------------------------------------------------- settings
$script:Cfg = @{ ApiKey = ''; AutoPick = $true; Sd = ''; Publisher = 'RetroArch forwarder'; Transparent = $false; Sound = $null; LastRomDir = ''; LastBatchDir = '' }
if (Test-Path -LiteralPath $script:Settings) {
    try {
        $j = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        if ($j.ApiKey)             { $script:Cfg.ApiKey    = [string]$j.ApiKey }
        if ($null -ne $j.AutoPick) { $script:Cfg.AutoPick  = [bool]$j.AutoPick }
        if ($j.Sd)                 { $script:Cfg.Sd        = [string]$j.Sd }
        if ($j.Publisher)          { $script:Cfg.Publisher = [string]$j.Publisher }
        if ($null -ne $j.Transparent) { $script:Cfg.Transparent = [bool]$j.Transparent }
        if ($null -ne $j.Sound)    { $script:Cfg.Sound     = [string]$j.Sound }
        if ($j.LastRomDir)         { $script:Cfg.LastRomDir   = [string]$j.LastRomDir }
        if ($j.LastBatchDir)       { $script:Cfg.LastBatchDir = [string]$j.LastBatchDir }
    } catch {}
}
# First run: reuse the key already saved by PS1 Forwarder Creator Plus, if it
# sits in a neighbouring folder.
if (-not $script:Cfg.ApiKey) {
    try {
        $plus = Get-ChildItem -LiteralPath (Split-Path -Parent $script:Root) -Filter 'settings_plus.json' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($plus) {
            $pj = Get-Content -LiteralPath $plus.FullName -Raw | ConvertFrom-Json
            if ($pj.ApiKey) { $script:Cfg.ApiKey = [string]$pj.ApiKey }
        }
    } catch {}
}
# First run: the PlayStation jingle that PS1 Forwarder Creator ships, if it
# sits in a neighbouring folder. An empty string means "no sound, keep the
# template's"; $null means never decided.
if ($null -eq $script:Cfg.Sound) {
    $script:Cfg.Sound = ''
    try {
        $w = Get-ChildItem -LiteralPath (Split-Path -Parent $script:Root) -Filter 'ps1.wav' -Recurse -Depth 4 -File -ErrorAction SilentlyContinue |
             Where-Object { $_.DirectoryName -like '*assets_ps1' } | Select-Object -First 1
        if ($w) { $script:Cfg.Sound = $w.FullName }
    } catch {}
}
# Folders are remembered relative to the SD card ("\roms\psx"), so they still
# work when Windows gives the card another drive letter.
function Get-RememberedDir([string]$sd, [string]$rel) {
    if ($rel) {
        $p = $sd + $rel
        while ($p.Length -gt $sd.Length) {
            if (Test-Path -LiteralPath $p -PathType Container) { return $p }
            $p = Split-Path -Parent $p          # the folder was removed: its parent
        }
    }
    return "$sd\"
}
function Set-RememberedDir([string]$sd, [string]$dir, [string]$key) {
    if ($dir.StartsWith($sd, [StringComparison]::OrdinalIgnoreCase)) {
        $script:Cfg[$key] = $dir.Substring($sd.Length).TrimEnd('\')
        Save-Settings
    }
}

function Save-Settings { $script:Cfg | ConvertTo-Json | Set-Content -LiteralPath $script:Settings -Encoding UTF8 }

# ---------------------------------------------------------------- state
$script:Rom = $null       # path on the PC, e.g. E:\roms\psx\Game.chd
$script:SdRom = $null     # same file as the console sees it, sdmc:/roms/psx/Game.chd
$script:GameName = $null
$script:Logo = $null; $script:Bg = $null; $script:IconImg = $null
$script:LogoIsLocal = $false; $script:BgIsLocal = $false; $script:IconIsLocal = $false
$script:Tid = $null

# ---------------------------------------------------------------- helpers
function Q([string]$s) { '"' + $s + '"' }

function Get-CleanName([string]$n) { (($n -replace '\s*[\(\[][^\)\]]*[\)\]]', '') -replace '\s+', ' ').Trim() }

function Load-Image([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($path)
    $ms = New-Object IO.MemoryStream(,$bytes)
    try { return [System.Drawing.Image]::FromStream($ms) } catch { return $null }
}

function Find-Local([string]$folder, [string[]]$names) {
    foreach ($n in $names) {
        if (-not $n) { continue }
        foreach ($ext in @('png', 'jpg', 'jpeg')) {
            $p = Join-Path (Join-Path $script:Root $folder) "$n.$ext"
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    return $null
}

# Runs fwdgen-pc.exe and returns its KEY=VALUE lines as a hashtable.
function Invoke-Cli([string]$arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Cli
    $psi.Arguments = $arguments
    $psi.WorkingDirectory = $script:Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    while (-not $p.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
    $p.WaitForExit()
    $out = $outTask.Result
    Write-Log ("fwdgen-pc {0} -> {1}`n{2}{3}" -f $arguments, $p.ExitCode, $out, $errTask.Result)
    $r = @{ ExitCode = $p.ExitCode }
    foreach ($line in ($out -split "`r?`n")) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $r[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
    if ($errTask.Result) { $r['STDERR'] = $errTask.Result }
    return $r
}

# libretro thumbnail folders for the cores people run on a 3DS.
$script:Systems = [ordered]@{
    'pcsx_rearmed' = 'Sony - PlayStation'
    'snes9x' = 'Nintendo - Super Nintendo Entertainment System'; 'snes9x2002' = 'Nintendo - Super Nintendo Entertainment System'
    'snes9x2005' = 'Nintendo - Super Nintendo Entertainment System'; 'snes9x2005_plus' = 'Nintendo - Super Nintendo Entertainment System'
    'snes9x2010' = 'Nintendo - Super Nintendo Entertainment System'
    'nestopia' = 'Nintendo - Nintendo Entertainment System'; 'fceumm' = 'Nintendo - Nintendo Entertainment System'; 'quicknes' = 'Nintendo - Nintendo Entertainment System'
    'gambatte' = 'Nintendo - Game Boy Color'; 'gearboy' = 'Nintendo - Game Boy Color'; 'tgbdual' = 'Nintendo - Game Boy Color'
    'gpsp' = 'Nintendo - Game Boy Advance'; 'mgba' = 'Nintendo - Game Boy Advance'; 'vba_next' = 'Nintendo - Game Boy Advance'
    'stella2014' = 'Atari - 2600'; 'stella' = 'Atari - 2600'
    'genesis_plus_gx' = 'Sega - Mega Drive - Genesis'; 'picodrive' = 'Sega - Mega Drive - Genesis'
    'mednafen_pce_fast' = 'NEC - PC Engine - TurboGrafx 16'; 'mednafen_ngp' = 'SNK - Neo Geo Pocket Color'; 'mednafen_wswan' = 'Bandai - WonderSwan Color'
}

# What a file extension says about the system, and the cores that run it on a
# 3DS, best first. Used to pick the core of each game and the libretro
# thumbnail folder (the extension beats the core: gambatte runs .gb and .gbc).
$script:ExtSystems = [ordered]@{
    '.gb'  = @{ System = 'Nintendo - Game Boy';            Cores = @('gambatte', 'gearboy', 'tgbdual', 'mgba') }
    '.gbc' = @{ System = 'Nintendo - Game Boy Color';      Cores = @('gambatte', 'gearboy', 'tgbdual', 'mgba') }
    '.gba' = @{ System = 'Nintendo - Game Boy Advance';    Cores = @('gpsp', 'mgba', 'vba_next') }
    '.nes' = @{ System = 'Nintendo - Nintendo Entertainment System'; Cores = @('nestopia', 'fceumm', 'quicknes') }
    '.fds' = @{ System = 'Nintendo - Family Computer Disk System';  Cores = @('nestopia', 'fceumm') }
    '.unf' = @{ System = 'Nintendo - Nintendo Entertainment System'; Cores = @('fceumm', 'nestopia') }
    '.sfc' = @{ System = 'Nintendo - Super Nintendo Entertainment System'; Cores = @('snes9x2005_plus', 'snes9x2005', 'snes9x2002', 'snes9x2010', 'snes9x') }
    '.smc' = @{ System = 'Nintendo - Super Nintendo Entertainment System'; Cores = @('snes9x2005_plus', 'snes9x2005', 'snes9x2002', 'snes9x2010', 'snes9x') }
    '.a26' = @{ System = 'Atari - 2600';                   Cores = @('stella2014', 'stella') }
    '.md'  = @{ System = 'Sega - Mega Drive - Genesis';    Cores = @('picodrive', 'genesis_plus_gx') }
    '.gen' = @{ System = 'Sega - Mega Drive - Genesis';    Cores = @('picodrive', 'genesis_plus_gx') }
    '.smd' = @{ System = 'Sega - Mega Drive - Genesis';    Cores = @('picodrive', 'genesis_plus_gx') }
    '.32x' = @{ System = 'Sega - 32X';                     Cores = @('picodrive') }
    '.sms' = @{ System = 'Sega - Master System - Mark III'; Cores = @('picodrive', 'genesis_plus_gx', 'smsplus', 'gearsystem') }
    '.gg'  = @{ System = 'Sega - Game Gear';               Cores = @('genesis_plus_gx', 'gearsystem', 'smsplus', 'picodrive') }
    '.pce' = @{ System = 'NEC - PC Engine - TurboGrafx 16'; Cores = @('mednafen_pce_fast', 'geargrafx') }
    '.ngp' = @{ System = 'SNK - Neo Geo Pocket';           Cores = @('mednafen_ngp', 'race') }
    '.ngc' = @{ System = 'SNK - Neo Geo Pocket Color';     Cores = @('mednafen_ngp', 'race') }
    '.ws'  = @{ System = 'Bandai - WonderSwan';            Cores = @('mednafen_wswan') }
    '.wsc' = @{ System = 'Bandai - WonderSwan Color';      Cores = @('mednafen_wswan') }
    '.col' = @{ System = 'Coleco - ColecoVision';          Cores = @('gearcoleco', 'bluemsx') }
    '.lnx' = @{ System = 'Atari - Lynx';                   Cores = @('handy') }
    '.vb'  = @{ System = 'Nintendo - Virtual Boy';         Cores = @('mednafen_vb') }
}
$script:PsxCores = @('pcsx_rearmed')
$script:DiscExt  = @('.chd', '.cue', '.pbp', '.iso', '.ccd', '.toc', '.cbn', '.img', '.mdf')

function Get-CoreStem([string]$corePath) { [IO.Path]::GetFileName($corePath) -replace '_libretro\.3dsx$', '' }

function Get-System([string]$corePath) {
    $stem = Get-CoreStem $corePath
    if ($script:Systems.Contains($stem)) { return $script:Systems[$stem] }
    return $null
}

# The extension that matters: a .zip holding a single ROM counts as that ROM.
function Get-RomKind([string]$file) {
    $ext = [IO.Path]::GetExtension($file).ToLower()
    if ($ext -ne '.zip') { return $ext }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $z = [IO.Compression.ZipFile]::OpenRead($file)
        try {
            foreach ($en in $z.Entries) {
                $inner = [IO.Path]::GetExtension($en.FullName).ToLower()
                if ($script:ExtSystems.Contains($inner)) { return $inner }
            }
        } finally { $z.Dispose() }
    } catch {}
    return $ext
}

# The installed core for a game, from its extension: the first of the
# preferred cores that is on the card. Disc images go to PCSX ReARMed. $null
# when nothing fits; the caller keeps the core chosen by hand.
function Find-Core([string]$file) {
    $kind = Get-RomKind $file
    $prefer = $null
    if ($script:ExtSystems.Contains($kind)) { $prefer = $script:ExtSystems[$kind].Cores }
    elseif ($script:DiscExt -contains $kind -or $kind -eq '.m3u') { $prefer = $script:PsxCores }
    if (-not $prefer) { return $null }
    foreach ($stem in $prefer) {
        foreach ($c in $cmbCore.Items) { if ((Get-CoreStem $c) -eq $stem) { return [string]$c } }
    }
    return $null
}

# The libretro thumbnail folder: from the extension when it says, else the core.
function Get-ThumbSystem([string]$romPath, [string]$corePath) {
    $kind = Get-RomKind $romPath
    if ($script:ExtSystems.Contains($kind)) { return $script:ExtSystems[$kind].System }
    return (Get-System $corePath)
}

# Downloads Named_Titles / Named_Boxarts from libretro (plain HTTP, like the console app).
function Get-LibretroArt([string]$kind, [string]$gameName = $script:GameName, [string]$romPath = $script:Rom, [string]$corePath = $cmbCore.Text) {
    $system = Get-ThumbSystem $romPath $corePath
    if (-not $system -or -not $gameName) { return $null }
    $names = @($gameName)
    if ([IO.Path]::GetExtension($romPath) -ieq '.m3u') { $names += "$gameName (Disc 1)" }
    foreach ($n in $names) {
        $file = ($n -replace '[&*/:`"<>?\\|]', '_') + '.png'
        $dest = Join-Path $script:CacheDir ("libretro_{0}_{1}_{2}" -f ($system -replace '[^A-Za-z0-9]', ''), $kind, $file)
        if (Test-Path -LiteralPath $dest) { return $dest }
        $url = "$($script:Thumbs)/$([Uri]::EscapeDataString($system))/$kind/$([Uri]::EscapeDataString($file))"
        try {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 20
            if ((Get-Item -LiteralPath $dest).Length -gt 100) { return $dest }
            Remove-Item -LiteralPath $dest -ErrorAction SilentlyContinue
        } catch { Remove-Item -LiteralPath $dest -ErrorAction SilentlyContinue }
    }
    return $null
}

# ---------------------------------------------------------------- SteamGridDB
function Invoke-Sgdb([string]$path) {
    $key = $txtKey.Text.Trim()
    if (-not $key) { throw 'Falta la API key de SteamGridDB.' }
    $r = Invoke-RestMethod -Uri ($script:ApiBase + $path) -Headers @{ Authorization = "Bearer $key" } -Method Get -TimeoutSec 30
    if (-not $r.success) { throw "SteamGridDB respondio con error en $path" }
    return @($r.data | Where-Object { $_ })
}

function Save-Remote([string]$url, [string]$kind, $id) {
    $ext = [IO.Path]::GetExtension(([Uri]$url).AbsolutePath)
    if (-not $ext) { $ext = '.png' }
    $dest = Join-Path $script:CacheDir ("{0}_{1}{2}" -f $kind, $id, $ext)
    if (-not (Test-Path -LiteralPath $dest)) { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 60 }
    return $dest
}

# ---------------------------------------------------------------- GUI
$form = New-Object System.Windows.Forms.Form
$form.Text = $script:AppName
$form.ClientSize = New-Object System.Drawing.Size(900, 640)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

function Add-Ctl($ctl, [int]$x, [int]$y, [int]$w, [int]$h) {
    $ctl.Location = New-Object System.Drawing.Point($x, $y)
    $ctl.Size = New-Object System.Drawing.Size($w, $h)
    $form.Controls.Add($ctl)
    return $ctl
}
function New-Label([string]$text, [int]$x, [int]$y, [int]$w = 110) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.TextAlign = 'MiddleLeft'
    return (Add-Ctl $l $x $y $w 23)
}
function New-Button([string]$text, [int]$x, [int]$y, [int]$w, [int]$h = 27) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    return (Add-Ctl $b $x $y $w $h)
}
function New-TextBox([int]$x, [int]$y, [int]$w, [string]$text = '') {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $text
    return (Add-Ctl $t $x $y $w 23)
}

# --- left column: previews
$picBanner = Add-Ctl (New-Object System.Windows.Forms.PictureBox) 12 12 258 130
$picBanner.BorderStyle = 'FixedSingle'
$picIcon = Add-Ctl (New-Object System.Windows.Forms.PictureBox) 282 12 98 98
$picIcon.BorderStyle = 'FixedSingle'; $picIcon.SizeMode = 'StretchImage'
$btnIconLocal = New-Button 'Icono...' 282 113 58 26
$btnIconClear = New-Button 'Quitar' 342 113 56 26

$btnLogoLocal = New-Button 'Logo local...' 12 150 120
$btnLogoClear = New-Button 'Quitar logo' 136 150 90
$btnBgLocal   = New-Button 'Fondo local...' 12 182 120
$btnBgClear   = New-Button 'Quitar fondo' 136 182 90
$lblArt = New-Label '' 232 147 165
$lblArt.Height = 44; $lblArt.Font = New-Object System.Drawing.Font('Segoe UI', 7); $lblArt.TextAlign = 'TopLeft'; $lblArt.ForeColor = [System.Drawing.Color]::DimGray

$chkTrans = Add-Ctl (New-Object System.Windows.Forms.CheckBox) 232 192 170 23
$chkTrans.Text = 'Banner transparente'
$chkTrans.Checked = $script:Cfg.Transparent
$tipTrans = New-Object System.Windows.Forms.ToolTip
$tipTrans.SetToolTip($chkTrans, 'Solo el logo en el banner, sin fondo: se ve el fondo del menu HOME. El icono siempre lleva fondo (la 3DS no admite iconos transparentes).')

# --- left column: SD, game, core
[void](New-Label 'SD:' 12 222 40)
$cmbSd = Add-Ctl (New-Object System.Windows.Forms.ComboBox) 55 222 80 23
$cmbSd.DropDownStyle = 'DropDownList'
$btnSdRefresh = New-Button 'Actualizar' 140 221 75 25
$lblSd = New-Label '' 220 222 178
$lblSd.AutoEllipsis = $true

$btnRom = New-Button 'Elegir juego...' 12 254 120
$btnBatch = New-Button 'Varios juegos...' 136 254 120
$tipBatch = New-Object System.Windows.Forms.ToolTip
$tipBatch.SetToolTip($btnBatch, 'Crea los CIAs de todos los juegos de una carpeta de la SD, detectando los .m3u.')
$lblRom = New-Label 'Ningun juego seleccionado' 262 256 136
$lblRom.AutoEllipsis = $true

[void](New-Label 'Core:' 12 288 90)
$cmbCore = Add-Ctl (New-Object System.Windows.Forms.ComboBox) 105 288 290 23
$cmbCore.DropDownStyle = 'DropDownList'

[void](New-Label 'Nombre:' 12 320 90)
$txtName = New-TextBox 105 320 290 ''
$txtName.MaxLength = 64
[void](New-Label 'Publisher:' 12 350 90)
$txtPub = New-TextBox 105 350 290 $script:Cfg.Publisher
$txtPub.MaxLength = 64

[void](New-Label 'Title ID:' 12 382 90)
$lblTid = New-Label '-' 105 382 290
$lblTid.Font = New-Object System.Drawing.Font('Consolas', 9)
$lblTidInfo = New-Label '' 12 404 383
$lblTidInfo.Height = 36; $lblTidInfo.TextAlign = 'TopLeft'

[void](New-Label 'Sonido:' 12 446 55)
$lblSound = New-Label '' 68 446 175
$lblSound.AutoEllipsis = $true
$btnSound = New-Button 'Elegir...' 246 444 60 26
$btnSoundPlay = New-Button 'Probar' 308 444 46 26
$btnSoundClear = New-Button 'Quitar' 356 444 42 26
$tipSound = New-Object System.Windows.Forms.ToolTip
$tipSound.SetToolTip($btnSound, 'Sonido al seleccionar el icono en el menu HOME (WAV PCM, mono o estereo, maximo 3 segundos).')

$btnBuild = New-Button 'Crear CIA' 12 476 383 70
$btnBuild.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$progress = Add-Ctl (New-Object System.Windows.Forms.ProgressBar) 12 560 383 18
$progress.Maximum = 4
$lblStatus = New-Label 'Listo.' 12 580 383
$lblStatus.Height = 46; $lblStatus.TextAlign = 'TopLeft'

# --- right column: SteamGridDB
$grp = Add-Ctl (New-Object System.Windows.Forms.GroupBox) 410 6 478 626
$grp.Text = 'SteamGridDB'
function Add-G($ctl, [int]$x, [int]$y, [int]$w, [int]$h) {
    $ctl.Location = New-Object System.Drawing.Point($x, $y)
    $ctl.Size = New-Object System.Drawing.Size($w, $h)
    $grp.Controls.Add($ctl)
    return $ctl
}
$l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'API key:'; $l1.TextAlign = 'MiddleLeft'
[void](Add-G $l1 10 22 60 23)
$txtKey = Add-G (New-Object System.Windows.Forms.TextBox) 72 22 300 23
$txtKey.UseSystemPasswordChar = $true
$txtKey.Text = $script:Cfg.ApiKey
$btnKey = Add-G (New-Object System.Windows.Forms.Button) 378 21 90 25
$btnKey.Text = 'Guardar'
$lnk = Add-G (New-Object System.Windows.Forms.LinkLabel) 10 48 458 20
$lnk.Text = 'Consigue tu API key en steamgriddb.com/profile/preferences/api'
$lnk.Add_LinkClicked({ Start-Process 'https://www.steamgriddb.com/profile/preferences/api' })

$txtSearch = Add-G (New-Object System.Windows.Forms.TextBox) 10 74 362 23
$btnSearch = Add-G (New-Object System.Windows.Forms.Button) 378 73 90 25
$btnSearch.Text = 'Buscar'
$cmbGames = Add-G (New-Object System.Windows.Forms.ComboBox) 10 104 458 23
$cmbGames.DropDownStyle = 'DropDownList'
$chkAuto = Add-G (New-Object System.Windows.Forms.CheckBox) 10 132 458 22
$chkAuto.Text = 'Elegir automaticamente el primer logo, fondo e icono al elegir juego'
$chkAuto.Checked = $script:Cfg.AutoPick

$tabs = Add-G (New-Object System.Windows.Forms.TabControl) 10 160 458 456
function New-Tab([string]$title) {
    $tp = New-Object System.Windows.Forms.TabPage
    $tp.Text = $title
    $fl = New-Object System.Windows.Forms.FlowLayoutPanel
    $fl.Dock = 'Fill'; $fl.AutoScroll = $true
    $tp.Controls.Add($fl)
    $tabs.TabPages.Add($tp)
    return $fl
}
$flLogos  = New-Tab 'Logos'
$flHeroes = New-Tab 'Fondos (Heroes)'
$flGrids  = New-Tab 'Portadas (Grids)'
$flIcons  = New-Tab 'Iconos'

# ---------------------------------------------------------------- GUI logic
function Update-Sound {
    $p = $script:Cfg.Sound
    if ($p -and (Test-Path -LiteralPath $p)) {
        $lblSound.Text = [IO.Path]::GetFileName($p); $lblSound.ForeColor = [System.Drawing.SystemColors]::ControlText
        $btnSoundPlay.Enabled = $true; $btnSoundClear.Enabled = $true
    } else {
        $lblSound.Text = '(el de la plantilla)'; $lblSound.ForeColor = [System.Drawing.Color]::DimGray
        $btnSoundPlay.Enabled = $false; $btnSoundClear.Enabled = $false
    }
}

function Set-Status([string]$t, [int]$step = -1) {
    $lblStatus.Text = $t
    if ($step -ge 0) { $progress.Value = [Math]::Min($step, $progress.Maximum) }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-SdRoot { if ($cmbSd.SelectedItem) { return [string]$cmbSd.SelectedItem }; return $null }   # "E:"

function Refresh-Sd {
    $prev = Get-SdRoot
    if (-not $prev) { $prev = $script:Cfg.Sd }
    $cmbSd.Items.Clear()
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($d.IsReady -and (Test-Path -LiteralPath (Join-Path $d.RootDirectory.FullName 'Nintendo 3DS'))) {
                [void]$cmbSd.Items.Add($d.Name.TrimEnd('\'))
            }
        } catch {}
    }
    if ($cmbSd.Items.Count -eq 0) {
        $lblSd.Text = 'No encuentro una SD de 3DS'; $lblSd.ForeColor = [System.Drawing.Color]::DarkRed
        $cmbCore.Items.Clear()
        return
    }
    $i = $cmbSd.Items.IndexOf($prev)
    $cmbSd.SelectedIndex = $(if ($i -ge 0) { $i } else { 0 })
}

function Refresh-Cores {
    $sd = Get-SdRoot
    $cmbCore.Items.Clear()
    if (-not $sd) { return }
    foreach ($dir in @('retroarch\cores', '3ds')) {
        $p = Join-Path "$sd\" $dir
        if (-not (Test-Path -LiteralPath $p)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $p -Filter '*_libretro.3dsx' -File -ErrorAction SilentlyContinue) {
            [void]$cmbCore.Items.Add('sdmc:/' + ($dir -replace '\\', '/') + '/' + $f.Name)
        }
    }
    if ($cmbCore.Items.Count -eq 0) {
        $lblSd.Text = 'Falta el core .3dsx en la SD'; $lblSd.ForeColor = [System.Drawing.Color]::DarkOrange
        return
    }
    $pcsx = @($cmbCore.Items | Where-Object { $_ -like '*pcsx_rearmed_libretro.3dsx' })
    $cmbCore.SelectedItem = $(if ($pcsx) { $pcsx[0] } else { $cmbCore.Items[0] })
    $lblSd.Text = "$($cmbCore.Items.Count) core(s) .3dsx"; $lblSd.ForeColor = [System.Drawing.Color]::Green
}

function Update-Tid {
    $script:Tid = $null
    $lblTid.Text = '-'; $lblTidInfo.Text = ''
    $sd = Get-SdRoot
    if (-not $sd -or -not $script:SdRom) { return }
    $r = Invoke-Cli ("tid --sd {0} --rom {1}" -f (Q $sd), (Q $script:SdRom))
    if ($r.ERROR) { $lblTidInfo.Text = "Error: $($r.ERROR)"; $lblTidInfo.ForeColor = [System.Drawing.Color]::DarkRed; return }
    $script:Tid = $r.TID
    $lblTid.Text = $r.TID
    switch ($r.STATUS) {
        'update' { $lblTidInfo.Text = 'Este juego ya tiene forwarder: el CIA lo actualiza.'; $lblTidInfo.ForeColor = [System.Drawing.Color]::RoyalBlue }
        'moved'  { $lblTidInfo.Text = "El ID $($r.PREFERRED) ya lo usa otro titulo instalado, se usa uno libre."; $lblTidInfo.ForeColor = [System.Drawing.Color]::DarkOrange }
        default  { $lblTidInfo.Text = "ID libre. $($r.INSTALLED) titulos revisados en la SD."; $lblTidInfo.ForeColor = [System.Drawing.Color]::Green }
    }
}

function New-ArtFor([string]$bgPath, [string]$logoPath, [string]$iconPath, [bool]$transparent, [string]$outBanner, [string]$outIcon) {
    Remove-Item -LiteralPath $outBanner, $outIcon -ErrorAction SilentlyContinue
    $bg = Load-Image $bgPath; $logo = Load-Image $logoPath; $icon = Load-Image $iconPath
    try {
        if ($logo -and $transparent) {
            $b = [FwdArt]::LogoOnly($logo, 256, 128, 248, 120)
            [FwdArt]::SaveAlpha($b, $outBanner); $b.Dispose()
        } elseif ($bg -or $logo) {
            $b = [FwdArt]::Compose($bg, $logo, 256, 128, 232, 100, 3)
            [FwdArt]::SaveOpaque($b, $outBanner); $b.Dispose()
        }
        if ($icon) {
            $i = [FwdArt]::ComposeIcon($bg, $icon)
            [FwdArt]::SaveOpaque($i, $outIcon); $i.Dispose()
        } elseif ($bg -or $logo) {
            $i = [FwdArt]::Compose($bg, $logo, 48, 48, 44, 44, 1)
            [FwdArt]::SaveOpaque($i, $outIcon); $i.Dispose()
        }
    } finally {
        foreach ($x in @($bg, $logo, $icon)) { if ($x) { $x.Dispose() } }
    }
}

# Builds the banner and the icon exactly as they will be written.
function New-Art([string]$outBanner, [string]$outIcon) {
    New-ArtFor $script:Bg $script:Logo $script:IconImg $chkTrans.Checked $outBanner $outIcon
}

function Use-Transparent { return [bool]($chkTrans.Checked -and $script:Logo) }

function Update-Preview {
    # light gray behind the preview, like the default HOME menu theme
    $picBanner.BackColor = $(if (Use-Transparent) { [System.Drawing.Color]::FromArgb(225, 225, 225) } else { [System.Drawing.SystemColors]::Control })
    $b = Join-Path $env:TEMP 'rafpc_banner.png'
    $i = Join-Path $env:TEMP 'rafpc_icon.png'
    New-Art $b $i
    $old = $picBanner.Image; $picBanner.Image = Load-Image $b; if ($old) { $old.Dispose() }
    $old = $picIcon.Image;   $picIcon.Image   = Load-Image $i; if ($old) { $old.Dispose() }
    $t = @()
    $t += 'Logo: '  + $(if ($script:Logo)    { [IO.Path]::GetFileName($script:Logo) }    else { '(ninguno)' })
    $t += 'Fondo: ' + $(if ($script:Bg)      { [IO.Path]::GetFileName($script:Bg) }      else { '(ninguno)' })
    $t += 'Icono: ' + $(if ($script:IconImg) { [IO.Path]::GetFileName($script:IconImg) } else { '(del logo)' })
    if (-not $picBanner.Image) { $t += 'Sin imagenes: se usa la de la plantilla.' }
    $lblArt.Text = $t -join "`n"
}

function Clear-Thumbs {
    foreach ($fl in @($flLogos, $flHeroes, $flGrids, $flIcons)) {
        foreach ($c in @($fl.Controls)) { try { $c.CancelAsync() } catch {}; if ($c.Image) { $c.Image.Dispose() }; $c.Dispose() }
        $fl.Controls.Clear()
    }
}

function Add-Thumb($fl, $item, [string]$kind, [int]$w, [int]$h) {
    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.Size = New-Object System.Drawing.Size($w, $h)
    $pb.SizeMode = 'Zoom'
    $pb.Margin = New-Object System.Windows.Forms.Padding(4)
    $pb.Cursor = [System.Windows.Forms.Cursors]::Hand
    $pb.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $pb.Tag = @{ Url = [string]$item.url; Id = $item.id; Kind = $kind }
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($pb, ("{0}x{1}  {2}" -f $item.width, $item.height, $item.style))
    $pb.Add_Click({ param($s, $e) Select-Remote $s.Tag })
    $fl.Controls.Add($pb)
    try { $pb.LoadAsync([string]$item.thumb) } catch {}
}

function Select-Remote($tag) {
    try {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Set-Status 'Descargando imagen...'
        $path = Save-Remote $tag.Url $tag.Kind $tag.Id
        switch ($tag.Kind) {
            'logo'  { $script:Logo = $path; $script:LogoIsLocal = $true }
            'icon'  { $script:IconImg = $path; $script:IconIsLocal = $true }
            default { $script:Bg = $path; $script:BgIsLocal = $true }
        }
        Update-Preview
        Set-Status 'Listo.'
    } catch { Show-Error "No se pudo descargar la imagen:`n$($_.Exception.Message)" }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Search-Games([string]$term) {
    $cmbGames.Items.Clear()
    $script:GameList = @()
    Clear-Thumbs
    if (-not $term) { return }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Set-Status "Buscando '$term' en SteamGridDB..."
        $res = Invoke-Sgdb ('/search/autocomplete/' + [Uri]::EscapeDataString($term))
        foreach ($g in $res) {
            $year = ''
            if ($g.release_date) { $year = ' (' + ([DateTimeOffset]::FromUnixTimeSeconds([int64]$g.release_date).Year) + ')' }
            $script:GameList += ,([pscustomobject]@{ Id = $g.id; Name = $g.name })
            [void]$cmbGames.Items.Add("$($g.name)$year")
        }
        if ($cmbGames.Items.Count -gt 0) { $cmbGames.SelectedIndex = 0 }
        else { Set-Status 'SteamGridDB no encontro ese juego. Prueba con otro nombre.' }
    } catch { Show-Error "Error al buscar en SteamGridDB:`n$($_.Exception.Message)"; Set-Status 'Error de busqueda.' }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Load-Assets($game, [bool]$autoPick) {
    Clear-Thumbs
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Set-Status "Cargando imagenes de $($game.Name)..."
        $logos  = @(Invoke-Sgdb "/logos/game/$($game.Id)?mimes=image/png&nsfw=false&humor=false")
        $heroes = @(Invoke-Sgdb "/heroes/game/$($game.Id)?mimes=image/png,image/jpeg&nsfw=false&humor=false")
        $grids  = @(Invoke-Sgdb "/grids/game/$($game.Id)?mimes=image/png,image/jpeg&nsfw=false&humor=false")
        $icons  = @(Invoke-Sgdb "/icons/game/$($game.Id)?mimes=image/png&nsfw=false&humor=false")
        foreach ($x in ($logos  | Select-Object -First 40)) { Add-Thumb $flLogos  $x 'logo' 200 80 }
        foreach ($x in ($heroes | Select-Object -First 40)) { Add-Thumb $flHeroes $x 'hero' 200 65 }
        foreach ($x in ($grids  | Select-Object -First 40)) { Add-Thumb $flGrids  $x 'grid' 96 140 }
        foreach ($x in ($icons  | Select-Object -First 40)) { Add-Thumb $flIcons  $x 'icon' 80 80 }
        Set-Status ("{0} logos, {1} fondos, {2} portadas, {3} iconos." -f @($logos).Count, @($heroes).Count, @($grids).Count, @($icons).Count)
        if ($autoPick) {
            if (-not $script:LogoIsLocal -and @($logos).Count -gt 0) { $script:Logo = Save-Remote ([string]$logos[0].url) 'logo' $logos[0].id }
            if (-not $script:BgIsLocal -and @($heroes).Count -gt 0)  { $script:Bg = Save-Remote ([string]$heroes[0].url) 'hero' $heroes[0].id }
            if (-not $script:IconIsLocal -and @($icons).Count -gt 0) { $script:IconImg = Save-Remote ([string]$icons[0].url) 'icon' $icons[0].id }
            Update-Preview
        }
    } catch { Show-Error "Error al cargar imagenes de SteamGridDB:`n$($_.Exception.Message)"; Set-Status 'Error de SteamGridDB.' }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

$script:AutoPickNext = $false
$cmbGames.Add_SelectedIndexChanged({
    $idx = $cmbGames.SelectedIndex
    if ($idx -ge 0 -and $idx -lt @($script:GameList).Count) {
        $auto = $script:AutoPickNext
        $script:AutoPickNext = $false
        Load-Assets $script:GameList[$idx] $auto
    }
})

$btnKey.Add_Click({ $script:Cfg.ApiKey = $txtKey.Text.Trim(); Save-Settings; Set-Status 'API key guardada.' })
$btnSearch.Add_Click({ Search-Games $txtSearch.Text.Trim() })
$txtSearch.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Search-Games $txtSearch.Text.Trim() } })
$chkAuto.Add_CheckedChanged({ $script:Cfg.AutoPick = $chkAuto.Checked; Save-Settings })
$chkTrans.Add_CheckedChanged({ $script:Cfg.Transparent = $chkTrans.Checked; Save-Settings; Update-Preview })
$txtPub.Add_Leave({ $script:Cfg.Publisher = $txtPub.Text; Save-Settings })
$btnSdRefresh.Add_Click({ Refresh-Sd })
$btnSound.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Sonido WAV (*.wav)|*.wav'
    if ($script:Cfg.Sound) { $d.InitialDirectory = [IO.Path]::GetDirectoryName($script:Cfg.Sound) }
    if ($d.ShowDialog() -eq 'OK') { $script:Cfg.Sound = $d.FileName; Save-Settings; Update-Sound }
})
$btnSoundClear.Add_Click({ $script:Cfg.Sound = ''; Save-Settings; Update-Sound })
$btnSoundPlay.Add_Click({
    try { $sp = New-Object System.Media.SoundPlayer($script:Cfg.Sound); $sp.Play() }
    catch { Show-Error "No se pudo reproducir:`n$($_.Exception.Message)" }
})
$cmbSd.Add_SelectedIndexChanged({
    $script:Cfg.Sd = Get-SdRoot; Save-Settings
    Refresh-Cores
    if ($script:Rom -and -not $script:Rom.StartsWith((Get-SdRoot) + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $script:Rom = $null; $script:SdRom = $null; $lblRom.Text = 'Ningun juego seleccionado'
    }
    Update-Tid
})

$imgFilter = 'Imagenes (*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.png;*.jpg;*.jpeg;*.bmp;*.gif'
$btnLogoLocal.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = $imgFilter; $d.InitialDirectory = Join-Path $script:Root 'logos'
    if ($d.ShowDialog() -eq 'OK') { $script:Logo = $d.FileName; $script:LogoIsLocal = $true; Update-Preview }
})
$btnBgLocal.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = $imgFilter; $d.InitialDirectory = Join-Path $script:Root 'covers'
    if ($d.ShowDialog() -eq 'OK') { $script:Bg = $d.FileName; $script:BgIsLocal = $true; Update-Preview }
})
$btnIconLocal.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = $imgFilter; $d.InitialDirectory = Join-Path $script:Root 'icons'
    if ($d.ShowDialog() -eq 'OK') { $script:IconImg = $d.FileName; $script:IconIsLocal = $true; Update-Preview }
})
$btnLogoClear.Add_Click({ $script:Logo = $null; $script:LogoIsLocal = $false; Update-Preview })
$btnBgClear.Add_Click({ $script:Bg = $null; $script:BgIsLocal = $false; Update-Preview })
$btnIconClear.Add_Click({ $script:IconImg = $null; $script:IconIsLocal = $false; Update-Preview })

$romPatterns = (@('.chd', '.m3u', '.cue', '.pbp', '.iso', '.ccd', '.toc', '.bin', '.zip', '.7z') + @($script:ExtSystems.Keys) | ForEach-Object { "*$_" }) -join ';'
$romFilter = "Juegos|$romPatterns|Todos los archivos|*.*"
# Loads a game of the SD card into the main window.
function Load-Game([string]$file) {
    $sd = Get-SdRoot
    if (-not $sd) { Show-Error 'Primero conecta la SD de tu 3DS y dale a Actualizar.'; return }
    if (-not $file.StartsWith("$sd\", [StringComparison]::OrdinalIgnoreCase)) {
        Show-Error "El juego tiene que estar en la SD ($sd), porque el forwarder lo abre desde ahi."
        return
    }
    $sdRom = 'sdmc:' + $file.Substring($sd.Length).Replace('\', '/')
    if ([Text.Encoding]::UTF8.GetByteCount($sdRom) -gt 255) { Show-Error 'La ruta del juego es demasiado larga (maximo 255 caracteres).'; return }
    $script:SdRom = $sdRom
    $script:Rom = $file
    $script:GameName = [IO.Path]::GetFileNameWithoutExtension($file)
    $clean = Get-CleanName $script:GameName
    $lblRom.Text = [IO.Path]::GetFileName($file)
    $txtName.Text = $clean
    $core = Find-Core $file
    if ($core) { $cmbCore.SelectedItem = $core }

    # local art first (logos\, covers\, icons\), then libretro, then SteamGridDB
    $names = @($script:GameName, $clean)
    $script:Logo = Find-Local 'logos' $names
    $script:Bg = Find-Local 'covers' $names
    $script:IconImg = Find-Local 'icons' $names
    $script:LogoIsLocal = [bool]$script:Logo
    $script:BgIsLocal   = [bool]$script:Bg
    $script:IconIsLocal = [bool]$script:IconImg
    if (-not $script:Bg) {
        Set-Status 'Buscando pantalla de titulo en libretro...'
        $script:Bg = Get-LibretroArt 'Named_Titles'
    }
    Update-Preview
    Update-Tid
    Set-Status 'Listo.'

    $txtSearch.Text = $clean
    if ($txtKey.Text.Trim()) {
        $script:AutoPickNext = $chkAuto.Checked
        Search-Games $clean
        $script:AutoPickNext = $false
    }
}

$btnRom.Add_Click({
    $sd = Get-SdRoot
    if (-not $sd) { Show-Error 'Primero conecta la SD de tu 3DS y dale a Actualizar.'; return }
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = $romFilter
    $d.InitialDirectory = Get-RememberedDir $sd $script:Cfg.LastRomDir
    $d.RestoreDirectory = $true
    if ($d.ShowDialog() -ne 'OK') { return }
    Set-RememberedDir $sd ([IO.Path]::GetDirectoryName($d.FileName)) 'LastRomDir'
    Load-Game $d.FileName
})

# ---------------------------------------------------------------- build
# Builds one CIA: picks the title id, renders the art, runs fwdgen-pc.
# Returns @{ Tid; Version; Status } or throws.
function Invoke-Build([string]$sdRom, [string]$name, [string]$bg, [string]$logo, [string]$icon, [bool]$transparent, [string]$out, [string]$core = [string]$cmbCore.SelectedItem) {
    $sd = Get-SdRoot
    $t = Invoke-Cli ("tid --sd {0} --rom {1}" -f (Q $sd), (Q $sdRom))
    if ($t.ERROR -or -not $t.TID) { throw "Title ID: $(if ($t.ERROR) { $t.ERROR } else { 'sin respuesta' })" }

    $b = Join-Path $env:TEMP 'rafpc_build_banner.png'
    $i = Join-Path $env:TEMP 'rafpc_build_icon.png'
    New-ArtFor $bg $logo $icon $transparent $b $i

    $name = ($name -replace '"', '').Trim()
    $cliArgs = "build --sd {0} --template {1} --rom {2} --core {3} --name {4} --publisher {5} --tid {6} --out {7}" -f `
        (Q $sd), (Q $script:Template), (Q $sdRom), (Q $core), (Q $name), (Q (($txtPub.Text -replace '"', '').Trim())), $t.TID, (Q $out)
    if (Test-Path -LiteralPath $i) { $cliArgs += " --icon $(Q $i)" }
    if (Test-Path -LiteralPath $b) { $cliArgs += " --banner $(Q $b)" }
    if ((Test-Path -LiteralPath $b) -and $transparent -and $logo) { $cliArgs += ' --transparent' }
    if ($script:Cfg.Sound -and (Test-Path -LiteralPath $script:Cfg.Sound)) { $cliArgs += " --sound $(Q $script:Cfg.Sound)" }
    $r = Invoke-Cli $cliArgs
    if ($r.ExitCode -ne 0 -or -not $r.OK) {
        $why = $(if ($r.ERROR) { $r.ERROR } elseif ($r.STDERR) { $r.STDERR } else { "codigo $($r.ExitCode)" })
        throw "fwdgen-pc: $why"
    }
    return @{ Tid = $t.TID; Version = $r.VERSION; Status = $t.STATUS }
}

$btnBuild.Add_Click({
    $sd = Get-SdRoot
    if (-not $script:SdRom) { [void][System.Windows.Forms.MessageBox]::Show('Primero elige un juego de la SD.'); return }
    if (-not $cmbCore.SelectedItem) { Show-Error "No hay ningun core .3dsx en la SD.`nCopia pcsx_rearmed_libretro.3dsx (de RetroArch_3dsx.7z) a $sd\retroarch\cores\"; return }
    if (-not $script:Tid) { Update-Tid; if (-not $script:Tid) { Show-Error 'No se pudo elegir un Title ID. Revisa que la SD sea la de tu 3DS.'; return } }
    $name = ($txtName.Text -replace '"', '').Trim()
    if (-not $name) { Show-Error 'Escribe un nombre para el juego.'; return }

    $ciaDir = "$sd\cias"
    if (-not (Test-Path -LiteralPath $ciaDir)) { [void](New-Item -ItemType Directory -Path $ciaDir) }
    $d = New-Object System.Windows.Forms.SaveFileDialog
    $d.Filter = 'Archivos CIA (*.cia)|*.cia'
    $d.FileName = ($name -replace '[\\/:*?"<>|]', '') + '.cia'
    $d.InitialDirectory = $ciaDir
    if ($d.ShowDialog() -ne 'OK') { return }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $btnBuild.Enabled = $false
    try {
        Set-Status 'Revisando el Title ID...' 1
        Update-Tid
        if (-not $script:Tid) { throw 'No se pudo elegir un Title ID.' }

        Set-Status 'Creando banner, icono y CIA...' 2
        $r = Invoke-Build $script:SdRom $name $script:Bg $script:Logo $script:IconImg ([bool]$chkTrans.Checked) $d.FileName
        Update-Tid
        Set-Status ("CIA creado: {0}  (Title ID {1}, version {2})" -f [IO.Path]::GetFileName($d.FileName), $r.Tid, $r.Version) 4
        [void][System.Windows.Forms.MessageBox]::Show("CIA creado:`n$($d.FileName)`n`nInstalalo en la 3DS con FBI (SD > cias).", 'Listo')
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
        Set-Status 'Error.' 0
        Show-Error "No se pudo crear el CIA:`n$($_.Exception.Message)"
    } finally {
        $btnBuild.Enabled = $true
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})


# ---------------------------------------------------------------- batch
$script:RomExt  = $script:DiscExt + @('.m3u', '.bin', '.zip', '.7z') + @($script:ExtSystems.Keys)
# When one game is there in several formats, the first wins.
$script:ExtRank = @('.m3u', '.chd', '.pbp', '.cue', '.iso', '.ccd', '.toc', '.cbn', '.img', '.mdf')

function Get-NormTitle([string]$s) { ($s.ToLowerInvariant() -replace '[^a-z0-9]', '') }

function Get-FullPathSafe([string]$dir, [string]$rel) {
    try { return [IO.Path]::GetFullPath((Join-Path $dir $rel)) } catch { return $null }
}

# Lists the games of a folder. A .m3u hides the discs it lists, a .cue the
# tracks it lists. Discs named "(Disc 1)", "(Disc 2)"... without a .m3u are
# grouped into a planned one, written only when the CIAs are built.
function Find-Games([string]$dir, [bool]$recurse) {
    $files = @(Get-ChildItem -LiteralPath $dir -File -Recurse:$recurse -ErrorAction SilentlyContinue |
               Where-Object { $script:RomExt -contains $_.Extension.ToLower() })
    $covered = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($f in $files) {
        $ext = $f.Extension.ToLower()
        if ($ext -ne '.m3u' -and $ext -ne '.cue') { continue }
        try { $lines = [IO.File]::ReadAllLines($f.FullName) } catch { continue }
        foreach ($line in $lines) {
            $ref = $null
            if ($ext -eq '.m3u') {
                $l = $line.Trim()
                if ($l -and -not $l.StartsWith('#')) { $ref = $l }
            } elseif ($line -match '^\s*FILE\s+"([^"]+)"' -or $line -match '^\s*FILE\s+(\S+)') {
                $ref = $Matches[1]
            }
            if ($ref) { $full = Get-FullPathSafe $f.DirectoryName $ref; if ($full) { [void]$covered.Add($full) } }
        }
    }

    $games = New-Object System.Collections.ArrayList
    $rx = '^(?<pre>.*?)\s*\((?:Disc|Disco|CD)\s*(?<n>\d+)(?:\s*of\s*\d+)?\)(?<post>.*)$'
    $groups = @{}
    foreach ($f in $files) {
        if ($script:DiscExt -notcontains $f.Extension.ToLower() -or $covered.Contains($f.FullName)) { continue }
        $m = [regex]::Match([IO.Path]::GetFileNameWithoutExtension($f.Name), $rx, 'IgnoreCase')
        if (-not $m.Success) { continue }
        $base = (($m.Groups['pre'].Value + $m.Groups['post'].Value) -replace '\s+', ' ').Trim()
        $key = (Join-Path $f.DirectoryName $base) + '|' + $f.Extension.ToLower()
        if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.ArrayList }
        [void]$groups[$key].Add([pscustomobject]@{ N = [int]$m.Groups['n'].Value; File = $f; Base = $base })
    }
    foreach ($key in $groups.Keys) {
        $discs = @($groups[$key] | Sort-Object N)
        if ($discs.Count -lt 2) { continue }
        $m3u = Join-Path $discs[0].File.DirectoryName ($discs[0].Base + '.m3u')
        if (Test-Path -LiteralPath $m3u) { continue }
        foreach ($d in $discs) { [void]$covered.Add($d.File.FullName) }
        [void]$games.Add([pscustomobject]@{ File = $m3u; Discs = @($discs | ForEach-Object { $_.File.Name }); Note = "se creara .m3u ($($discs.Count) discos)" })
    }

    foreach ($f in $files) {
        if ($covered.Contains($f.FullName)) { continue }
        $note = ''
        if ($f.Extension -ieq '.m3u') {
            $n = 0
            try { $n = @([IO.File]::ReadAllLines($f.FullName) | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count } catch {}
            $note = ".m3u ($n discos)"
        }
        [void]$games.Add([pscustomobject]@{ File = $f.FullName; Discs = $null; Note = $note })
    }

    # Same game in several formats (Game.chd and Game.cue): keep the best.
    $best = @{}
    foreach ($g in $games) {
        $k = (Join-Path ([IO.Path]::GetDirectoryName($g.File)) ([IO.Path]::GetFileNameWithoutExtension($g.File))).ToLower()
        $r = [Array]::IndexOf($script:ExtRank, [IO.Path]::GetExtension($g.File).ToLower()); if ($r -lt 0) { $r = 99 }
        $g | Add-Member -NotePropertyName Rank -NotePropertyValue $r
        $g | Add-Member -NotePropertyName Dup -NotePropertyValue $false
        if (-not $best.ContainsKey($k) -or $best[$k].Rank -gt $r) { $best[$k] = $g }
    }
    foreach ($g in $games) {
        $k = (Join-Path ([IO.Path]::GetDirectoryName($g.File)) ([IO.Path]::GetFileNameWithoutExtension($g.File))).ToLower()
        if ($best[$k] -ne $g) { $g.Dup = $true; $g.Note = "otro formato de $([IO.Path]::GetFileName($best[$k].File))" }
    }
    return @($games | Sort-Object File)
}

# The SteamGridDB game closest to the name, and its first logo, hero and icon.
function Get-SgdbAuto([string]$clean) {
    $res = @(Invoke-Sgdb ('/search/autocomplete/' + [Uri]::EscapeDataString($clean)))
    if (-not $res.Count -and $clean -match '^(.+?) - ') { $res = @(Invoke-Sgdb ('/search/autocomplete/' + [Uri]::EscapeDataString($Matches[1]))) }
    if (-not $res.Count) { return $null }
    $g = $res | Where-Object { (Get-NormTitle $_.name) -eq (Get-NormTitle $clean) } | Select-Object -First 1
    if (-not $g) { $g = $res[0] }
    $o = @{ Name = [string]$g.name; Logo = $null; Bg = $null; Icon = $null }
    $l = @(Invoke-Sgdb "/logos/game/$($g.id)?mimes=image/png&nsfw=false&humor=false")
    if ($l.Count) { $o.Logo = Save-Remote ([string]$l[0].url) 'logo' $l[0].id }
    $h = @(Invoke-Sgdb "/heroes/game/$($g.id)?mimes=image/png,image/jpeg&nsfw=false&humor=false")
    if ($h.Count) { $o.Bg = Save-Remote ([string]$h[0].url) 'hero' $h[0].id }
    $c = @(Invoke-Sgdb "/icons/game/$($g.id)?mimes=image/png&nsfw=false&humor=false")
    if ($c.Count) { $o.Icon = Save-Remote ([string]$c[0].url) 'icon' $c[0].id }
    return $o
}

function Get-RegisteredRoms([string]$sd) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $reg = Join-Path "$sd\" 'forwarders\registry.txt'
    if (Test-Path -LiteralPath $reg) {
        foreach ($line in [IO.File]::ReadAllLines($reg, [Text.Encoding]::UTF8)) {
            $i = $line.IndexOf('|')
            if ($i -eq 16) { [void]$set.Add($line.Substring(17).TrimEnd()) }
        }
    }
    return $set
}

function Show-Batch {
    $sd = Get-SdRoot
    if (-not $sd) { Show-Error 'Primero conecta la SD de tu 3DS y dale a Actualizar.'; return }
    if (-not $cmbCore.SelectedItem) { Show-Error "No hay ningun core .3dsx en la SD.`nCopia pcsx_rearmed_libretro.3dsx (de RetroArch_3dsx.7z) a $sd\retroarch\cores\"; return }

    $bf = New-Object System.Windows.Forms.Form
    $bf.Text = 'Crear CIAs de varios juegos'
    $bf.ClientSize = New-Object System.Drawing.Size(760, 570)
    # Each game gets the core for its extension (.gb gambatte, .sfc snes9x...);
    # only extensions that say nothing (.bin, .7z) fall back to the main window's.
    $bf.StartPosition = 'CenterParent'
    $bf.FormBorderStyle = 'FixedSingle'
    $bf.MaximizeBox = $false
    $bf.Font = $form.Font
    function BAdd($ctl, [int]$x, [int]$y, [int]$w, [int]$h) {
        $ctl.Location = New-Object System.Drawing.Point($x, $y)
        $ctl.Size = New-Object System.Drawing.Size($w, $h)
        $bf.Controls.Add($ctl)
        return $ctl
    }

    $l = New-Object System.Windows.Forms.Label; $l.Text = 'Carpeta:'; $l.TextAlign = 'MiddleLeft'
    [void](BAdd $l 12 12 60 23)
    $txtDir = BAdd (New-Object System.Windows.Forms.TextBox) 75 12 470 23
    $txtDir.ReadOnly = $true
    $btnDir = BAdd (New-Object System.Windows.Forms.Button) 550 10 80 26; $btnDir.Text = 'Elegir...'
    $chkRec = BAdd (New-Object System.Windows.Forms.CheckBox) 636 12 120 23; $chkRec.Text = 'Subcarpetas'

    $chkM3u = BAdd (New-Object System.Windows.Forms.CheckBox) 12 42 360 22
    $chkM3u.Text = 'Crear el .m3u de los juegos de varios discos que no lo tengan'; $chkM3u.Checked = $true
    $chkSkip = BAdd (New-Object System.Windows.Forms.CheckBox) 380 42 370 22
    $chkSkip.Text = 'No marcar los juegos que ya tienen forwarder'; $chkSkip.Checked = $true
    $chkSg = BAdd (New-Object System.Windows.Forms.CheckBox) 12 64 360 22
    $chkSg.Text = 'SteamGridDB: usar el primer logo, fondo e icono'
    $chkSg.Checked = [bool]$txtKey.Text.Trim(); $chkSg.Enabled = [bool]$txtKey.Text.Trim()
    $lblOpts = BAdd (New-Object System.Windows.Forms.Label) 380 64 370 22
    $lblOpts.TextAlign = 'MiddleLeft'; $lblOpts.ForeColor = [System.Drawing.Color]::DimGray
    $snd = $(if ($script:Cfg.Sound -and (Test-Path -LiteralPath $script:Cfg.Sound)) { [IO.Path]::GetFileName($script:Cfg.Sound) } else { 'el de la plantilla' })
    $lblOpts.Text = "Banner transparente: $(if ($chkTrans.Checked) { 'si' } else { 'no' })   Sonido: $snd"

    $lv = BAdd (New-Object System.Windows.Forms.ListView) 12 92 736 370
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.GridLines = $true
    [void]$lv.Columns.Add('Juego', 230)
    [void]$lv.Columns.Add('Archivo', 220)
    [void]$lv.Columns.Add('Core', 110)
    [void]$lv.Columns.Add('Estado', 150)
    $hint = BAdd (New-Object System.Windows.Forms.Label) 12 465 736 20
    $hint.Text = 'Doble clic en un juego: cierra esta ventana y lo abre en la ventana principal para ajustarlo a mano.'
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $bp = BAdd (New-Object System.Windows.Forms.ProgressBar) 12 488 736 18
    $bs = BAdd (New-Object System.Windows.Forms.Label) 12 508 736 20; $bs.Text = 'Elige una carpeta de la SD.'
    $btnAll  = BAdd (New-Object System.Windows.Forms.Button) 12 532 80 28;  $btnAll.Text = 'Marcar todos'
    $btnNone = BAdd (New-Object System.Windows.Forms.Button) 96 532 80 28;  $btnNone.Text = 'Ninguno'
    $btnGo   = BAdd (New-Object System.Windows.Forms.Button) 520 528 124 34; $btnGo.Text = 'Crear CIAs'
    $btnGo.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btnX    = BAdd (New-Object System.Windows.Forms.Button) 650 528 98 34;  $btnX.Text = 'Cerrar'

    $state = @{ Running = $false; Stop = $false; Load = $null }

    $scan = {
        $lv.Items.Clear()
        if (-not $txtDir.Text) { return }
        $bf.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $reg = Get-RegisteredRoms $sd
            $found = Find-Games $txtDir.Text $chkRec.Checked
            foreach ($g in $found) {
                if ($g.Discs -and -not $chkM3u.Checked) { continue }
                $sdRom = 'sdmc:' + $g.File.Substring($sd.Length).Replace('\', '/')
                $it = New-Object System.Windows.Forms.ListViewItem((Get-CleanName ([IO.Path]::GetFileNameWithoutExtension($g.File))))
                [void]$it.SubItems.Add($g.File.Substring($txtDir.Text.TrimEnd('\').Length).TrimStart('\'))
                # The core follows the extension; unknown ones (.bin, .7z...) take the main window's.
                $core = Find-Core $g.File
                $g | Add-Member -NotePropertyName Core -NotePropertyValue $(if ($core) { $core } else { [string]$cmbCore.SelectedItem }) -Force
                [void]$it.SubItems.Add((Get-CoreStem $g.Core) + $(if ($core) { '' } else { ' (elegido)' }))
                $note = $g.Note
                $has = $reg.Contains($sdRom)
                if ($has) { $note = $(if ($note) { "$note, " } else { '' }) + 'ya tiene forwarder' }
                [void]$it.SubItems.Add($note)
                $it.Tag = $g
                $it.Checked = -not $g.Dup -and -not ($has -and $chkSkip.Checked)
                if ($g.Dup) { $it.ForeColor = [System.Drawing.Color]::Gray }
                [void]$lv.Items.Add($it)
            }
            $bs.Text = "$($lv.Items.Count) juegos encontrados, $(@($lv.CheckedItems).Count) marcados."
        } finally { $bf.Cursor = [System.Windows.Forms.Cursors]::Default }
    }

    $btnDir.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Carpeta de juegos en la SD'
        $d.SelectedPath = $(if ($txtDir.Text) { $txtDir.Text } else { Get-RememberedDir $sd $script:Cfg.LastBatchDir })
        if ($d.ShowDialog() -ne 'OK') { return }
        if (-not ($d.SelectedPath + '\').StartsWith("$sd\", [StringComparison]::OrdinalIgnoreCase)) {
            Show-Error "La carpeta tiene que estar en la SD ($sd)."
            return
        }
        $txtDir.Text = $d.SelectedPath
        Set-RememberedDir $sd $d.SelectedPath 'LastBatchDir' 
        & $scan
    })
    $chkRec.Add_CheckedChanged({ & $scan })
    $chkM3u.Add_CheckedChanged({ & $scan })
    $chkSkip.Add_CheckedChanged({ & $scan })
    $btnAll.Add_Click({ foreach ($it in $lv.Items) { $it.Checked = $true } })
    $btnNone.Add_Click({ foreach ($it in $lv.Items) { $it.Checked = $false } })
    $lv.Add_ItemChecked({ if (-not $state.Running) { $bs.Text = "$($lv.Items.Count) juegos encontrados, $(@($lv.CheckedItems).Count) marcados." } })
    $lv.Add_DoubleClick({
        if ($state.Running -or $lv.SelectedItems.Count -eq 0) { return }
        $g = $lv.SelectedItems[0].Tag
        if ($g.Discs) { Show-Error 'Ese juego todavia no tiene .m3u: crealo con "Crear CIAs" o abre un disco.'; return }
        $state.Load = $g.File
        $bf.Close()
    })
    $btnX.Add_Click({ if ($state.Running) { $state.Stop = $true; $btnX.Enabled = $false; $bs.Text = 'Deteniendo despues del juego actual...' } else { $bf.Close() } })
    $bf.Add_FormClosing({ param($s, $e) if ($state.Running) { $state.Stop = $true; $e.Cancel = $true } })

    $btnGo.Add_Click({
        $items = @($lv.CheckedItems)
        if (-not $items.Count) { Show-Error 'Marca al menos un juego.'; return }
        $ciaDir = "$sd\cias"
        if (-not (Test-Path -LiteralPath $ciaDir)) { [void](New-Item -ItemType Directory -Path $ciaDir) }
        $state.Running = $true; $state.Stop = $false
        foreach ($c in @($btnGo, $btnDir, $chkRec, $chkM3u, $chkSkip, $chkSg, $btnAll, $btnNone)) { $c.Enabled = $false }
        $btnX.Text = 'Detener'
        $bp.Maximum = $items.Count; $bp.Value = 0
        $ok = 0; $bad = 0
        foreach ($it in $items) {
            if ($state.Stop) { break }
            $g = $it.Tag
            $lv.EnsureVisible($it.Index)
            $it.SubItems[3].Text = 'Preparando...'; $it.ForeColor = [System.Drawing.SystemColors]::WindowText
            [System.Windows.Forms.Application]::DoEvents()
            try {
                if ($g.Discs) {
                    [IO.File]::WriteAllLines($g.File, [string[]]$g.Discs, (New-Object Text.UTF8Encoding($false)))
                    Write-Log "m3u creado: $($g.File)"
                }
                $stem = [IO.Path]::GetFileNameWithoutExtension($g.File)
                $clean = Get-CleanName $stem
                $sdRom = 'sdmc:' + $g.File.Substring($sd.Length).Replace('\', '/')
                if ([Text.Encoding]::UTF8.GetByteCount($sdRom) -gt 255) { throw 'ruta demasiado larga' }

                $names = @($stem, $clean)
                $logo = Find-Local 'logos' $names; $bg = Find-Local 'covers' $names; $icon = Find-Local 'icons' $names
                $src = @()
                if ($chkSg.Checked -and (-not $logo -or -not $bg -or -not $icon)) {
                    $it.SubItems[3].Text = 'SteamGridDB...'; [System.Windows.Forms.Application]::DoEvents()
                    try {
                        $a = Get-SgdbAuto $clean
                        if ($a) {
                            if (-not $logo) { $logo = $a.Logo }; if (-not $bg) { $bg = $a.Bg }; if (-not $icon) { $icon = $a.Icon }
                            $src += "SGDB: $($a.Name)"
                        }
                    } catch { $src += 'SGDB no respondio'; Write-Log "SGDB ${clean}: $($_.Exception.Message)" }
                }
                if (-not $bg) {
                    $bg = Get-LibretroArt 'Named_Titles' $stem $g.File $g.Core
                    if ($bg) { $src += 'fondo libretro' }
                }

                $it.SubItems[3].Text = 'Creando CIA...'; [System.Windows.Forms.Application]::DoEvents()
                $out = Join-Path $ciaDir (($clean -replace '[\\/:*?"<>|]', '') + '.cia')
                $r = Invoke-Build $sdRom $clean $bg $logo $icon ([bool]$chkTrans.Checked) $out $g.Core
                $it.SubItems[3].Text = "Listo, $($r.Tid.Substring(8))" + $(if ($r.Status -eq 'moved') { ' (ID movido)' } elseif ($r.Status -eq 'update') { ' (actualizado)' } else { '' })
                $it.ForeColor = [System.Drawing.Color]::DarkGreen
                $it.Checked = $false
                if ($src) { $it.ToolTipText = $src -join ', ' }
                $ok++
            } catch {
                $it.SubItems[3].Text = "Error: $($_.Exception.Message)"
                $it.ForeColor = [System.Drawing.Color]::DarkRed
                Write-Log "LOTE ERROR $($g.File): $($_.Exception.Message)"
                $bad++
            }
            $bp.Value = [Math]::Min($bp.Maximum, $bp.Value + 1)
            $bs.Text = "$ok creados, $bad con error, $($items.Count - $ok - $bad) pendientes."
            [System.Windows.Forms.Application]::DoEvents()
        }
        $state.Running = $false
        foreach ($c in @($btnGo, $btnDir, $chkRec, $chkM3u, $chkSkip, $btnAll, $btnNone)) { $c.Enabled = $true }
        $chkSg.Enabled = [bool]$txtKey.Text.Trim()
        $btnX.Text = 'Cerrar'; $btnX.Enabled = $true
        $bs.Text = "Terminado: $ok CIAs en $ciaDir" + $(if ($bad) { ", $bad con error (detalle en log.txt)" } else { '' }) + '. Instalalos con FBI.'
        Update-Tid
    })

    $lv.ShowItemToolTips = $true
    # Modal: the handlers above see this function's variables only while it runs.
    [void]$bf.ShowDialog($form)
    $bf.Dispose()
    if ($state.Load) { Load-Game $state.Load }
}

$btnBatch.Add_Click({ Show-Batch })

# ---------------------------------------------------------------- start
Refresh-Sd
Update-Sound
Update-Preview
try { [void]$form.ShowDialog() }
catch { Show-Error $_.Exception.Message }
