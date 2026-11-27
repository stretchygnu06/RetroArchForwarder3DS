#Requires -Version 5.1
<#
  DS Forwarder PC
  ---------------------------------------------------------------
  Crea en Windows forwarders (CIA) de juegos de Nintendo DS con el banner
  al estilo de RetroArch Forwarder PC (logo y fondo de SteamGridDB, banner
  transparente, portada de libretro) y el icono original del juego.

  - El forwarder es el de YANBF (nds-bootstrap): se usan su forwarder.elf,
    su build-cia.rsf y su makerom.exe, de la carpeta de YANBF.
  - El icono se saca de la ROM igual que lo hace YANBF.
  - Cada juego conserva el ID que ya tenia en YANBF (ids_anteriores.txt), asi
    el CIA nuevo se instala encima del viejo.
  - El banner y el SMDH los arma fwdgen-pc.exe a partir de template.cia.
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
$script:Settings = Join-Path $script:Root 'settings-ds.json'
$script:Versions = Join-Path $script:Root 'versions-ds.txt'
$script:LogFile  = Join-Path $script:Root 'log-ds.txt'
$script:ApiBase  = 'https://www.steamgriddb.com/api/v2'
$script:Thumbs   = 'http://thumbnails.libretro.com'
$script:AppName  = 'DS Forwarder PC'
$script:DsSystem = 'Nintendo - Nintendo DS'
# YANBF's range of unique ids: 0xFF400 + index + 1 (index -1 is 0xFF400).
$script:UidBase  = 0xFF400
$script:UidLast  = 0xFF7FF

function Show-Error([string]$msg) { [void][System.Windows.Forms.MessageBox]::Show($msg, $script:AppName, 'OK', 'Error') }
function Write-Log([string]$msg) {
    try { Add-Content -LiteralPath $script:LogFile -Value ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

foreach ($f in @($script:Cli, $script:Template, (Join-Path $script:Root 'FwdArt.cs'))) {
    if (-not (Test-Path -LiteralPath $f)) { Show-Error "Falta $([IO.Path]::GetFileName($f)) junto a este programa."; exit 1 }
}
foreach ($d in @('logos', 'covers', 'cache')) {
    $p = Join-Path $script:Root $d
    if (-not (Test-Path -LiteralPath $p)) { [void](New-Item -ItemType Directory -Path $p) }
}

if (-not ('FwdArt' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -Path (Join-Path $script:Root 'FwdArt.cs')
}

# ---------------------------------------------------------------- settings
$script:Cfg = @{ ApiKey = ''; AutoPick = $true; Sd = ''; Transparent = $true; CoverBanner = $false; Sound = ''; YanbfDir = ''; LastRomDir = ''; LastBatchDir = ''; OutDir = '' }
$script:FirstRun = -not (Test-Path -LiteralPath $script:Settings)
if (-not $script:FirstRun) {
    try {
        $j = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        foreach ($k in @('ApiKey', 'Sd', 'Sound', 'YanbfDir', 'LastRomDir', 'LastBatchDir', 'OutDir')) { if ($j.$k) { $script:Cfg[$k] = [string]$j.$k } }
        foreach ($k in @('AutoPick', 'Transparent', 'CoverBanner')) { if ($null -ne $j.$k) { $script:Cfg[$k] = [bool]$j.$k } }
    } catch {}
}
# First run: the API key and the SD of RetroArch Forwarder PC, next to this.
if (-not $script:Cfg.ApiKey) {
    try {
        $ra = Join-Path $script:Root 'settings.json'
        if (Test-Path -LiteralPath $ra) {
            $rj = Get-Content -LiteralPath $ra -Raw | ConvertFrom-Json
            if ($rj.ApiKey) { $script:Cfg.ApiKey = [string]$rj.ApiKey }
            if ($rj.Sd -and -not $script:Cfg.Sd) { $script:Cfg.Sd = [string]$rj.Sd }
            if ($rj.OutDir -and -not $script:Cfg.OutDir) { $script:Cfg.OutDir = [string]$rj.OutDir }
        }
    } catch {}
}
function Save-Settings { $script:Cfg | ConvertTo-Json | Set-Content -LiteralPath $script:Settings -Encoding UTF8 }

# Folders are remembered relative to the SD card, so they still work when
# Windows gives the card another drive letter.
function Get-RememberedDir([string]$sd, [string]$rel) {
    if ($rel) {
        $p = $sd + $rel
        while ($p.Length -gt $sd.Length) {
            if (Test-Path -LiteralPath $p -PathType Container) { return $p }
            $p = Split-Path -Parent $p
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

# ---------------------------------------------------------------- YANBF
# The folder that holds YANBF's makerom.exe and data\ (forwarder.elf, the
# rsf, dsboot.wav), and its ids_anteriores.txt / id.txt.
function Test-Yanbf([string]$dir) {
    if (-not $dir) { return $false }
    foreach ($f in @('makerom.exe', 'data\forwarder.elf', 'data\build-cia.rsf')) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $f))) { return $false }
    }
    return $true
}
function Find-Yanbf {
    if (Test-Yanbf $script:Cfg.YanbfDir) { return $script:Cfg.YanbfDir }
    try {
        $hits = Get-ChildItem -LiteralPath (Split-Path -Parent $script:Root) -Filter 'makerom.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue
        foreach ($h in $hits) { if (Test-Yanbf $h.DirectoryName) { return $h.DirectoryName } }
    } catch {}
    return $null
}

# index -> unique id, the way YANBF's generator turns id.txt into one.
function Get-Uid([int]$index) { return $script:UidBase + $index + 1 }
function Get-TidText([int]$uid) { return ('00040000{0:X8}' -f ($uid * 256)) }

# ids_anteriores.txt: "Game (USA).nds|index", one game per line.
function Read-YanbfIds {
    $o = @{ Map = @{}; Max = -1 }
    $dir = $script:Cfg.YanbfDir
    $f = Join-Path $dir 'ids_anteriores.txt'
    if (Test-Path -LiteralPath $f) {
        foreach ($line in [IO.File]::ReadAllLines($f)) {
            $i = $line.LastIndexOf('|')
            if ($i -le 0) { continue }
            $n = 0
            if (-not [int]::TryParse($line.Substring($i + 1).Trim(), [ref]$n)) { continue }
            $o.Map[$line.Substring(0, $i).Trim().ToLowerInvariant()] = $n
            if ($n -gt $o.Max) { $o.Max = $n }
        }
    }
    $t = Join-Path $dir 'id.txt'
    if (Test-Path -LiteralPath $t) {
        $n = 0
        if ([int]::TryParse(([IO.File]::ReadAllText($t)).Trim(), [ref]$n) -and $n -gt $o.Max) { $o.Max = $n }
    }
    return $o
}

# The titles installed on the card, as "0ff42c00" (low half of the title id).
function Get-Installed([string]$sd) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $base = Join-Path "$sd\" 'Nintendo 3DS'
    if (-not (Test-Path -LiteralPath $base)) { return ,$set }
    foreach ($id0 in Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue) {
        foreach ($id1 in Get-ChildItem -LiteralPath $id0.FullName -Directory -ErrorAction SilentlyContinue) {
            $t = Join-Path $id1.FullName 'title\00040000'
            if (-not (Test-Path -LiteralPath $t)) { continue }
            foreach ($d in Get-ChildItem -LiteralPath $t -Directory -ErrorAction SilentlyContinue) { [void]$set.Add($d.Name.ToLowerInvariant()) }
        }
    }
    # The comma keeps PowerShell from unrolling the set (an empty one would be $null).
    return ,$set
}

# A game keeps its YANBF index. A new one takes the next index after all those
# in use, skipping any id an installed title already holds.
function Get-DsId([string]$fileName, $ids, $installed) {
    $key = $fileName.ToLowerInvariant()
    if ($ids.Map.ContainsKey($key)) {
        $idx = [int]$ids.Map[$key]
        $uid = Get-Uid $idx
        $low = ('{0:x8}' -f ($uid * 256))
        return @{ Index = $idx; Uid = $uid; Tid = (Get-TidText $uid); Status = $(if ($installed.Contains($low)) { 'update' } else { 'known' }) }
    }
    $idx = $ids.Max + 1
    while ($true) {
        $uid = Get-Uid $idx
        if ($uid -gt $script:UidLast) { throw 'No quedan IDs libres en el rango de YANBF.' }
        if (-not $installed.Contains(('{0:x8}' -f ($uid * 256)))) { break }
        $idx++
    }
    return @{ Index = $idx; Uid = $uid; Tid = (Get-TidText $uid); Status = 'new' }
}

# Records a new game in ids_anteriores.txt and moves id.txt past it, so
# YANBF's own .bat files keep agreeing with this app.
function Save-DsId([string]$fileName, [int]$idx, $ids) {
    $dir = $script:Cfg.YanbfDir
    $key = $fileName.ToLowerInvariant()
    if (-not $ids.Map.ContainsKey($key)) {
        $f = Join-Path $dir 'ids_anteriores.txt'
        $sep = ''
        if (Test-Path -LiteralPath $f) {
            $bytes = [IO.File]::ReadAllBytes($f)
            if ($bytes.Length -and $bytes[-1] -ne 10) { $sep = "`r`n" }
        }
        [IO.File]::AppendAllText($f, "$sep$fileName|$idx`r`n", (New-Object Text.UTF8Encoding($false)))
        $ids.Map[$key] = $idx
    }
    if ($idx -gt $ids.Max) {
        $ids.Max = $idx
        [IO.File]::WriteAllText((Join-Path $dir 'id.txt'), "$idx`r`n", (New-Object Text.UTF8Encoding($false)))
    }
}

# Title versions: each build goes one up, so the HOME menu drops its cached
# icon and banner. YANBF built 1.6.3; this app starts at 2.0.0.
function Get-NextVersion([int]$uid) {
    $v = 2047
    if (Test-Path -LiteralPath $script:Versions) {
        foreach ($line in [IO.File]::ReadAllLines($script:Versions)) {
            $p = $line.Split('|')
            if ($p.Count -eq 2 -and $p[0] -eq ('{0:X5}' -f $uid)) { $n = 0; if ([int]::TryParse($p[1], [ref]$n) -and $n -gt $v) { $v = $n } }
        }
    }
    return [Math]::Min($v + 1, 65535)
}
function Save-Version([int]$uid, [int]$v) {
    Add-Content -LiteralPath $script:Versions -Value ('{0:X5}|{1}' -f $uid, $v) -Encoding ASCII
}

# ---------------------------------------------------------------- state
$script:Rom = $null        # E:\Nintendo DS Roms\Game (USA).nds
$script:GameName = $null   # Game (USA)
$script:Logo = $null; $script:Bg = $null
$script:LogoIsLocal = $false; $script:BgIsLocal = $false
$script:Cover = $null; $script:CoverTried = $false
$script:IconBmp = $null
$script:Ids = $null; $script:Installed = $null

# ---------------------------------------------------------------- helpers
function Q([string]$s) { '"' + $s + '"' }
function Get-CleanName([string]$n) { (($n -replace '\s*[\(\[][^\)\]]*[\)\]]', '') -replace '\s+', ' ').Trim() }
function Get-NormTitle([string]$s) { ($s.ToLowerInvariant() -replace '[^a-z0-9]', '') }

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

# A picture of YANBF's banners\ folder: a logo when it has transparent parts
# (what descargar_banners.ps1 leaves), a background otherwise.
function Find-YanbfBanner([string]$stem) {
    if (-not $script:Cfg.YanbfDir) { return $null }
    $p = Join-Path (Join-Path $script:Cfg.YanbfDir 'banners') "$stem.png"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $img = Load-Image $p
    if (-not $img) { return $null }
    try {
        $b = New-Object System.Drawing.Bitmap($img)
        $alpha = $false
        foreach ($pt in @(@(0, 0), @($b.Width - 1, 0), @(0, $b.Height - 1), @($b.Width - 1, $b.Height - 1), @([int]($b.Width / 2), 0))) {
            if ($b.GetPixel($pt[0], $pt[1]).A -lt 250) { $alpha = $true; break }
        }
        $b.Dispose()
        return @{ Path = $p; IsLogo = $alpha }
    } finally { $img.Dispose() }
}

function Invoke-Exe([string]$exe, [string]$arguments, [string]$cwd) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $arguments
    $psi.WorkingDirectory = $cwd
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
    Write-Log ("{0} {1} -> {2}`n{3}{4}" -f [IO.Path]::GetFileName($exe), $arguments, $p.ExitCode, $outTask.Result, $errTask.Result)
    return @{ ExitCode = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}

# Runs fwdgen-pc.exe and returns its KEY=VALUE lines as a hashtable.
function Invoke-Cli([string]$arguments) {
    $x = Invoke-Exe $script:Cli $arguments $script:Root
    $r = @{ ExitCode = $x.ExitCode }
    foreach ($line in ($x.Out -split "`r?`n")) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $r[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
    if ($x.Err) { $r['STDERR'] = $x.Err }
    return $r
}

# ---------------------------------------------------------------- libretro
# Downloads one libretro thumbnail to $dest, from the GitHub repository of the
# system (thumbnails.libretro.com as the fallback). Renamed games are git
# symlinks: the file then holds the name of the real image.
function Save-LibretroThumb([string]$system, [string]$kind, [string]$file, [string]$dest) {
    $repo = 'https://raw.githubusercontent.com/libretro-thumbnails/' + ($system -replace ' ', '_') + '/master/'
    $bases = @(
        @{ Url = { param($k, $f) $repo + $k + '/' + [Uri]::EscapeDataString($f) }; Links = $true },
        @{ Url = { param($k, $f) "$($script:Thumbs)/$([Uri]::EscapeDataString($system))/$k/$([Uri]::EscapeDataString($f))" }; Links = $false }
    )
    foreach ($b in $bases) {
        $k = $kind; $f = $file
        for ($hop = 0; $hop -le 3; $hop++) {
            try {
                Invoke-WebRequest -Uri (& $b.Url $k $f) -OutFile $dest -UseBasicParsing -TimeoutSec 20
            } catch { break }
            $bytes = [IO.File]::ReadAllBytes($dest)
            if ($bytes.Length -gt 8 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) { return $true }
            if (-not $b.Links -or $bytes.Length -gt 400) { break }
            $target = [Text.Encoding]::UTF8.GetString($bytes).Trim()
            if ($target -notmatch '\.png$' -or $target -match '^[a-z]+:' -or $target.StartsWith('/')) { break }
            $parts = @($k) + @($target -split '/')
            $stack = New-Object System.Collections.ArrayList
            $bad = $false
            foreach ($p in ($parts[0..($parts.Count - 2)])) {
                if ($p -eq '..') { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) } else { $bad = $true } }
                elseif ($p -and $p -ne '.') { [void]$stack.Add($p) }
            }
            if ($bad -or $stack.Count -ne 1) { break }
            $k = $stack[0]; $f = $parts[-1]
        }
    }
    Remove-Item -LiteralPath $dest -ErrorAction SilentlyContinue
    return $false
}

# Named_Titles / Named_Boxarts of a DS game, cached.
function Get-LibretroArt([string]$kind, [string]$gameName) {
    if (-not $gameName) { return $null }
    $file = ($gameName -replace '[&*/:`"<>?\\|]', '_') + '.png'
    $dest = Join-Path $script:CacheDir ("libretro_NintendoNintendoDS_{0}_{1}" -f $kind, $file)
    if (Test-Path -LiteralPath $dest) { return $dest }
    if (Save-LibretroThumb $script:DsSystem $kind $file $dest) { return $dest }
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

# The SteamGridDB game closest to the name, and its first logo and hero.
function Get-SgdbAuto([string]$clean) {
    $res = @(Invoke-Sgdb ('/search/autocomplete/' + [Uri]::EscapeDataString($clean)))
    if (-not $res.Count -and $clean -match '^(.+?) - ') { $res = @(Invoke-Sgdb ('/search/autocomplete/' + [Uri]::EscapeDataString($Matches[1]))) }
    if (-not $res.Count) { return $null }
    $g = $res | Where-Object { (Get-NormTitle $_.name) -eq (Get-NormTitle $clean) } | Select-Object -First 1
    if (-not $g) { $g = $res[0] }
    $o = @{ Name = [string]$g.name; Logo = $null; Bg = $null }
    $l = @(Invoke-Sgdb "/logos/game/$($g.id)?mimes=image/png&nsfw=false&humor=false")
    if ($l.Count) { $o.Logo = Save-Remote ([string]$l[0].url) 'logo' $l[0].id }
    $h = @(Invoke-Sgdb "/heroes/game/$($g.id)?mimes=image/png,image/jpeg&nsfw=false&humor=false")
    if ($h.Count) { $o.Bg = Save-Remote ([string]$h[0].url) 'hero' $h[0].id }
    return $o
}

# ---------------------------------------------------------------- art
# The banner picture, as RetroArch Forwarder PC makes it. Returns $true when
# it was written; $false leaves the template's banner.
function New-DsBanner([string]$bgPath, [string]$logoPath, [bool]$transparent, [string]$coverPath, [bool]$coverBanner, [string]$out) {
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
    $bg = Load-Image $bgPath; $logo = Load-Image $logoPath
    $cover = $(if ($coverBanner -and $coverPath) { Load-Image $coverPath } else { $null })
    try {
        if ($cover) {
            $b = [FwdArt]::FitOver($cover, 256, 128, 4, $transparent)
            if ($transparent) { [FwdArt]::SaveAlpha($b, $out) } else { [FwdArt]::SaveOpaque($b, $out) }
            $b.Dispose()
        } elseif ($logo -and $transparent) {
            $b = [FwdArt]::LogoOnly($logo, 256, 128, 248, 120)
            [FwdArt]::SaveAlpha($b, $out); $b.Dispose()
        } elseif ($bg -or $logo) {
            $b = [FwdArt]::Compose($bg, $logo, 256, 128, 232, 100, 3)
            [FwdArt]::SaveOpaque($b, $out); $b.Dispose()
        } else { return $false }
    } finally {
        foreach ($x in @($bg, $logo, $cover)) { if ($x) { $x.Dispose() } }
    }
    return $true
}

# Banner alpha is kept only for what can be transparent: the logo alone or the
# cover alone.
function Use-Alpha([bool]$transparent, [string]$logo, [string]$cover, [bool]$coverBanner) {
    return [bool]($transparent -and ($logo -or ($coverBanner -and $cover)))
}

# The banner sound: the one chosen, DS boot (YANBF's dsboot.wav) by default,
# or none.
function Get-Sound {
    if ($script:Cfg.Sound -eq 'none') { return $null }
    if ($script:Cfg.Sound -and (Test-Path -LiteralPath $script:Cfg.Sound)) { return $script:Cfg.Sound }
    if ($script:Cfg.YanbfDir) {
        $p = Join-Path $script:Cfg.YanbfDir 'data\dsboot.wav'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# ---------------------------------------------------------------- build
# Builds one CIA. Returns @{ Tid; Version; Status } or throws.
function Invoke-DsBuild([string]$romFile, [string]$name, [string]$publisher, [string]$bg, [string]$logo,
                        [bool]$transparent, [string]$cover, [bool]$coverBanner, [string]$out) {
    $sd = Get-SdRoot
    $ydir = $script:Cfg.YanbfDir
    if (-not (Test-Yanbf $ydir)) { throw 'No encuentro la carpeta de YANBF (makerom.exe y data\forwarder.elf).' }
    if (-not $romFile.StartsWith("$sd\", [StringComparison]::OrdinalIgnoreCase)) { throw "El juego tiene que estar en la SD ($sd)." }

    # What nds-bootstrap opens, as YANBF writes it: "sd:/folder/Game.nds".
    $sdPath = 'sd:' + $romFile.Substring($sd.Length).Replace('\', '/').Normalize([Text.NormalizationForm]::FormC)
    if ([Text.Encoding]::UTF8.GetByteCount($sdPath) -gt 255) { throw 'La ruta del juego es demasiado larga.' }

    $info = Invoke-Cli ("ndsinfo --rom {0}" -f (Q $romFile))
    if ($info.ERROR -or -not $info.GAMECODE) { throw "ROM: $(if ($info.ERROR) { $info.ERROR } else { 'no se pudo leer' })" }

    if (-not $script:Ids) { $script:Ids = Read-YanbfIds }
    if (-not $script:Installed) { $script:Installed = Get-Installed $sd }
    $fileName = [IO.Path]::GetFileName($romFile)
    $id = Get-DsId $fileName $script:Ids $script:Installed
    $ver = Get-NextVersion $id.Uid

    $work = Join-Path $env:TEMP 'dsfpc_build'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    [void](New-Item -ItemType Directory -Path (Join-Path $work 'romfs'))
    [IO.File]::WriteAllText((Join-Path $work 'romfs\path.txt'), $sdPath, (New-Object Text.UTF8Encoding($false)))

    $png = Join-Path $work 'banner.png'
    $hasArt = New-DsBanner $bg $logo $transparent $cover $coverBanner $png
    $name = ($name -replace '"', '').Trim()
    $publisher = ($publisher -replace '"', '').Trim()
    if (-not $publisher) { $publisher = 'Nintendo DS' }
    $cargs = "ds --template {0} --rom {1} --name {2} --publisher {3} --banner-out {4} --smdh-out {5}" -f `
        (Q $script:Template), (Q $romFile), (Q $name), (Q $publisher), (Q (Join-Path $work 'banner.bin')), (Q (Join-Path $work 'icon.smdh'))
    if ($hasArt) {
        $cargs += " --banner $(Q $png)"
        if (Use-Alpha $transparent $logo $cover $coverBanner) { $cargs += ' --transparent' }
    }
    $sound = Get-Sound
    if ($sound) { $cargs += " --sound $(Q $sound)" }
    $r = Invoke-Cli $cargs
    if ($r.ExitCode -ne 0 -or -not $r.OK) {
        throw "fwdgen-pc: $(if ($r.ERROR) { $r.ERROR } elseif ($r.STDERR) { $r.STDERR } else { "codigo $($r.ExitCode)" })"
    }

    # makerom, with the arguments of YANBF's generator. Its title is only the
    # internal process name: plain ASCII is enough.
    $title = (($name -replace '[^A-Za-z0-9 \-]', '') -replace '\s+', ' ').Trim()
    if (-not $title) { $title = $info.GAMECODE }
    $code = ($info.GAMECODE -replace '[^A-Za-z0-9]', '0')
    $major = $ver -shr 10; $minor = ($ver -shr 4) -band 63; $micro = $ver -band 15
    $margs = ('-f cia -target t -exefslogo -rsf {0} -elf {1} -banner banner.bin -icon icon.smdh -DAPP_ROMFS=romfs ' +
              '-major {2} -minor {3} -micro {4} -DAPP_VERSION_MAJOR={2} -o {5} -DAPP_PRODUCT_CODE=CTR-H-{6} -DAPP_TITLE={7} -DAPP_UNIQUE_ID=0x{8:X5}') -f `
        (Q (Join-Path $ydir 'data\build-cia.rsf')), (Q (Join-Path $ydir 'data\forwarder.elf')), $major, $minor, $micro, (Q $out), $code, (Q $title), $id.Uid
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
    $m = Invoke-Exe (Join-Path $ydir 'makerom.exe') $margs $work
    if ($m.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $out)) {
        $why = (($m.Err + "`n" + $m.Out).Trim() -split "`r?`n" | Select-Object -Last 3) -join ' '
        throw "makerom: $(if ($why) { $why } else { "codigo $($m.ExitCode)" })"
    }

    Save-DsId $fileName $id.Index $script:Ids
    Save-Version $id.Uid $ver
    return @{ Tid = $id.Tid; Version = ('{0}.{1}.{2}' -f $major, $minor, $micro); Status = $id.Status }
}

# ---------------------------------------------------------------- GUI
$form = New-Object System.Windows.Forms.Form
$form.Text = $script:AppName
$form.ClientSize = New-Object System.Drawing.Size(900, 716)
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
$tip = New-Object System.Windows.Forms.ToolTip

# --- left column: previews
$picBanner = Add-Ctl (New-Object System.Windows.Forms.PictureBox) 12 12 258 130
$picBanner.BorderStyle = 'FixedSingle'
$picIcon = Add-Ctl (New-Object System.Windows.Forms.PictureBox) 282 12 98 98
$picIcon.BorderStyle = 'FixedSingle'; $picIcon.SizeMode = 'StretchImage'
$lblIcon = New-Label 'Icono del juego' 282 113 116
$lblIcon.ForeColor = [System.Drawing.Color]::DimGray
$tip.SetToolTip($picIcon, 'El icono original del juego, sacado de la ROM igual que lo hace YANBF.')

$btnLogoLocal = New-Button 'Logo local...' 12 150 120
$btnLogoClear = New-Button 'Quitar logo' 136 150 90
$btnBgLocal   = New-Button 'Fondo local...' 12 182 120
$btnBgClear   = New-Button 'Quitar fondo' 136 182 90
$lblArt = New-Label '' 232 147 165
$lblArt.Height = 44; $lblArt.Font = New-Object System.Drawing.Font('Segoe UI', 7); $lblArt.TextAlign = 'TopLeft'; $lblArt.ForeColor = [System.Drawing.Color]::DimGray

$chkTrans = Add-Ctl (New-Object System.Windows.Forms.CheckBox) 232 192 170 23
$chkTrans.Text = 'Banner transparente'
$chkTrans.Checked = $script:Cfg.Transparent
$tip.SetToolTip($chkTrans, 'Solo el logo en el banner, sin fondo: se ve el fondo del menu HOME.')
$chkCoverBanner = Add-Ctl (New-Object System.Windows.Forms.CheckBox) 12 216 250 23
$chkCoverBanner.Text = 'Banner: portada de libretro'
$chkCoverBanner.Checked = $script:Cfg.CoverBanner
$tip.SetToolTip($chkCoverBanner, 'Usa la portada (Named_Boxarts) de libretro como banner en lugar del logo y el fondo. Con "Banner transparente" queda la portada sola.')

# --- left column: SD, game
[void](New-Label 'SD:' 12 248 40)
$cmbSd = Add-Ctl (New-Object System.Windows.Forms.ComboBox) 55 248 80 23
$cmbSd.DropDownStyle = 'DropDownList'
$btnSdRefresh = New-Button 'Actualizar' 140 247 75 25
$lblSd = New-Label '' 220 248 178
$lblSd.AutoEllipsis = $true

$btnRom = New-Button 'Elegir juego...' 12 280 120
$btnBatch = New-Button 'Varios juegos...' 136 280 120
$tip.SetToolTip($btnBatch, 'Crea los CIAs de todos los .nds de una carpeta de la SD.')
$lblRom = New-Label 'Ningun juego seleccionado' 262 282 136
$lblRom.AutoEllipsis = $true

[void](New-Label 'YANBF:' 12 314 90)
$lblYanbf = New-Label '' 105 314 205
$lblYanbf.AutoEllipsis = $true
$btnYanbf = New-Button 'Carpeta...' 314 312 84 26
$tip.SetToolTip($btnYanbf, 'La carpeta "generator" de YANBF: la que tiene makerom.exe, data\forwarder.elf e ids_anteriores.txt.')

[void](New-Label 'Nombre:' 12 346 90)
$txtName = New-TextBox 105 346 290 ''
$txtName.MaxLength = 64
$tip.SetToolTip($txtName, 'Se llena con el titulo que trae la ROM. Puedes cambiarlo.')
[void](New-Label 'Publisher:' 12 376 90)
$txtPub = New-TextBox 105 376 290 'Nintendo DS'
$txtPub.MaxLength = 64
$tip.SetToolTip($txtPub, 'La plataforma, como en RetroArch Forwarder PC. Puedes poner el de la ROM.')

[void](New-Label 'Title ID:' 12 408 90)
$lblTid = New-Label '-' 105 408 290
$lblTid.Font = New-Object System.Drawing.Font('Consolas', 9)
$lblTidInfo = New-Label '' 12 430 383
$lblTidInfo.Height = 36; $lblTidInfo.TextAlign = 'TopLeft'

[void](New-Label 'Sonido:' 12 472 55)
$lblSound = New-Label '' 68 472 150
$lblSound.AutoEllipsis = $true
$btnSound = New-Button 'Elegir...' 220 470 58 26
$btnSoundPlay = New-Button 'Probar' 280 470 46 26
$btnSoundDs = New-Button 'DS' 328 470 32 26
$btnSoundNone = New-Button 'Sin' 362 470 36 26
$tip.SetToolTip($btnSound, 'Sonido al seleccionar el icono en el menu HOME (WAV PCM, mono o estereo, maximo 3 segundos).')
$tip.SetToolTip($btnSoundDs, 'El sonido de arranque del DS (dsboot.wav de YANBF).')
$tip.SetToolTip($btnSoundNone, 'Sin sonido.')

[void](New-Label 'Salida:' 12 502 50)
$lblOut = New-Label '' 64 502 254
$lblOut.AutoEllipsis = $true
$btnOut = New-Button 'Cambiar...' 322 500 76 26
$tip.SetToolTip($btnOut, 'Carpeta donde se guardan los CIAs. Se recuerda (por defecto <SD>\cias).')

# The list of "Revisar uno por uno": hidden until it is in use.
$btnQPrev = New-Button '<' 12 530 30 27
$lblQueue = New-Label '' 46 532 152
$btnQNext = New-Button '>' 200 530 30 27
$btnQRest = New-Button 'Crear el resto (auto)' 234 530 134 27
$btnQEnd  = New-Button 'X' 370 530 28 27
$tip.SetToolTip($btnQPrev, 'Juego anterior de la lista (lo que elegiste se conserva).')
$tip.SetToolTip($btnQNext, 'Siguiente juego sin crear su CIA.')
$tip.SetToolTip($btnQRest, 'Crea los CIAs que faltan de la lista: los que ya revisaste con lo que elegiste, los demas con la eleccion automatica.')
$tip.SetToolTip($btnQEnd, 'Salir de la lista.')
foreach ($c in @($btnQPrev, $lblQueue, $btnQNext, $btnQRest, $btnQEnd)) { $c.Visible = $false }

$btnBuild = New-Button 'Crear CIA' 12 564 383 62
$btnBuild.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$progress = Add-Ctl (New-Object System.Windows.Forms.ProgressBar) 12 632 383 18
$progress.Maximum = 4
$lblStatus = New-Label 'Listo.' 12 652 383
$lblStatus.Height = 46; $lblStatus.TextAlign = 'TopLeft'

# --- right column: SteamGridDB
$grp = Add-Ctl (New-Object System.Windows.Forms.GroupBox) 410 6 478 702
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
$chkAuto.Text = 'Elegir automaticamente el primer logo y fondo al elegir juego'
$chkAuto.Checked = $script:Cfg.AutoPick

$tabs = Add-G (New-Object System.Windows.Forms.TabControl) 10 160 458 532
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

# ---------------------------------------------------------------- GUI logic
function Set-Status([string]$t, [int]$step = -1) {
    $lblStatus.Text = $t
    if ($step -ge 0) { $progress.Value = [Math]::Min($step, $progress.Maximum) }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-SdRoot { if ($cmbSd.SelectedItem) { return [string]$cmbSd.SelectedItem }; return $null }   # "E:"

# The output folder. One on the SD card is kept as "SD:\cias", so it follows
# the card when Windows gives it another letter. <SD>\cias by default.
function Get-OutDir {
    $sd = Get-SdRoot
    $o = $script:Cfg.OutDir
    if ($o -and $o.StartsWith('SD:')) { if ($sd) { return $sd + $o.Substring(3) }; return $null }
    if ($o -and (Test-Path -LiteralPath $o -PathType Container)) { return $o }
    if ($sd) { return "$sd\cias" }
    return $null
}
function Update-OutDir {
    $d = Get-OutDir
    $lblOut.Text = $(if ($d) { $d } else { '(conecta la SD)' })
    $tip.SetToolTip($lblOut, $lblOut.Text)
}
function Get-OutFile([string]$name) {
    $dir = Get-OutDir
    if (-not $dir) { throw 'No hay carpeta de salida: conecta la SD o elige una con "Cambiar...".' }
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $file = ($name -replace '[\\/:*?"<>|]', '').Trim()
    if (-not $file) { $file = 'forwarder' }
    return (Join-Path $dir ($file + '.cia'))
}

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
        return
    }
    $i = $cmbSd.Items.IndexOf($prev)
    $cmbSd.SelectedIndex = $(if ($i -ge 0) { $i } else { 0 })
}

function Update-Yanbf {
    $dir = Find-Yanbf
    if ($dir) {
        $script:Cfg.YanbfDir = $dir; Save-Settings
        $script:Ids = Read-YanbfIds
        $lblYanbf.Text = $dir; $lblYanbf.ForeColor = [System.Drawing.Color]::Green
        $tip.SetToolTip($lblYanbf, "$dir`n$($script:Ids.Map.Count) juegos en ids_anteriores.txt")
    } else {
        $lblYanbf.Text = 'No encontrada: elige la carpeta'; $lblYanbf.ForeColor = [System.Drawing.Color]::DarkRed
        $script:Ids = $null
    }
}

function Update-Sound {
    $p = Get-Sound
    if ($p) {
        $isDs = $script:Cfg.YanbfDir -and ($p -eq (Join-Path $script:Cfg.YanbfDir 'data\dsboot.wav'))
        $lblSound.Text = $(if ($isDs) { 'Arranque de DS' } else { [IO.Path]::GetFileName($p) })
        $lblSound.ForeColor = [System.Drawing.SystemColors]::ControlText
        $tip.SetToolTip($lblSound, $p)
    } else {
        $lblSound.Text = 'Sin sonido'; $lblSound.ForeColor = [System.Drawing.Color]::DimGray
        $tip.SetToolTip($lblSound, 'El icono no suena al seleccionarlo.')
    }
    $btnSoundPlay.Enabled = [bool]$p
}

function Update-Tid {
    $lblTid.Text = '-'; $lblTidInfo.Text = ''
    $sd = Get-SdRoot
    if (-not $sd -or -not $script:Rom) { return }
    if (-not $script:Ids) { $lblTidInfo.Text = 'Falta la carpeta de YANBF.'; $lblTidInfo.ForeColor = [System.Drawing.Color]::DarkRed; return }
    try {
        if (-not $script:Installed) { $script:Installed = Get-Installed $sd }
        $id = Get-DsId ([IO.Path]::GetFileName($script:Rom)) $script:Ids $script:Installed
        $lblTid.Text = $id.Tid
        switch ($id.Status) {
            'update' { $lblTidInfo.Text = 'Mismo ID que su forwarder de YANBF: el CIA lo reemplaza.'; $lblTidInfo.ForeColor = [System.Drawing.Color]::RoyalBlue }
            'known'  { $lblTidInfo.Text = 'Mismo ID que tenia en YANBF (no esta instalado ahora).'; $lblTidInfo.ForeColor = [System.Drawing.Color]::RoyalBlue }
            default  { $lblTidInfo.Text = "Juego nuevo: ID libre. $($script:Installed.Count) titulos revisados en la SD."; $lblTidInfo.ForeColor = [System.Drawing.Color]::Green }
        }
    } catch { $lblTidInfo.Text = "Error: $($_.Exception.Message)"; $lblTidInfo.ForeColor = [System.Drawing.Color]::DarkRed }
}

function Update-Preview {
    $trans = Use-Alpha $chkTrans.Checked $script:Logo $script:Cover $chkCoverBanner.Checked
    $picBanner.BackColor = $(if ($trans) { [System.Drawing.Color]::FromArgb(225, 225, 225) } else { [System.Drawing.SystemColors]::Control })
    $b = Join-Path $env:TEMP 'dsfpc_banner.png'
    $ok = New-DsBanner $script:Bg $script:Logo $chkTrans.Checked $script:Cover $chkCoverBanner.Checked $b
    $old = $picBanner.Image; $picBanner.Image = $(if ($ok) { Load-Image $b } else { $null }); if ($old) { $old.Dispose() }
    $old = $picIcon.Image; $picIcon.Image = Load-Image $script:IconBmp; if ($old) { $old.Dispose() }
    $t = @()
    if ($chkCoverBanner.Checked -and $script:Cover) { $t += 'Banner: portada de libretro' }
    else {
        $t += 'Logo: '  + $(if ($script:Logo) { [IO.Path]::GetFileName($script:Logo) } else { '(ninguno)' })
        $t += 'Fondo: ' + $(if ($script:Bg)   { [IO.Path]::GetFileName($script:Bg) }   else { '(ninguno)' })
    }
    if ($chkCoverBanner.Checked -and $script:Rom -and -not $script:Cover) { $t += 'Portada de libretro: no encontrada' }
    if (-not $ok) { $t += 'Sin imagenes: se usa la de la plantilla.' }
    $lblArt.Text = $t -join "`n"
}

function Clear-Thumbs {
    foreach ($fl in @($flLogos, $flHeroes, $flGrids)) {
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
        if ($tag.Kind -eq 'logo') { $script:Logo = $path; $script:LogoIsLocal = $true }
        else { $script:Bg = $path; $script:BgIsLocal = $true }
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
        foreach ($x in ($logos  | Select-Object -First 40)) { Add-Thumb $flLogos  $x 'logo' 200 80 }
        foreach ($x in ($heroes | Select-Object -First 40)) { Add-Thumb $flHeroes $x 'hero' 200 65 }
        foreach ($x in ($grids  | Select-Object -First 40)) { Add-Thumb $flGrids  $x 'grid' 96 140 }
        Set-Status ("{0} logos, {1} fondos, {2} portadas." -f @($logos).Count, @($heroes).Count, @($grids).Count)
        if ($autoPick) {
            if (-not $script:LogoIsLocal -and @($logos).Count -gt 0) { $script:Logo = Save-Remote ([string]$logos[0].url) 'logo' $logos[0].id }
            if (-not $script:BgIsLocal -and @($heroes).Count -gt 0)  { $script:Bg = Save-Remote ([string]$heroes[0].url) 'hero' $heroes[0].id }
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
$chkCoverBanner.Add_CheckedChanged({
    $script:Cfg.CoverBanner = $chkCoverBanner.Checked; Save-Settings
    if ($chkCoverBanner.Checked -and $script:Rom -and -not $script:CoverTried) {
        Set-Status 'Buscando portada en libretro...'
        $script:Cover = Get-LibretroArt 'Named_Boxarts' $script:GameName; $script:CoverTried = $true
        Set-Status 'Listo.'
    }
    Update-Preview
})
$btnSdRefresh.Add_Click({ Refresh-Sd })
$cmbSd.Add_SelectedIndexChanged({
    $script:Cfg.Sd = Get-SdRoot; Save-Settings
    Update-OutDir
    $script:Installed = $null
    $lblSd.Text = 'SD de 3DS'; $lblSd.ForeColor = [System.Drawing.Color]::Green
    if ($script:Rom -and -not $script:Rom.StartsWith((Get-SdRoot) + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $script:Rom = $null; $lblRom.Text = 'Ningun juego seleccionado'
    }
    Update-Tid
})
$btnYanbf.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Carpeta "generator" de YANBF (con makerom.exe y data\forwarder.elf)'
    if ($script:Cfg.YanbfDir) { $d.SelectedPath = $script:Cfg.YanbfDir }
    if ($d.ShowDialog() -ne 'OK') { return }
    if (-not (Test-Yanbf $d.SelectedPath)) { Show-Error 'Esa carpeta no tiene makerom.exe, data\forwarder.elf y data\build-cia.rsf.'; return }
    $script:Cfg.YanbfDir = $d.SelectedPath; Save-Settings
    Update-Yanbf; Update-Sound; Update-Tid
})

$btnSound.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Sonido WAV (*.wav)|*.wav'
    $cur = Get-Sound
    $d.InitialDirectory = $(if ($cur) { [IO.Path]::GetDirectoryName($cur) } else { $script:Root })
    if ($d.ShowDialog() -eq 'OK') { $script:Cfg.Sound = $d.FileName; Save-Settings; Update-Sound }
})
$btnSoundDs.Add_Click({ $script:Cfg.Sound = ''; Save-Settings; Update-Sound })
$btnSoundNone.Add_Click({ $script:Cfg.Sound = 'none'; Save-Settings; Update-Sound })
$btnSoundPlay.Add_Click({
    try { $sp = New-Object System.Media.SoundPlayer((Get-Sound)); $sp.Play() }
    catch { Show-Error "No se pudo reproducir:`n$($_.Exception.Message)" }
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
$btnLogoClear.Add_Click({ $script:Logo = $null; $script:LogoIsLocal = $false; Update-Preview })
$btnBgClear.Add_Click({ $script:Bg = $null; $script:BgIsLocal = $false; Update-Preview })

# Local art first (logos\, covers\, then YANBF's banners\), then libretro and
# SteamGridDB. Returns @{ Logo; Bg; Src }.
function Find-LocalArt([string]$stem) {
    $clean = Get-CleanName $stem
    $o = @{ Logo = (Find-Local 'logos' @($stem, $clean)); Bg = (Find-Local 'covers' @($stem, $clean)); Src = @() }
    if (-not $o.Logo -or -not $o.Bg) {
        $y = Find-YanbfBanner $stem
        if ($y) {
            if ($y.IsLogo -and -not $o.Logo) { $o.Logo = $y.Path; $o.Src += 'logo de banners\ (YANBF)' }
            elseif (-not $y.IsLogo -and -not $o.Bg) { $o.Bg = $y.Path; $o.Src += 'fondo de banners\ (YANBF)' }
        }
    }
    return $o
}

# Loads a game of the SD card into the main window.
function Load-Game([string]$file) {
    $sd = Get-SdRoot
    if (-not $sd) { Show-Error 'Primero conecta la SD de tu 3DS y dale a Actualizar.'; return }
    if (-not $file.StartsWith("$sd\", [StringComparison]::OrdinalIgnoreCase)) {
        Show-Error "El juego tiene que estar en la SD ($sd), porque el forwarder lo abre desde ahi."
        return
    }
    $bmp = Join-Path $env:TEMP 'dsfpc_icon.bmp'
    Remove-Item -LiteralPath $bmp -ErrorAction SilentlyContinue
    $info = Invoke-Cli ("ndsinfo --rom {0} --icon-bmp {1}" -f (Q $file), (Q $bmp))
    if ($info.ERROR -or -not $info.GAMECODE) { Show-Error "No se pudo leer la ROM:`n$(if ($info.ERROR) { $info.ERROR } else { $info.STDERR })"; return }

    $script:Rom = $file
    $script:GameName = [IO.Path]::GetFileNameWithoutExtension($file)
    $script:IconBmp = $bmp
    $clean = Get-CleanName $script:GameName
    $lblRom.Text = [IO.Path]::GetFileName($file)
    $txtName.Text = $(if ($info.TITLE) { $info.TITLE } else { $clean })
    $tip.SetToolTip($lblRom, "$file`nCodigo: $($info.GAMECODE)$(if ($info.MAKER) { "`nPublisher de la ROM: $($info.MAKER)" })")

    $a = Find-LocalArt $script:GameName
    $script:Logo = $a.Logo; $script:Bg = $a.Bg
    $script:LogoIsLocal = [bool]$script:Logo
    $script:BgIsLocal   = [bool]$script:Bg
    if (-not $script:Bg) {
        Set-Status 'Buscando pantalla de titulo en libretro...'
        $script:Bg = Get-LibretroArt 'Named_Titles' $script:GameName
    }
    $script:Cover = $null; $script:CoverTried = $false
    if ($chkCoverBanner.Checked) {
        Set-Status 'Buscando portada en libretro...'
        $script:Cover = Get-LibretroArt 'Named_Boxarts' $script:GameName; $script:CoverTried = $true
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
    Stop-Queue
    $sd = Get-SdRoot
    if (-not $sd) { Show-Error 'Primero conecta la SD de tu 3DS y dale a Actualizar.'; return }
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Juegos de DS (*.nds;*.dsi)|*.nds;*.dsi|Todos los archivos|*.*'
    $d.InitialDirectory = Get-RememberedDir $sd $script:Cfg.LastRomDir
    $d.RestoreDirectory = $true
    if ($d.ShowDialog() -ne 'OK') { return }
    Set-RememberedDir $sd ([IO.Path]::GetDirectoryName($d.FileName)) 'LastRomDir'
    Load-Game $d.FileName
})

$btnBuild.Add_Click({
    if (-not $script:Rom) { [void][System.Windows.Forms.MessageBox]::Show('Primero elige un juego de la SD.'); return }
    if (-not $script:Ids) { Show-Error 'Falta la carpeta de YANBF: dale a "Carpeta..." y elige su carpeta generator.'; return }
    $name = ($txtName.Text -replace '"', '').Trim()
    if (-not $name) { Show-Error 'Escribe un nombre para el juego.'; return }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $btnBuild.Enabled = $false
    $next = $false
    try {
        $out = Get-OutFile (Get-CleanName $script:GameName)
        Set-Status 'Creando banner, icono y CIA...' 2
        $r = Invoke-DsBuild $script:Rom $name $txtPub.Text $script:Bg $script:Logo ([bool]$chkTrans.Checked) $script:Cover ([bool]$chkCoverBanner.Checked) $out
        $script:Installed = $null
        Update-Tid
        Set-Status ("CIA creado: {0}  (Title ID {1}, version {2})" -f $out, $r.Tid, $r.Version) 4
        if (In-Queue) {
            $script:Queue[$script:QIndex].Built = $true
            $next = $true
        } else {
            [void][System.Windows.Forms.MessageBox]::Show("CIA creado:`n$out`n`nInstalalo en la 3DS con FBI. Si el juego ya tenia forwarder, se instala encima.", 'Listo')
        }
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
        Set-Status 'Error.' 0
        Show-Error "No se pudo crear el CIA:`n$($_.Exception.Message)"
    } finally {
        $btnBuild.Enabled = $true
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    if ($next) {
        $n = Find-NextPending $script:QIndex
        if ($n -ge 0) { Show-QueueItem $n }
        else {
            Update-QueueUi
            [void][System.Windows.Forms.MessageBox]::Show("Listo: ya estan todos los CIAs de la lista en`n$(Get-OutDir)`n`nInstalalos en la 3DS con FBI.", 'Lista terminada')
        }
    }
})

# ---------------------------------------------------------------- one by one
# "Revisar uno por uno": the games of the list open here one after another,
# each with its pictures picked automatically, for any change before its CIA.
# What was chosen for a game is kept when moving back and forth.
$script:Queue = @(); $script:QIndex = -1

function In-Queue { return [bool](@($script:Queue).Count -gt 0 -and $script:QIndex -ge 0) }

function Save-Picks {
    if (-not (In-Queue)) { return }
    $script:Queue[$script:QIndex].Picks = @{
        Logo = $script:Logo; Bg = $script:Bg; LogoIsLocal = $script:LogoIsLocal; BgIsLocal = $script:BgIsLocal
        Name = $txtName.Text; Pub = $txtPub.Text
    }
}

function Restore-Picks($p) {
    $script:Logo = $p.Logo; $script:Bg = $p.Bg
    $script:LogoIsLocal = $p.LogoIsLocal; $script:BgIsLocal = $p.BgIsLocal
    $txtName.Text = $p.Name; $txtPub.Text = $p.Pub
    Update-Preview
}

function Update-QueueUi {
    $on = In-Queue
    foreach ($c in @($btnQPrev, $lblQueue, $btnQNext, $btnQRest, $btnQEnd)) { $c.Visible = $on }
    if (-not $on) { $btnBuild.Text = 'Crear CIA'; return }
    $n = @($script:Queue).Count
    $done = @($script:Queue | Where-Object { $_.Built }).Count
    $lblQueue.Text = "Juego $($script:QIndex + 1) de $n ($done hechos)"
    $btnQPrev.Enabled = $script:QIndex -gt 0
    $btnQNext.Enabled = $script:QIndex -lt $n - 1
    $btnQRest.Enabled = $done -lt $n
    $btnBuild.Text = $(if ($script:Queue[$script:QIndex].Built) { 'Crear CIA otra vez' } elseif ((Find-NextPending $script:QIndex) -ge 0) { 'Crear CIA y siguiente' } else { 'Crear CIA' })
}

# The next game of the list without a CIA after $from, then from the start.
function Find-NextPending([int]$from) {
    $n = @($script:Queue).Count
    for ($k = 1; $k -lt $n; $k++) {
        $i = ($from + $k) % $n
        if (-not $script:Queue[$i].Built) { return $i }
    }
    return -1
}

function Show-QueueItem([int]$i) {
    Save-Picks
    $script:QIndex = $i
    $q = $script:Queue[$i]
    Load-Game $q.File
    if ($q.Picks) { Restore-Picks $q.Picks }
    Update-QueueUi
}

function Stop-Queue {
    $script:Queue = @(); $script:QIndex = -1
    Update-QueueUi
}

# Pictures picked automatically for one game, as the batch does: local files
# (logos\, covers\, YANBF's banners\), the libretro cover, the first
# SteamGridDB results, the libretro title screen.
function Get-AutoArt([string]$file, [bool]$useSgdb) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($file)
    $clean = Get-CleanName $stem
    $a = Find-LocalArt $stem
    $o = @{ Logo = $a.Logo; Bg = $a.Bg; Cover = $null; Src = @($a.Src) }
    if ($chkCoverBanner.Checked) {
        $o.Cover = Get-LibretroArt 'Named_Boxarts' $stem
        $o.Src += $(if ($o.Cover) { 'portada libretro' } else { 'sin portada libretro' })
    }
    if ($useSgdb -and (-not $o.Logo -or -not $o.Bg)) {
        try {
            $g = Get-SgdbAuto $clean
            if ($g) {
                if (-not $o.Logo) { $o.Logo = $g.Logo }; if (-not $o.Bg) { $o.Bg = $g.Bg }
                $o.Src += "SGDB: $($g.Name)"
            }
        } catch { $o.Src += 'SGDB no respondio'; Write-Log "SGDB ${clean}: $($_.Exception.Message)" }
    }
    if (-not $o.Bg) {
        $o.Bg = Get-LibretroArt 'Named_Titles' $stem
        if ($o.Bg) { $o.Src += 'fondo libretro' }
    }
    return $o
}

# "Crear el resto (auto)": every game of the list still without a CIA. Those
# already looked at keep what was chosen; the others take the automatic pick.
function Invoke-QueueRest {
    Save-Picks
    $todo = @(0..(@($script:Queue).Count - 1) | Where-Object { -not $script:Queue[$_].Built })
    if (-not $todo.Count) { return }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    foreach ($c in @($btnQPrev, $btnQNext, $btnQRest, $btnQEnd, $btnBuild, $btnRom, $btnBatch)) { $c.Enabled = $false }
    $ok = 0; $bad = 0; $k = 0
    try {
        foreach ($i in $todo) {
            $k++
            $q = $script:Queue[$i]
            $stem = [IO.Path]::GetFileNameWithoutExtension($q.File)
            Set-Status ("Creando {0} de {1}: {2}" -f $k, $todo.Count, $stem)
            try {
                $out = Get-OutFile (Get-CleanName $stem)
                if ($q.Picks) {
                    $p = $q.Picks
                    $cover = $(if ($chkCoverBanner.Checked) { Get-LibretroArt 'Named_Boxarts' $stem } else { $null })
                    $name = ($p.Name -replace '"', '').Trim(); if (-not $name) { $name = Get-CleanName $stem }
                    $r = Invoke-DsBuild $q.File $name $p.Pub $p.Bg $p.Logo ([bool]$chkTrans.Checked) $cover ([bool]$chkCoverBanner.Checked) $out
                } else {
                    $info = Invoke-Cli ("ndsinfo --rom {0}" -f (Q $q.File))
                    if ($info.ERROR) { throw $info.ERROR }
                    $name = $(if ($info.TITLE) { $info.TITLE } else { Get-CleanName $stem })
                    $a = Get-AutoArt $q.File ([bool]$txtKey.Text.Trim())
                    $r = Invoke-DsBuild $q.File $name $txtPub.Text $a.Bg $a.Logo ([bool]$chkTrans.Checked) $a.Cover ([bool]$chkCoverBanner.Checked) $out
                }
                $q.Built = $true
                $ok++
            } catch {
                Write-Log "LISTA ERROR $($q.File): $($_.Exception.Message)"
                $bad++
            }
            Update-QueueUi
        }
    } finally {
        foreach ($c in @($btnQPrev, $btnQNext, $btnQRest, $btnQEnd, $btnBuild, $btnRom, $btnBatch)) { $c.Enabled = $true }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $script:Installed = $null
        Update-QueueUi
        Update-Tid
    }
    Set-Status "Lista: $ok CIAs creados$(if ($bad) { ", $bad con error (detalle en log-ds.txt)" })."
    [void][System.Windows.Forms.MessageBox]::Show("$ok CIAs creados en`n$(Get-OutDir)$(if ($bad) { "`n$bad con error (detalle en log-ds.txt)" })", 'Lista')
}

$btnQPrev.Add_Click({ if ($script:QIndex -gt 0) { Show-QueueItem ($script:QIndex - 1) } })
$btnQNext.Add_Click({ if ($script:QIndex -lt @($script:Queue).Count - 1) { Show-QueueItem ($script:QIndex + 1) } })
$btnQRest.Add_Click({ Invoke-QueueRest })
$btnQEnd.Add_Click({ Stop-Queue; Set-Status 'Lista cerrada.' })
$btnOut.Add_Click({
    $sd = Get-SdRoot
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Carpeta donde guardar los CIAs'
    $cur = Get-OutDir
    if ($cur -and (Test-Path -LiteralPath $cur)) { $d.SelectedPath = $cur } elseif ($sd) { $d.SelectedPath = "$sd\" }
    if ($d.ShowDialog() -ne 'OK') { return }
    $dir = $d.SelectedPath.TrimEnd('\')
    if ($sd -and ($dir + '\').StartsWith("$sd\", [StringComparison]::OrdinalIgnoreCase)) { $script:Cfg.OutDir = 'SD:' + $dir.Substring($sd.Length) }
    else { $script:Cfg.OutDir = $dir }
    Save-Settings
    Update-OutDir
})

# ---------------------------------------------------------------- batch
function Show-Batch {
    $sd = Get-SdRoot
    if (-not $sd) { Show-Error 'Primero conecta la SD de tu 3DS y dale a Actualizar.'; return }
    if (-not $script:Ids) { Show-Error 'Falta la carpeta de YANBF: dale a "Carpeta..." y elige su carpeta generator.'; return }
    if (-not $script:Installed) { $script:Installed = Get-Installed $sd }

    $bf = New-Object System.Windows.Forms.Form
    $bf.Text = 'Crear CIAs de varios juegos de DS'
    $bf.ClientSize = New-Object System.Drawing.Size(760, 570)
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

    $chkSkip = BAdd (New-Object System.Windows.Forms.CheckBox) 12 42 360 22
    $chkSkip.Text = 'No marcar los juegos que ya tienen forwarder'; $chkSkip.Checked = $false
    $chkSg = BAdd (New-Object System.Windows.Forms.CheckBox) 380 42 370 22
    $chkSg.Text = 'SteamGridDB: usar el primer logo y fondo'
    $chkSg.Checked = [bool]$txtKey.Text.Trim(); $chkSg.Enabled = [bool]$txtKey.Text.Trim()
    $lblOpts = BAdd (New-Object System.Windows.Forms.Label) 12 64 736 22
    $lblOpts.TextAlign = 'MiddleLeft'; $lblOpts.ForeColor = [System.Drawing.Color]::DimGray
    $lblOpts.Text = "Transparente: $(if ($chkTrans.Checked) { 'si' } else { 'no' })   Portada como banner: $(if ($chkCoverBanner.Checked) { 'si' } else { 'no' })   Sonido: $($lblSound.Text)   Publisher: $($txtPub.Text)"

    $lv = BAdd (New-Object System.Windows.Forms.ListView) 12 92 736 370
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.GridLines = $true
    [void]$lv.Columns.Add('Juego', 240)
    [void]$lv.Columns.Add('Archivo', 230)
    [void]$lv.Columns.Add('ID', 80)
    [void]$lv.Columns.Add('Estado', 160)
    $hint = BAdd (New-Object System.Windows.Forms.Label) 12 465 736 20
    $hint.Text = 'Doble clic en un juego: cierra esta ventana y lo abre en la ventana principal para ajustarlo a mano.'
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $bp = BAdd (New-Object System.Windows.Forms.ProgressBar) 12 488 736 18
    $bs = BAdd (New-Object System.Windows.Forms.Label) 12 508 736 20; $bs.Text = 'Elige una carpeta de la SD.'
    $btnAll  = BAdd (New-Object System.Windows.Forms.Button) 12 532 80 28;  $btnAll.Text = 'Marcar todos'
    $btnNone = BAdd (New-Object System.Windows.Forms.Button) 96 532 80 28;  $btnNone.Text = 'Ninguno'
    $btnReview = BAdd (New-Object System.Windows.Forms.Button) 330 528 184 34; $btnReview.Text = 'Revisar uno por uno'
    $tip.SetToolTip($btnReview, 'Abre los juegos marcados uno tras otro en la ventana principal, con las imagenes ya elegidas, para cambiar lo que quieras antes de crear cada CIA.')
    $btnGo   = BAdd (New-Object System.Windows.Forms.Button) 520 528 124 34; $btnGo.Text = 'Crear CIAs'
    $btnGo.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btnX    = BAdd (New-Object System.Windows.Forms.Button) 650 528 98 34;  $btnX.Text = 'Cerrar'

    $state = @{ Running = $false; Stop = $false; Load = $null; Queue = $null }

    $scan = {
        $lv.Items.Clear()
        if (-not $txtDir.Text) { return }
        $bf.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $files = @(Get-ChildItem -LiteralPath $txtDir.Text -File -Recurse:$chkRec.Checked -ErrorAction SilentlyContinue |
                       Where-Object { @('.nds', '.dsi') -contains $_.Extension.ToLower() } | Sort-Object FullName)
            foreach ($f in $files) {
                $it = New-Object System.Windows.Forms.ListViewItem((Get-CleanName $f.BaseName))
                [void]$it.SubItems.Add($f.FullName.Substring($txtDir.Text.TrimEnd('\').Length).TrimStart('\'))
                $id = Get-DsId $f.Name $script:Ids $script:Installed
                # A new game's id is only known when it is built, after the others.
                [void]$it.SubItems.Add($(if ($id.Status -eq 'new') { '-' } else { $id.Tid.Substring(8) }))
                $has = $id.Status -ne 'new'
                [void]$it.SubItems.Add($(if ($id.Status -eq 'update') { 'tiene forwarder (instalado)' } elseif ($has) { 'tenia ID en YANBF' } else { 'nuevo' }))
                $it.Tag = $f.FullName
                $it.Checked = -not ($has -and $chkSkip.Checked)
                [void]$lv.Items.Add($it)
            }
            $bs.Text = "$($lv.Items.Count) juegos encontrados, $(@($lv.CheckedItems).Count) marcados."
        } finally { $bf.Cursor = [System.Windows.Forms.Cursors]::Default }
    }

    $btnDir.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Carpeta de juegos de DS en la SD'
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
    $chkSkip.Add_CheckedChanged({ & $scan })
    $btnAll.Add_Click({ foreach ($it in $lv.Items) { $it.Checked = $true } })
    $btnNone.Add_Click({ foreach ($it in $lv.Items) { $it.Checked = $false } })
    $lv.Add_ItemChecked({ if (-not $state.Running) { $bs.Text = "$($lv.Items.Count) juegos encontrados, $(@($lv.CheckedItems).Count) marcados." } })
    $lv.Add_DoubleClick({
        if ($state.Running -or $lv.SelectedItems.Count -eq 0) { return }
        $state.Load = [string]$lv.SelectedItems[0].Tag
        $bf.Close()
    })
    $btnReview.Add_Click({
        $items = @($lv.CheckedItems)
        if (-not $items.Count) { Show-Error 'Marca al menos un juego.'; return }
        $list = @()
        foreach ($it in $items) { $list += @{ File = [string]$it.Tag; Built = $false; Picks = $null } }
        $state.Queue = $list
        $bf.Close()
    })
    $btnX.Add_Click({ if ($state.Running) { $state.Stop = $true; $btnX.Enabled = $false; $bs.Text = 'Deteniendo despues del juego actual...' } else { $bf.Close() } })
    $bf.Add_FormClosing({ param($s, $e) if ($state.Running) { $state.Stop = $true; $e.Cancel = $true } })

    $btnGo.Add_Click({
        $items = @($lv.CheckedItems)
        if (-not $items.Count) { Show-Error 'Marca al menos un juego.'; return }
        $ciaDir = Get-OutDir
        if (-not $ciaDir) { Show-Error 'No hay carpeta de salida.'; return }
        $state.Running = $true; $state.Stop = $false
        foreach ($c in @($btnGo, $btnReview, $btnDir, $chkRec, $chkSkip, $chkSg, $btnAll, $btnNone)) { $c.Enabled = $false }
        $btnX.Text = 'Detener'
        $bp.Maximum = $items.Count; $bp.Value = 0
        $ok = 0; $bad = 0
        foreach ($it in $items) {
            if ($state.Stop) { break }
            $file = [string]$it.Tag
            $lv.EnsureVisible($it.Index)
            $it.SubItems[3].Text = 'Preparando...'; $it.ForeColor = [System.Drawing.SystemColors]::WindowText
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $stem = [IO.Path]::GetFileNameWithoutExtension($file)
                $clean = Get-CleanName $stem
                $info = Invoke-Cli ("ndsinfo --rom {0}" -f (Q $file))
                if ($info.ERROR) { throw $info.ERROR }
                $name = $(if ($info.TITLE) { $info.TITLE } else { $clean })

                $it.SubItems[3].Text = 'Buscando imagenes...'; [System.Windows.Forms.Application]::DoEvents()
                $a = Get-AutoArt $file ([bool]$chkSg.Checked)
                $logo = $a.Logo; $bg = $a.Bg; $cover = $a.Cover; $src = @($a.Src)

                $it.SubItems[3].Text = 'Creando CIA...'; [System.Windows.Forms.Application]::DoEvents()
                $out = Get-OutFile $clean
                $r = Invoke-DsBuild $file $name $txtPub.Text $bg $logo ([bool]$chkTrans.Checked) $cover ([bool]$chkCoverBanner.Checked) $out
                $it.SubItems[3].Text = "Listo, v$($r.Version)" + $(if ($r.Status -eq 'update') { ' (reemplaza)' } elseif ($r.Status -eq 'new') { ' (nuevo)' } else { '' })
                $it.ForeColor = [System.Drawing.Color]::DarkGreen
                $it.Checked = $false
                if ($src) { $it.ToolTipText = $src -join ', ' }
                $ok++
            } catch {
                $it.SubItems[3].Text = "Error: $($_.Exception.Message)"
                $it.ForeColor = [System.Drawing.Color]::DarkRed
                Write-Log "LOTE ERROR ${file}: $($_.Exception.Message)"
                $bad++
            }
            $bp.Value = [Math]::Min($bp.Maximum, $bp.Value + 1)
            $bs.Text = "$ok creados, $bad con error, $($items.Count - $ok - $bad) pendientes."
            [System.Windows.Forms.Application]::DoEvents()
        }
        $state.Running = $false
        foreach ($c in @($btnGo, $btnReview, $btnDir, $chkRec, $chkSkip, $btnAll, $btnNone)) { $c.Enabled = $true }
        $chkSg.Enabled = [bool]$txtKey.Text.Trim()
        $btnX.Text = 'Cerrar'; $btnX.Enabled = $true
        $bs.Text = "Terminado: $ok CIAs en $ciaDir" + $(if ($bad) { ", $bad con error (detalle en log-ds.txt)" } else { '' }) + '. Instalalos con FBI.'
        Update-Tid
    })

    $lv.ShowItemToolTips = $true
    # Modal: the handlers above see this function's variables only while it runs.
    [void]$bf.ShowDialog($form)
    $bf.Dispose()
    if ($state.Queue) {
        $script:Queue = @($state.Queue); $script:QIndex = -1
        Show-QueueItem 0
    } elseif ($state.Load) { Stop-Queue; Load-Game $state.Load }
}

$btnBatch.Add_Click({ Show-Batch })

# ---------------------------------------------------------------- start
Save-Settings
Update-Yanbf
Refresh-Sd
Update-OutDir
Update-Sound
Update-Preview
try { [void]$form.ShowDialog() }
catch { Show-Error $_.Exception.Message }
