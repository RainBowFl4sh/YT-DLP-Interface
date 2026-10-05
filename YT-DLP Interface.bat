<# : batch portion
@echo off
title YT-DLP Interface
cd /d "%~dp0"
mode con: cols=100 lines=45 >nul 2>&1

:: Set USE_PS7=0 to always use Windows PowerShell 5.1
set "USE_PS7=1"

set "PSEXE=powershell"
if "%USE_PS7%"=="1" (
    where pwsh >nul 2>&1 && set "PSEXE=pwsh"
    if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PSEXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
)

:: This file is batch and PowerShell in one: everything below this header is the program.
set "YTDLP_UI_SELF=%~f0"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command ". ([ScriptBlock]::Create([IO.File]::ReadAllText($env:YTDLP_UI_SELF, [Text.Encoding]::UTF8)))"
exit /b %errorlevel%
#>
# =====================================================================
#  YT-DLP Universal Downloader v2
#  Needs: Windows PowerShell 5.1, yt-dlp.exe, ffmpeg.exe (+ ffprobe.exe)
#  Single file: the batch header above starts this PowerShell part.
# =====================================================================
$ErrorActionPreference = 'Continue'
$script:Version = '2.4'

# The batch header passes the path of this file, the script itself is run from memory
$Root = $PSScriptRoot
if (-not $Root -and $env:YTDLP_UI_SELF) { $Root = Split-Path -Parent $env:YTDLP_UI_SELF }
if (-not $Root) { $Root = (Get-Location).Path }
Set-Location -LiteralPath $Root
$SettingsFile = Join-Path $Root 'settings.json'
$HistoryFile  = Join-Path $Root 'history.log'
$LinksFile    = Join-Path $Root 'links.txt'
$CookieFile   = Join-Path $Root 'cookies.txt'
$ToolsDir     = Join-Path $Root 'tools'
$env:PATH = "$ToolsDir;$Root;$env:PATH"   # tools in the tools / program folder are found by yt-dlp

$inv = [Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$env:PYTHONIOENCODING = 'utf-8'

# ---------------------------------------------------------------------
# Glyphs (Unicode boxes or plain ASCII)
# ---------------------------------------------------------------------
$G = @{}
function Set-Glyphs([bool]$Uni) {
    if ($Uni) {
        $G.Full  = [string][char]0x2588
        $G.Empty = [string][char]0x2591
        $G.H     = [string][char]0x2550
        $G.V     = [string][char]0x2551
        $G.TL    = [string][char]0x2554
        $G.TR    = [string][char]0x2557
        $G.BL    = [string][char]0x255A
        $G.BR    = [string][char]0x255D
        $G.Line  = [string][char]0x2500
    } else {
        $G.Full = '#'; $G.Empty = '-'; $G.H = '='; $G.V = '|'
        $G.TL = '+'; $G.TR = '+'; $G.BL = '+'; $G.BR = '+'; $G.Line = '-'
    }
}
Set-Glyphs $true

# ---------------------------------------------------------------------
# Small UI helpers
# ---------------------------------------------------------------------
function W([string]$Text = '', [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
}
function Wn([string]$Text, [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color -NoNewline
}
function Limit-Text([string]$t, [int]$n) {
    if ($t.Length -gt $n) { return $t.Substring(0, $n - 3) + '...' }
    return $t
}
function Read-Key {
    $k = [Console]::ReadKey($true)
    if ($k.Key -eq 'Enter')  { return 'ENTER' }
    if ($k.Key -eq 'Escape') { return 'ESC' }
    return ("" + $k.KeyChar).ToUpper()
}
function Wait-Key([string]$Msg = '  Press any key to continue...') {
    W ''
    Wn $Msg 'DarkGray'
    [void][Console]::ReadKey($true)
    Write-Host ''
}
function Get-Width {
    try { return [Math]::Max(40, [Console]::WindowWidth - 1) } catch { return 100 }
}
function Write-Rule {
    W ('  ' + ($G.Line * 68)) 'DarkGray'
}
function Write-Item([string]$Key, [string]$Text) {
    Wn "  [$Key] " 'Yellow'
    W $Text 'Gray'
}

# ---------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------
function Get-Defaults {
    return [ordered]@{
        DownloadFolder = (Join-Path $Root 'Downloads')
        Type           = 'video'      # video | audio
        Resolution     = 0            # 0 = best, else max height
        Mode           = 'quality'    # quality | fast | original
        KeepOriginal   = $false
        AudioFormat    = 'mp3'
        AudioQuality   = '0'          # 0 = best, or 320K / 256K / 192K / 128K
        Subtitles      = ''           # '' = off, else language codes
        Thumbnail      = $false
        Metadata       = $true
        SponsorBlock   = $false
        Playlist       = $false
        Encoder        = 'auto'       # auto | nvenc | amd | cpu
        RateLimit      = ''
        CookiesBrowser = ''
        RestrictNames  = $true
        OpenFolder     = $false
        Sound          = $true
        AutoUpdate     = $true
        Unicode        = $true
        SetupPending   = $true       # run the first-run setup on the next start
        AutoBenchmark  = $true       # speed test on first start and when the hardware changes
        CookieFileMode = 'patreon'   # patreon | always | never  (when cookies.txt is used)
    }
}
function Copy-Dict($d) {
    $n = [ordered]@{}
    foreach ($k in @($d.Keys)) { $n[$k] = $d[$k] }
    return $n
}
function Load-Settings {
    $s = Get-Defaults
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                if ($s.Contains($p.Name) -and $null -ne $p.Value) { $s[$p.Name] = $p.Value }
            }
        } catch { }
    }
    return $s
}
function Save-Settings {
    try { $script:S | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8 } catch { }
}

$script:S = Load-Settings
Set-Glyphs ([bool]$script:S.Unicode)

# ---------------------------------------------------------------------
# Tools and hardware
# ---------------------------------------------------------------------
function Find-Tool([string]$Name) {
    $inTools = Join-Path $ToolsDir "$Name.exe"
    if (Test-Path -LiteralPath $inTools) { return $inTools }
    $local = Join-Path $Root "$Name.exe"
    if (Test-Path -LiteralPath $local) { return $local }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Refresh-Tools {
    $script:ytdlp   = Find-Tool 'yt-dlp'
    $script:ffmpeg  = Find-Tool 'ffmpeg'
    $script:ffprobe = Find-Tool 'ffprobe'
}
Refresh-Tools

$script:VerYt = ''
$script:VerFf = 'not found'
$script:GpuNames = ''
$script:HasNv  = $false
$script:HasAmd = $false

function Read-Versions {
    $script:VerYt = ''
    $script:VerFf = 'not found'
    if ($ytdlp) { $script:VerYt = ("" + (& $ytdlp --version 2>$null)).Trim() }
    if ($ffmpeg) {
        $l = & $ffmpeg -version 2>$null | Select-Object -First 1
        if ("$l" -match 'version\s+(\S+)') { $script:VerFf = $matches[1] } else { $script:VerFf = 'found' }
    }
}

function Test-Enc([string]$Enc) {
    if (-not $ffmpeg) { return $false }
    $t = @('-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=256x256:d=0.2', '-c:v', $Enc, '-f', 'null', '-')
    & $ffmpeg @t 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Resolve-Encoder([string]$Pref) {
    switch ($Pref) {
        'nvenc' { return 'NVENC' }
        'amd'   { return 'AMD' }
        'cpu'   { return 'CPU' }
        default {
            if ($script:HasNv)  { return 'NVENC' }
            if ($script:HasAmd) { return 'AMD' }
            return 'CPU'
        }
    }
}

# ---------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------
function Show-Header([string]$Sub = '') {
    Clear-Host
    try { $Host.UI.RawUI.WindowTitle = 'YT-DLP Universal Downloader' } catch { }
    $inner = 70
    $left  = "  YT-DLP DOWNLOADER v$($script:Version)"
    $right = "$Sub  "
    $pad = $inner - $left.Length - $right.Length
    if ($pad -lt 1) { $pad = 1 }
    W ($G.TL + ($G.H * $inner) + $G.TR) 'Cyan'
    Wn $G.V 'Cyan'
    Wn $left 'White'
    Wn (' ' * $pad) 'Gray'
    Wn $right 'Yellow'
    W $G.V 'Cyan'
    W ($G.BL + ($G.H * $inner) + $G.BR) 'Cyan'
    $enc = Resolve-Encoder $script:S.Encoder
    $yv = $script:VerYt
    if (-not $yv) { $yv = 'MISSING' }
    W (" yt-dlp {0}  |  ffmpeg {1}  |  Encoder: {2}" -f $yv, $script:VerFf, $enc) 'DarkGray'
    W (" Folder: " + (Limit-Text ([string]$script:S.DownloadFolder) 62)) 'DarkGray'
}

# ---------------------------------------------------------------------
# Progress bar helpers
# ---------------------------------------------------------------------
$script:barActive   = $false
$script:streamTotal = 1
$script:streamCur   = 0
$script:lastExit    = 0
$script:lastErr     = ''
$script:seenWarn    = @{}

function Format-Bar([double]$Pct, [int]$Width = 30) {
    if ($Pct -lt 0)   { $Pct = 0 }
    if ($Pct -gt 100) { $Pct = 100 }
    $f = [int][Math]::Floor($Width * $Pct / 100)
    return ($G.Full * $f) + ($G.Empty * ($Width - $f))
}
function Format-Time([double]$Seconds) {
    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) { return '--:--' }
    $t = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    if ($t.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds) }
    return ('{0:00}:{1:00}' -f $t.Minutes, $t.Seconds)
}
function Show-Progress([string]$Label, [double]$Pct, [string]$Info, [string]$Suffix = '') {
    # a suffix (state of the background converter) needs room, so the bar gets shorter
    $bw = 30
    if ($Suffix) { $bw = 20 }
    $bar  = Format-Bar $Pct $bw
    $text = '  {0} [{1}] {2,5:N1}%  {3}' -f $Label.PadRight(11), $bar, $Pct, $Info
    if ($Suffix) { $text += '  ' + $Suffix }
    $w = Get-Width
    if ($text.Length -gt $w) { $text = $text.Substring(0, $w) }
    Write-Host ("`r" + $text.PadRight($w)) -NoNewline -ForegroundColor Green
    $script:barActive = $true
    try { $Host.UI.RawUI.WindowTitle = ('{0:N0}% - {1}' -f $Pct, $Label) } catch { }
}
function Hide-Progress {
    if ($script:barActive) {
        Write-Host ("`r" + (' ' * (Get-Width)) + "`r") -NoNewline
        $script:barActive = $false
    }
}
function End-Progress {
    Write-Host ''
    $script:barActive = $false
}
function Write-Line([string]$Text, [string]$Color = 'Gray') {
    Hide-Progress
    Write-Host $Text -ForegroundColor $Color
}

# ---------------------------------------------------------------------
# yt-dlp runner with download bar
# ---------------------------------------------------------------------
function Invoke-YtDlp([string[]]$YtArgs) {
    $script:streamTotal = 1
    $script:streamCur   = 0
    $script:lastErr     = ''
    $tmpl = 'download:PROG|%(progress.status)s|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s'
    $all  = @('--newline', '--progress', '--progress-template', $tmpl, '--no-mtime') + $YtArgs

    & $ytdlp @all 2>&1 | ForEach-Object {
        $isErr = $_ -is [System.Management.Automation.ErrorRecord]
        $line  = ("$_") -replace '\x1b\[[0-9;]*m', ''
        Update-Converter

        if ($line -match '^PROG\|') {
            $p   = $line.Split('|')
            $pct = -1.0
            if ($p[1] -eq 'finished') {
                $pct = 100.0
            } elseif ($p.Length -gt 2 -and $p[2] -match '([\d.]+)\s*%') {
                $pct = [double]::Parse($matches[1], $inv)
            }
            if ($pct -ge 0) {
                $label = 'Download'
                if ($script:streamTotal -gt 1) { $label = "Download $($script:streamCur)/$($script:streamTotal)" }
                $speed = ''; $eta = ''
                if ($p.Length -gt 3) { $speed = $p[3].Trim() }
                if ($p.Length -gt 4) { $eta   = $p[4].Trim() }
                Show-Progress $label $pct ("$speed  ETA $eta") (Get-ConverterStatus)
                if ($p[1] -eq 'finished') { End-Progress }
            }
        } else {
            if ($line -match 'format\(s\):\s*(\S+)') { $script:streamTotal = ($matches[1] -split '\+').Count }
            if ($line -match '^\[download\] Destination:') { $script:streamCur++ }
            if ($line.Trim() -eq '') { return }
            if ($line -match '^ERROR') {
                $script:lastErr = $line
                Write-Line ('  ' + $line) 'Red'
            } elseif ($isErr -or $line -match '^WARNING') {
                if ($script:seenWarn.ContainsKey($line)) { return }
                $script:seenWarn[$line] = $true
                Write-Line ('  ' + $line) 'Yellow'
            } else {
                Write-Line ('  ' + $line) 'DarkGray'
            }
        }
    }
    $script:lastExit = $LASTEXITCODE
}

# ---------------------------------------------------------------------
# Media info helpers (ffprobe)
# ---------------------------------------------------------------------
# Fallback when ffprobe is missing or reports no duration
function Get-Duration([string]$File) {
    $t = (& $ffmpeg -hide_banner -i $File 2>&1 | Out-String)
    if ($t -match 'Duration:\s*(\d+):(\d+):(\d+(\.\d+)?)') {
        return ([int]$matches[1] * 3600) + ([int]$matches[2] * 60) + [double]::Parse($matches[3], $inv)
    }
    return 0.0
}

function Get-StreamInfo([string]$File) {
    $info = [pscustomobject]@{ Width = 0; Height = 0; Fps = 30.0; VCodec = ''; ACodec = ''; Duration = 0.0 }
    if (-not $ffprobe) { return $info }
    try {
        # one ffprobe call for video stream, audio stream and duration
        $json = & $ffprobe -v error -show_entries 'stream=codec_type,codec_name,width,height,avg_frame_rate:format=duration' -of json $File 2>$null | Out-String
        $j = $json | ConvertFrom-Json
        $s = @($j.streams | Where-Object { $_.codec_type -eq 'video' })[0]
        $au = @($j.streams | Where-Object { $_.codec_type -eq 'audio' })[0]
        if ($s) {
            $info.VCodec = "$($s.codec_name)"
            $info.Width  = [int]$s.width
            $info.Height = [int]$s.height
            if ("$($s.avg_frame_rate)" -match '^(\d+)/(\d+)$') {
                $den = [double]$matches[2]
                if ($den -gt 0) { $info.Fps = [double]$matches[1] / $den }
            }
        }
        if ($au) { $info.ACodec = "$($au.codec_name)" }
        $d = 0.0
        if ([double]::TryParse("$($j.format.duration)", [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { $info.Duration = $d }
    } catch { }
    return $info
}

# ---------------------------------------------------------------------
# Encoding profiles
# ---------------------------------------------------------------------
function Get-Profile($info, [int]$MaxHeight) {
    $h = 0
    if ($info.Width -gt 0 -and $info.Height -gt 0) { $h = [Math]::Min($info.Width, $info.Height) }
    if ($h -le 0) { if ($MaxHeight -gt 0) { $h = $MaxHeight } else { $h = 1080 } }
    if ($h -le 720)      { $codec = 'h264'; $q = 18; $p = 'p6'; $tier = '720p or lower' }
    elseif ($h -le 1080) { $codec = 'h264'; $q = 19; $p = 'p5'; $tier = '1080p' }
    else                 { $codec = 'hevc'; $q = 23; $p = 'p4'; $tier = 'above 1080p' }
    if ($info.Fps -ge 50) { $q += 2 }
    return [pscustomobject]@{ Codec = $codec; Q = $q; Preset = $p; Tier = $tier }
}

function Get-EncArgs($prof, [string]$Enc) {
    $q = $prof.Q
    $hevc = ($prof.Codec -eq 'hevc')
    switch ($Enc) {
        'NVENC' {
            if ($hevc) { $v = @('-c:v', 'hevc_nvenc', '-preset', $prof.Preset, '-rc', 'vbr', '-cq', "$q", '-b:v', '0', '-tag:v', 'hvc1') }
            else       { $v = @('-c:v', 'h264_nvenc', '-preset', $prof.Preset, '-rc', 'vbr', '-cq', "$q", '-b:v', '0') }
            $desc = "NVENC $($prof.Codec) cq$q $($prof.Preset)"
        }
        'AMD' {
            $qp2 = $q + 2
            if ($hevc) { $v = @('-c:v', 'hevc_amf', '-quality', 'quality', '-rc', 'cqp', '-qp_i', "$q", '-qp_p', "$qp2", '-tag:v', 'hvc1') }
            else       { $v = @('-c:v', 'h264_amf', '-quality', 'quality', '-rc', 'cqp', '-qp_i', "$q", '-qp_p', "$qp2") }
            $desc = "AMD AMF $($prof.Codec) qp$q/$qp2"
        }
        default {
            if ($hevc) { $v = @('-c:v', 'libx265', '-preset', 'medium', '-crf', "$q", '-tag:v', 'hvc1') }
            else       { $v = @('-c:v', 'libx264', '-preset', 'medium', '-crf', "$q") }
            $desc = "CPU $($prof.Codec) crf$q"
        }
    }
    return [pscustomobject]@{ V = $v; Desc = $desc }
}

# ---------------------------------------------------------------------
# Background converter
# ffmpeg runs as its own process, so the next download can start while a
# finished one is still being converted. One conversion runs at a time,
# further files wait in a queue. Update-Converter has to be called
# regularly (download loop, wait loop) to keep it moving.
# ---------------------------------------------------------------------
$script:ConvQueue = New-Object System.Collections.Queue
$script:ConvCur   = $null
$script:ConvPoll  = [Diagnostics.Stopwatch]::StartNew()

# Builds a Windows command line (quotes arguments with spaces, escapes quotes and trailing backslashes)
function Join-ProcArgs([string[]]$List) {
    $out = foreach ($a in $List) {
        if ($a -ne '' -and $a -notmatch '[\s"]') { $a }
        else { '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
    }
    return ($out -join ' ')
}

function Write-Conv($t, [string]$Text, [string]$Color = 'Gray') {
    Write-Line ('  ' + $t.Tag + $Text) $Color
}

function Add-ConvertTask($res, $src, $O, [int]$Index, [int]$Total, $sw) {
    $t = @{ Res = $res; Src = $src; O = $O; Sw = $sw; Tag = ''; Label = 'Convert'; Proc = $null; Cur = 0.0; Speed = ''; Dur = 0.0 }
    if ($Total -gt 1) { $t.Tag = "[#$Index] "; $t.Label = "Convert #$Index" }
    $script:ConvQueue.Enqueue($t)
    Update-Converter -Now
}

function Start-ConvertTask($t) {
    $src  = $t.Src
    $info = Get-StreamInfo $src.FullName
    $t.Prof = Get-Profile $info ([int]$t.O.Resolution)
    Write-Conv $t ("Source : {0}x{1}, {2:N0} fps, video {3}, audio {4}" -f $info.Width, $info.Height, $info.Fps, $info.VCodec, $info.ACodec) 'DarkGray'

    $t.CopyVideo = ($t.O.Mode -eq 'fast' -and $info.VCodec -eq 'h264')
    $t.Out = Join-Path $src.DirectoryName (($src.BaseName -replace '_original$', '') + '.mp4')
    $t.Dur = $info.Duration
    if ($t.Dur -le 0) { $t.Dur = Get-Duration $src.FullName }
    if ($info.ACodec -eq 'aac') { $t.Audio = @('-c:a', 'copy') } else { $t.Audio = @('-c:a', 'aac', '-b:a', '192k') }

    $enc = Resolve-Encoder $t.O.Encoder
    $t.Attempts = @($enc)
    if ((-not $t.CopyVideo) -and $enc -ne 'CPU') { $t.Attempts += 'CPU' }
    $t.Try = 0
    Start-ConvertAttempt $t
}

function Start-ConvertAttempt($t) {
    if ($t.CopyVideo) {
        $v = @('-c:v', 'copy'); $pix = @(); $desc = 'video copy, no re-encode'
    } else {
        $ea = Get-EncArgs $t.Prof $t.Attempts[$t.Try]
        $v = $ea.V; $desc = $ea.Desc; $pix = @('-pix_fmt', 'yuv420p')
    }
    Write-Conv $t ("Converting to MP4 - {0} - {1}" -f $t.Prof.Tier, $desc) 'White'
    # ffmpeg writes its progress into a file, the program reads the end of that file
    $t.ProgFile = Join-Path $env:TEMP ('ytdlp_conv_' + [guid]::NewGuid().ToString('N') + '.txt')
    $ffArgs = @('-y', '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', $t.Src.FullName) + $v + $pix + $t.Audio +
              @('-movflags', '+faststart', '-progress', $t.ProgFile, '-nostats', $t.Out)
    $t.Cur = 0.0
    $t.Speed = ''
    $t.StartError = ''
    $t.Timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ffmpeg
        $psi.Arguments = Join-ProcArgs $ffArgs
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        $t.Proc = [Diagnostics.Process]::Start($psi)
        $t.ErrTask = $t.Proc.StandardError.ReadToEndAsync()
    } catch {
        $t.Proc = $null
        $t.StartError = $_.Exception.Message
    }
}

function Read-ConvProgress($t) {
    $txt = ''
    try {
        $fs = New-Object System.IO.FileStream($t.ProgFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $n = [int][Math]::Min(600, $fs.Length)
            if ($n -le 0) { return }
            [void]$fs.Seek(-$n, [IO.SeekOrigin]::End)
            $buf = New-Object byte[] $n
            $got = $fs.Read($buf, 0, $n)
            $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $got)
        } finally { $fs.Dispose() }
    } catch { return }
    $m = [regex]::Matches($txt, 'out_time_(?:us|ms)=(\d+)')
    if ($m.Count -gt 0) { $t.Cur = [double]::Parse($m[$m.Count - 1].Groups[1].Value, $inv) / 1000000.0 }
    $m = [regex]::Matches($txt, 'speed=\s*([\d.]+)x')
    if ($m.Count -gt 0) { $t.Speed = $m[$m.Count - 1].Groups[1].Value + 'x' }
}

function Get-ConvPct($t) {
    if ($t.Dur -le 0) { return 0.0 }
    return [Math]::Min(99.9, $t.Cur / $t.Dur * 100.0)
}

# Short state of the converter, shown behind the download bar
function Get-ConverterStatus {
    $t = $script:ConvCur
    if (-not $t) { return '' }
    $s = '| ' + $t.Label
    if ($t.Dur -gt 0) { $s += (' {0:N0}%' -f (Get-ConvPct $t)) }
    if ($script:ConvQueue.Count -gt 0) { $s += " +$($script:ConvQueue.Count)" }
    return $s
}

function Complete-ConvertTask($t) {
    $src = $t.Src
    # give subtitles / thumbnails the final name
    Get-ChildItem -LiteralPath $src.DirectoryName -File |
        Where-Object { $_.Name.StartsWith($src.BaseName + '.') -and $_.FullName -ne $src.FullName -and $_.Extension -in @('.srt', '.vtt', '.jpg', '.jpeg', '.png', '.webp') } |
        ForEach-Object {
            # only strip the "_original" marker, not the same text inside a title
            $newPath = Join-Path $_.DirectoryName (($src.BaseName -replace '_original$', '') + $_.Name.Substring($src.BaseName.Length))
            Move-Item -LiteralPath $_.FullName -Destination $newPath -Force -ErrorAction SilentlyContinue
        }
    if (-not $t.O.KeepOriginal) {
        Remove-Item -LiteralPath $src.FullName -Force -ErrorAction SilentlyContinue
    } else {
        Write-Conv $t ('Original kept: ' + $src.Name) 'DarkGray'
    }
    $it = Get-Item -LiteralPath $t.Out
    $t.Res.Ok   = $true
    $t.Res.File = $t.Out
    $t.Res.Size = $it.Length
    Write-Conv $t ('Saved  : ' + $t.Out) 'Green'
    Write-Conv $t ('Size   : {0:N1} MB     Time: {1}' -f ($it.Length / 1MB), (Format-Time $t.Sw.Elapsed.TotalSeconds)) 'Green'
}

# Called when the ffmpeg process of the current task has ended (or could not be started)
function Complete-ConvertAttempt($t) {
    $code = -1
    $errText = $t.StartError
    if ($t.Proc) {
        try {
            $t.Proc.WaitForExit()
            $code = $t.Proc.ExitCode
            $errText = "$($t.ErrTask.Result)"
        } catch { }
        $t.Proc.Dispose()
        $t.Proc = $null
    }
    Remove-Item -LiteralPath $t.ProgFile -Force -ErrorAction SilentlyContinue

    if ($code -eq 0 -and (Test-Path -LiteralPath $t.Out)) {
        Complete-ConvertTask $t
        Add-History $t.Res $t.O.Type
        $script:ConvCur = $null
        return
    }
    Remove-Item -LiteralPath $t.Out -Force -ErrorAction SilentlyContinue
    foreach ($l in @("$errText" -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 4)) {
        Write-Conv $t (Limit-Text $l.Trim() 110) 'Red'
    }
    $t.Try++
    if ($t.Try -lt $t.Attempts.Count) {
        Write-Conv $t 'GPU encoding failed - retrying on the CPU...' 'Yellow'
        Start-ConvertAttempt $t
        return
    }
    Write-Conv $t 'FAILED: Conversion failed. The original file was kept.' 'Red'
    $t.Res.Error = 'Conversion failed.'
    Add-History $t.Res $t.O.Type
    $script:ConvCur = $null
}

# Moves the converter on: reads the progress, finishes an ended conversion, starts the next one
function Update-Converter([switch]$Now) {
    if (-not $script:ConvCur -and $script:ConvQueue.Count -eq 0) { return }
    if ((-not $Now) -and $script:ConvPoll.ElapsedMilliseconds -lt 250) { return }
    $script:ConvPoll.Restart()
    $t = $script:ConvCur
    if ($t) {
        if ($t.Proc -and -not $t.Proc.HasExited) { Read-ConvProgress $t; return }
        Complete-ConvertAttempt $t
        if ($script:ConvCur) { return }
    }
    if ($script:ConvQueue.Count -gt 0) {
        $script:ConvCur = $script:ConvQueue.Dequeue()
        Start-ConvertTask $script:ConvCur
    }
}

# Shows the conversion bar until the converter is idle,
# or (with -UntilWaiting N) until at most N files are waiting for it
function Wait-Converter([int]$UntilWaiting = -1) {
    while ($true) {
        Update-Converter -Now
        $t = $script:ConvCur
        if (-not $t) { break }
        if ($UntilWaiting -ge 0 -and $script:ConvQueue.Count -le $UntilWaiting) { break }
        $more = ''
        if ($script:ConvQueue.Count -gt 0) { $more = "   ($($script:ConvQueue.Count) waiting)" }
        if ($t.Dur -gt 0) {
            $pct = Get-ConvPct $t
            $eta = -1.0
            if ($pct -gt 1) { $eta = $t.Timer.Elapsed.TotalSeconds * (100.0 - $pct) / $pct }
            Show-Progress $t.Label $pct ("$($t.Speed)  ETA $(Format-Time $eta)$more")
        } else {
            Write-Host ("`r  $($t.Label)  processed " + (Format-Time $t.Cur) + "  $($t.Speed)$more").PadRight((Get-Width)) -NoNewline
            $script:barActive = $true
        }
        Start-Sleep -Milliseconds 200
    }
    Hide-Progress
}

# ---------------------------------------------------------------------
# Argument builders
# ---------------------------------------------------------------------
function Get-CookieArgs($O, [string]$Url) {
    $a = New-Object System.Collections.Generic.List[string]
    if ($O.CookiesBrowser) {
        $a.Add('--cookies-from-browser'); $a.Add([string]$O.CookiesBrowser)
    } elseif (Test-Path -LiteralPath $CookieFile) {
        $mode = [string]$O.CookieFileMode
        if (-not $mode) { $mode = 'patreon' }
        if ($mode -eq 'always' -or ($mode -eq 'patreon' -and $Url -match 'patreon\.com')) {
            $a.Add('--cookies'); $a.Add($CookieFile)
        }
    }
    return $a.ToArray()
}

function Get-CommonArgs($O, [string]$Url) {
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add('--no-playlist')
    if ($O.RestrictNames) { $a.Add('--restrict-filenames') } else { $a.Add('--windows-filenames') }
    foreach ($c in @(Get-CookieArgs $O $Url)) { $a.Add($c) }
    if ($O.RateLimit)    { $a.Add('--limit-rate'); $a.Add([string]$O.RateLimit) }
    if ($O.Metadata)     { $a.Add('--embed-metadata') }
    if ($O.SponsorBlock) { $a.Add('--sponsorblock-remove'); $a.Add('sponsor,selfpromo,interaction') }
    if ($O.Section) {
        $sec = [string]$O.Section
        if ($sec.EndsWith('-')) { $sec += 'inf' }
        $a.Add('--download-sections'); $a.Add('*' + $sec); $a.Add('--force-keyframes-at-cuts')
    }
    if ($O.Type -eq 'video') {
        if ($O.Subtitles) {
            $a.Add('--write-subs'); $a.Add('--write-auto-subs')
            $a.Add('--sub-langs'); $a.Add([string]$O.Subtitles)
            $a.Add('--convert-subs'); $a.Add('srt')
        }
        if ($O.Thumbnail) { $a.Add('--write-thumbnail'); $a.Add('--convert-thumbnails'); $a.Add('jpg') }
    } else {
        if ($O.Thumbnail) { $a.Add('--embed-thumbnail'); $a.Add('--convert-thumbnails'); $a.Add('jpg') }
    }
    return $a.ToArray()
}

function Get-FormatString($O) {
    $hf = ''
    if ([int]$O.Resolution -gt 0) { $hf = "[height<=$([int]$O.Resolution)]" }
    if ($O.Mode -eq 'fast') {
        return "bv*${hf}[vcodec^=avc1]+ba[ext=m4a]/bv*${hf}[vcodec^=avc1]+ba/bv*${hf}+ba/b${hf}/b"
    }
    return "bv*${hf}+ba/b${hf}/b"
}

function Safe-Name([string]$n) {
    $n = $n -replace '[\\/:*?"<>|]', '_'
    return $n.Trim().TrimEnd('.')
}

# ---------------------------------------------------------------------
# Video info / playlist helpers
# ---------------------------------------------------------------------
function Get-Meta([string]$Url, $O) {
    $tpl = '%(title)s|||%(uploader)s|||%(duration_string)s|||%(upload_date)s|||%(height)s|||%(fps)s|||%(playlist_title)s'
    $a = @('--no-warnings', '--print', $tpl) + @(Get-CookieArgs $O $Url)
    if ($O.Playlist) { $a += @('--yes-playlist', '--playlist-items', '1') } else { $a += '--no-playlist' }
    $a += $Url
    $out = @(& $ytdlp @a 2>$null)
    $line = $out | Where-Object { "$_" -match '\|\|\|' } | Select-Object -First 1
    if (-not $line) { return $null }
    $p = ("$line") -split '\|\|\|'
    if ($p.Count -lt 7) { return $null }
    return [pscustomobject]@{ Title = $p[0]; Uploader = $p[1]; Duration = $p[2]; Date = $p[3]; Height = $p[4]; Fps = $p[5]; Playlist = $p[6] }
}

function Show-MetaPanel($m) {
    W ''
    if (-not $m) { W '  (no video info available - you can still download)' 'DarkGray'; return }
    Wn '  Title    : ' 'DarkGray'; W (Limit-Text $m.Title 58) 'White'
    if ($m.Uploader -ne 'NA') { Wn '  Channel  : ' 'DarkGray'; W (Limit-Text $m.Uploader 58) 'Gray' }
    $parts = @()
    if ($m.Duration -ne 'NA') { $parts += "Duration $($m.Duration)" }
    if ($m.Date -match '^\d{8}$') { $parts += ('Uploaded {0}-{1}-{2}' -f $m.Date.Substring(0, 4), $m.Date.Substring(4, 2), $m.Date.Substring(6, 2)) }
    if ($m.Height -ne 'NA') {
        $x = "Best $($m.Height)p"
        if ($m.Fps -ne 'NA') { $x += " $($m.Fps)fps" }
        $parts += $x
    }
    if ($parts.Count -gt 0) { Wn '  Info     : ' 'DarkGray'; W ($parts -join '   ') 'Gray' }
    if ($m.Playlist -ne 'NA') { Wn '  Playlist : ' 'DarkGray'; W (Limit-Text $m.Playlist 58) 'Cyan' }
}

function Get-PlaylistItems([string]$Url, $O) {
    $a = @('--flat-playlist', '--no-warnings', '--yes-playlist', '--print', '%(playlist_title)s|||%(webpage_url,url)s') + @(Get-CookieArgs $O $Url) + @($Url)
    $lines = @(& $ytdlp @a 2>$null)
    $items = @()
    $title = ''
    foreach ($l in $lines) {
        $p = ("$l") -split '\|\|\|'
        if ($p.Count -ge 2 -and $p[1].Trim() -match '^https?://') {
            $items += $p[1].Trim()
            if ((-not $title) -and $p[0] -ne 'NA') { $title = $p[0].Trim() }
        }
    }
    return [pscustomobject]@{ Title = $title; Items = $items }
}

# ---------------------------------------------------------------------
# History
# ---------------------------------------------------------------------
function Add-History($r, [string]$Type) {
    $st = 'FAIL'
    if ($r.Ok) { $st = 'OK' }
    $line = '{0}|{1}|{2}|{3}|{4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $st, $Type, $r.File, $r.Url
    try { Add-Content -LiteralPath $HistoryFile -Value $line -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------------
# Download of ONE url
# ---------------------------------------------------------------------
function Read-PathFile([string]$Tmp) {
    $found = $null
    if (Test-Path -LiteralPath $Tmp) {
        $found = Get-Content -LiteralPath $Tmp -Encoding UTF8 |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Last 1
        Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
    }
    return $found
}

function New-Fail($res, [string]$Msg) {
    $res.Error = $Msg
    Write-Line ("  FAILED: " + $Msg) 'Red'
    return $res
}

# Downloads one url. A video that still has to be converted is handed to the background
# converter and comes back with Pending = $true.
function Start-OneDownload([string]$Url, $O, [string]$OutDir, [string]$Prefix, [int]$Index = 1, [int]$Total = 1) {
    $res = [pscustomobject]@{ Url = $Url; Ok = $false; File = ''; Size = 0; Error = ''; Pending = $false }
    $sw = [Diagnostics.Stopwatch]::StartNew()

    try {
        if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction Stop | Out-Null }
    } catch {
        return (New-Fail $res "Cannot create folder $OutDir")
    }

    $common   = @(Get-CommonArgs $O $Url)
    $tmp      = Join-Path $env:TEMP ('ytdlp_' + [guid]::NewGuid().ToString('N') + '.txt')
    $pathArgs = @('--no-simulate', '--print-to-file', 'after_move:filepath', $tmp)
    $stamp    = (Get-Date).AddSeconds(-2)
    $isAudio  = ($O.Type -eq 'audio')
    $convert  = ((-not $isAudio) -and ($O.Mode -ne 'original'))

    if ($isAudio) {
        $a = @('-f', 'bestaudio/best', '-x', '--audio-format', [string]$O.AudioFormat, '--audio-quality', [string]$O.AudioQuality,
               '-o', "$OutDir\$Prefix%(title)s.%(ext)s")
        W '  Downloading audio...' 'White'
    } elseif ($convert) {
        $a = @('-f', (Get-FormatString $O), '-o', "$OutDir\$Prefix%(title)s_original.%(ext)s")
        W '  Downloading original file...' 'White'
    } else {
        $a = @('-f', (Get-FormatString $O), '-o', "$OutDir\$Prefix%(title)s.%(ext)s")
        W '  Downloading video (no conversion)...' 'White'
    }

    Invoke-YtDlp -YtArgs ($common + $pathArgs + $a + @($Url))
    if ($script:lastExit -ne 0) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $m = $script:lastErr
        if (-not $m) { $m = "yt-dlp exit code $($script:lastExit)" }
        $null = New-Fail $res $m
        if ($m -match '(?i)cookies|log ?in|sign in|members.only|no access|not have access|private') {
            Write-Line '  Hint: this usually means login cookies are needed - see main menu [C] Cookies.' 'Yellow'
        }
        return $res
    }

    $file = Read-PathFile $tmp
    if (-not $file) {
        $pat = '*'
        if ($convert) { $pat = '*_original.*' }
        $c = Get-ChildItem -LiteralPath $OutDir -File -Filter $pat |
            Where-Object { $_.LastWriteTime -ge $stamp -and $_.Extension -notin @('.part', '.ytdl', '.temp', '.jpg', '.png', '.webp', '.srt', '.vtt') } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($c) { $file = $c.FullName }
    }
    if (-not $file) { return (New-Fail $res 'Could not locate the downloaded file.') }

    if ($convert) {
        # the conversion runs in the background, its result is written into $res later
        $res.Pending = $true
        if ($Index -lt $Total) { Write-Line '  Download finished - it is converted while the next download runs.' 'DarkGray' }
        Add-ConvertTask $res (Get-Item -LiteralPath $file) $O $Index $Total $sw
        return $res
    }

    $it = Get-Item -LiteralPath $file
    $res.Ok = $true
    $res.File = $file
    $res.Size = $it.Length
    Write-Line ('  Saved  : ' + $file) 'Green'
    Write-Line ('  Size   : {0:N1} MB     Time: {1}' -f ($it.Length / 1MB), (Format-Time $sw.Elapsed.TotalSeconds)) 'Green'
    return $res
}

# ---------------------------------------------------------------------
# Queue (single link, batch, playlist)
# ---------------------------------------------------------------------
function Start-Queue([string[]]$Urls, $O) {
    $jobs = New-Object System.Collections.ArrayList
    foreach ($u0 in $Urls) {
        $u = $u0
        $usePl = ([bool]$O.Playlist) -or ($u -match 'youtube\.com/playlist\?')
        if ($usePl) {
            W '  Reading playlist...' 'DarkGray'
            $pl = Get-PlaylistItems $u $O
            if ($pl.Items.Count -gt 1) {
                $name = Safe-Name $pl.Title
                if (-not $name) { $name = 'Playlist' }
                $dir = Join-Path ([string]$O.DownloadFolder) $name
                $n = 0
                foreach ($it in $pl.Items) {
                    $n++
                    [void]$jobs.Add(@{ Url = $it; Dir = $dir; Prefix = ('{0:000}_' -f $n) })
                }
                W ("  Playlist '{0}': {1} videos" -f $name, $pl.Items.Count) 'Cyan'
                continue
            }
            if ($pl.Items.Count -eq 1) { $u = $pl.Items[0] }
        }
        [void]$jobs.Add(@{ Url = $u; Dir = [string]$O.DownloadFolder; Prefix = '' })
    }

    $results = New-Object System.Collections.ArrayList
    $n = $jobs.Count
    $i = 0
    $total = [Diagnostics.Stopwatch]::StartNew()
    foreach ($j in $jobs) {
        $i++
        # do not pile up unconverted originals on the disk when downloads are faster than the converter
        if ($script:ConvQueue.Count -ge 2) {
            Write-Line ''
            Write-Line '  Waiting for the converter to catch up before the next download...' 'DarkGray'
            Wait-Converter -UntilWaiting 1
        }
        Write-Line ''
        if ($n -gt 1) {
            $ov = ($i - 1) / $n * 100
            W ("  Overall [{0}] {1}/{2} downloaded" -f (Format-Bar $ov 30), ($i - 1), $n) 'Cyan'
        }
        W ("  Item {0} of {1}: {2}" -f $i, $n, (Limit-Text $j.Url 70)) 'White'
        Write-Rule
        $r = @(Start-OneDownload $j.Url $O $j.Dir $j.Prefix $i $n) | Select-Object -Last 1
        [void]$results.Add($r)
        if (-not $r.Pending) { Add-History $r $O.Type }
    }
    # the last conversions are still running
    if ($script:ConvCur -or $script:ConvQueue.Count -gt 0) {
        if ($n -gt 1) {
            Write-Line ''
            Write-Line '  All downloads finished - waiting for the remaining conversions...' 'Cyan'
        }
        Wait-Converter
    }

    $ok = @($results | Where-Object { $_.Ok }).Count
    $bad = @($results | Where-Object { -not $_.Ok })
    Write-Host ''
    Write-Rule
    if ($bad.Count -eq 0) {
        W ("  All done: {0} OK   (total time {1})" -f $ok, (Format-Time $total.Elapsed.TotalSeconds)) 'Green'
    } else {
        W ("  Finished: {0} OK, {1} failed   (total time {2})" -f $ok, $bad.Count, (Format-Time $total.Elapsed.TotalSeconds)) 'Yellow'
        foreach ($b in $bad) { W ("   x {0}" -f (Limit-Text $b.Url 60)) 'Red'; W ("     {0}" -f (Limit-Text $b.Error 64)) 'DarkRed' }
    }
    try { $Host.UI.RawUI.WindowTitle = 'YT-DLP Universal Downloader' } catch { }
    if ($O.Sound) { try { [System.Media.SystemSounds]::Asterisk.Play(); Start-Sleep -Milliseconds 400 } catch { } }
    if ($O.OpenFolder -and $ok -gt 0) { try { Start-Process explorer.exe ([string]$O.DownloadFolder) } catch { } }
}

# ---------------------------------------------------------------------
# Option definitions (used by the options screen AND the settings screen)
# ---------------------------------------------------------------------
$ResValues = @(0, 2160, 1440, 1080, 720, 480)
$Defs = @(
    @{ Key = '1'; Field = 'Type';         Label = 'Type';               Kind = 'cycle'; Vals = @('video', 'audio'); Group = 'What to download'; Scope = 'both'; Rel = { param($o) $true }
       Hint = 'Video = picture and sound as MP4.  Audio = sound only (MP3, M4A, ...).' },
    @{ Key = '2'; Field = 'Resolution';   Label = 'Resolution';         Kind = 'cycle'; Vals = $ResValues; Group = 'Video'; Scope = 'both'; Rel = { param($o) $o.Type -eq 'video' }
       Hint = 'Upper limit. The best stream up to this height is downloaded.' },
    @{ Key = '3'; Field = 'Mode';         Label = 'Encoding mode';      Kind = 'cycle'; Vals = @('quality', 'fast', 'original'); Group = 'Video'; Scope = 'both'; Rel = { param($o) $o.Type -eq 'video' }
       Hint = 'Quality = re-encode, tuned to the resolution.  Fast = copy H.264, no loss.  Original = no conversion.' },
    @{ Key = '4'; Field = 'KeepOriginal'; Label = 'Keep original file'; Kind = 'bool'; Group = 'Video'; Scope = 'both'; Rel = { param($o) $o.Type -eq 'video' -and $o.Mode -ne 'original' }
       Hint = 'Also keep the downloaded source file (..._original.webm) next to the MP4.' },
    @{ Key = '7'; Field = 'Subtitles';    Label = 'Subtitles';          Kind = 'text'; Group = 'Video'; Scope = 'both'; Rel = { param($o) $o.Type -eq 'video' }
       Prompt = 'Language codes, e.g. en  or  de,en   (empty = off)'
       Hint = 'Saved as separate .srt files next to the video (manual subtitles, else auto-generated).' },
    @{ Key = '5'; Field = 'AudioFormat';  Label = 'Audio format';       Kind = 'cycle'; Vals = @('mp3', 'm4a', 'opus', 'flac', 'wav'); Group = 'Audio'; Scope = 'both'; Rel = { param($o) $o.Type -eq 'audio' }
       Hint = 'MP3 = most compatible, M4A = AAC, OPUS = best for size, FLAC/WAV = lossless container.' },
    @{ Key = '6'; Field = 'AudioQuality'; Label = 'Audio quality';      Kind = 'cycle'; Vals = @('0', '320K', '256K', '192K', '128K'); Group = 'Audio'; Scope = 'both'; Rel = { param($o) $o.Type -eq 'audio' }
       Hint = 'Best = highest quality yt-dlp can produce. A fixed bitrate makes smaller files.' },
    @{ Key = '8'; Field = 'Thumbnail';    Label = 'Thumbnail';          Kind = 'bool'; Group = 'Extras'; Scope = 'both'; Rel = { param($o) $true }
       Hint = 'Video: save the cover as .jpg.  Audio: embed it as cover art in the file.' },
    @{ Key = '9'; Field = 'Metadata';     Label = 'Embed metadata';     Kind = 'bool'; Group = 'Extras'; Scope = 'both'; Rel = { param($o) $true }
       Hint = 'Writes title, channel, date and chapters into the file tags.' },
    @{ Key = 'A'; Field = 'SponsorBlock'; Label = 'Cut sponsor parts';  Kind = 'bool'; Group = 'Extras'; Scope = 'both'; Rel = { param($o) $true }
       Hint = 'Removes sponsor / self-promo / interaction segments (YouTube, community data via SponsorBlock).' },
    @{ Key = 'P'; Field = 'Playlist';     Label = 'Playlist';           Kind = 'bool'; Group = 'Extras'; Scope = 'both'; Rel = { param($o) $true }
       Hint = 'On = download every video of a playlist link into its own sub folder.' },
    @{ Key = 'T'; Field = 'Section';      Label = 'Time range';         Kind = 'text'; Group = 'Extras'; Scope = 'download'; Rel = { param($o) $true }
       Prompt = 'START-END, e.g. 1:30-2:45   or   10:00-  (until the end).  Empty = full video'
       Hint = 'Download only a part of the video. The progress bar may stay empty while cutting.' },
    @{ Key = 'F'; Field = 'DownloadFolder'; Label = 'Download folder';  Kind = 'text'; Group = 'Output'; Scope = 'both'; Rel = { param($o) $true }
       Prompt = 'Full path of the folder (created if missing). Empty = keep current'
       Hint = 'Where the finished files are saved.' },
    @{ Key = 'E'; Field = 'Encoder';      Label = 'Encoder';            Kind = 'cycle'; Vals = @('auto', 'nvenc', 'amd', 'cpu'); Group = 'Program'; Scope = 'settings'; Rel = { param($o) $true }
       Hint = 'Auto = best working GPU encoder, else CPU. Force one if auto picks wrong.' },
    @{ Key = 'L'; Field = 'RateLimit';    Label = 'Speed limit';        Kind = 'text'; Group = 'Program'; Scope = 'settings'; Rel = { param($o) $true }
       Prompt = 'Max download speed, e.g. 5M or 800K   (empty = unlimited)'
       Hint = 'Useful if the download slows down your internet.' },
    @{ Key = 'K'; Field = 'CookiesBrowser'; Label = 'Cookies from browser'; Kind = 'cycle'; Vals = @('', 'firefox', 'chrome', 'edge', 'brave'); Group = 'Program'; Scope = 'settings'; Rel = { param($o) $true }
       Hint = 'Use your logged-in browser for age-restricted or members-only videos. Firefox works best.' },
    @{ Key = 'N'; Field = 'RestrictNames'; Label = 'Safe file names';   Kind = 'bool'; Group = 'Program'; Scope = 'settings'; Rel = { param($o) $true }
       Hint = 'Yes = only simple ASCII characters and underscores. No = keep the full original title.' },
    @{ Key = 'O'; Field = 'OpenFolder';   Label = 'Open folder when done'; Kind = 'bool'; Group = 'Program'; Scope = 'settings'; Rel = { param($o) $true }
       Hint = 'Opens the download folder in Explorer after a successful download.' },
    @{ Key = 'M'; Field = 'Sound';        Label = 'Sound when done';    Kind = 'bool'; Group = 'Program'; Scope = 'settings'; Rel = { param($o) $true }
       Hint = 'Plays a short notification sound after the last download.' },
    @{ Key = 'Y'; Field = 'AutoUpdate';   Label = 'Update yt-dlp on start'; Kind = 'bool'; Group = 'Program'; Scope = 'settings'; Rel = { param($o) $true }
       Hint = 'Checks for a new yt-dlp version every time the program starts.' },
    @{ Key = 'U'; Field = 'Unicode';      Label = 'Fancy graphics';     Kind = 'bool'; Group = 'Program'; Scope = 'settings'; Rel = { param($o) $true }
       Hint = 'Off = plain ASCII bars and boxes (use this if you see strange symbols).' },
    @{ Key = 'X'; Field = 'SetupPending'; Label = 'Run setup on next start'; Kind = 'bool'; Group = 'Program'; Scope = 'settings'; Rel = { param($o) $true }
       Hint = 'On = the first-run setup (install yt-dlp, ffmpeg, deno, plugins) runs at the next start. Use it after deleting tools.' },
    @{ Key = 'V'; Field = 'AutoBenchmark'; Label = 'Auto speed test'; Kind = 'bool'; Group = 'Program'; Scope = 'settings'; Rel = { param($o) $true }
       Hint = 'On = the speed test runs by itself on the first start and after a hardware change. Off = only from Tools.' },
    @{ Key = 'C'; Field = 'CookieFileMode'; Label = 'cookies.txt usage'; Kind = 'cycle'; Vals = @('patreon', 'always', 'never'); Group = 'Program'; Scope = 'settings'; Rel = { param($o) $true }
       Hint = 'When the cookies.txt file is used: only for Patreon links, for all links, or never. Main menu C helps you create it.' }
)

function Format-Opt([string]$F, $O) {
    $v = $O[$F]
    switch ($F) {
        'Type'       { if ($v -eq 'audio') { return 'Audio only' }; return 'Video' }
        'Resolution' { if ([int]$v -eq 0) { return 'Best available' }; return ('max. {0}p' -f $v) }
        'Mode'       {
            if ($v -eq 'fast') { return 'Fast (copy H.264, no re-encode)' }
            if ($v -eq 'original') { return 'Original (no conversion)' }
            return 'Quality (re-encode, optimized)'
        }
        'Encoder'    {
            if ($v -eq 'auto') { return ('Auto (detected: {0})' -f (Resolve-Encoder 'auto')) }
            return ("$v").ToUpper()
        }
        'AudioQuality' { if ("$v" -eq '0') { return 'Best' }; return "$v" }
        'AudioFormat'  { return ("$v").ToUpper() }
        'Subtitles'    { if ($v) { return "$v (separate .srt)" }; return 'Off' }
        'Thumbnail'    {
            if (-not $v) { return 'No' }
            if ($O.Type -eq 'audio') { return 'Embed as cover art' }
            return 'Save as .jpg'
        }
        'Playlist'       { if ($v) { return 'Whole playlist' }; return 'Single video only' }
        'Section'        { if ($v) { return "$v" }; return 'Full video' }
        'RateLimit'      { if ($v) { return "$v per second" }; return 'Unlimited' }
        'CookiesBrowser' { if ($v) { return "$v" }; return 'None' }
        'RestrictNames'  { if ($v) { return 'ASCII only (safe)' }; return 'Keep original title' }
        'CookieFileMode' { if ($v -eq 'always') { return 'All links' }; if ($v -eq 'never') { return 'Never' }; return 'Only Patreon links' }
        'DownloadFolder' { return (Limit-Text ([string]$v) 44) }
        default {
            if ($v -is [bool]) { if ($v) { return 'Yes' }; return 'No' }
            return "$v"
        }
    }
}

function Apply-Def($d, $O) {
    switch ($d.Kind) {
        'cycle' {
            $vals = @($d.Vals)
            $idx = -1
            for ($n = 0; $n -lt $vals.Count; $n++) {
                if ("$($vals[$n])" -eq "$($O[$d.Field])") { $idx = $n }
            }
            $O[$d.Field] = $vals[($idx + 1) % $vals.Count]
        }
        'bool' {
            $O[$d.Field] = (-not [bool]$O[$d.Field])
        }
        'text' {
            Write-Host ''
            W ('  ' + $d.Prompt) 'Yellow'
            $v = (Read-Host '  New value').Trim().Trim('"')
            $bad = $false
            switch ($d.Field) {
                'DownloadFolder' {
                    if ($v) {
                        try {
                            if (-not (Test-Path -LiteralPath $v)) { New-Item -ItemType Directory -Path $v -Force -ErrorAction Stop | Out-Null }
                            $O['DownloadFolder'] = $v
                        } catch { $bad = $true }
                    }
                }
                'Section' {
                    if ($v -eq '' -or $v -match '^\d+(:\d+){0,2}(\.\d+)?-(\d+(:\d+){0,2}(\.\d+)?)?$') { $O['Section'] = $v } else { $bad = $true }
                }
                'Subtitles' {
                    if ($v -eq '' -or $v -match '^[A-Za-z][A-Za-z0-9,\-\.\*]*$') { $O['Subtitles'] = $v } else { $bad = $true }
                }
                'RateLimit' {
                    if ($v -eq '' -or $v -match '^\d+(\.\d+)?[KkMmGg]?$') { $O['RateLimit'] = $v } else { $bad = $true }
                }
                default { $O[$d.Field] = $v }
            }
            if ($bad) { W '  That value is not valid - nothing changed.' 'Red'; Start-Sleep -Seconds 1 }
        }
    }
    if ($d.Field -eq 'Unicode') { Set-Glyphs ([bool]$O['Unicode']) }
}

# ---------------------------------------------------------------------
# Options screen (per download) and Settings screen (defaults)
# ---------------------------------------------------------------------
function Show-Options($O, [bool]$IsSettings, $Meta) {
    $hint = ''
    while ($true) {
        $sub = 'Settings'
        if (-not $IsSettings) { $sub = 'Download options' }
        Show-Header $sub
        if ((-not $IsSettings) -and $null -ne $script:showMetaFlag) { Show-MetaPanel $Meta }

        $visible = @()
        $lastGroup = ''
        foreach ($d in $Defs) {
            if ($d.Scope -eq 'settings' -and -not $IsSettings) { continue }
            if ($d.Scope -eq 'download' -and $IsSettings) { continue }
            if ((-not $IsSettings) -and -not (& $d.Rel $O)) { continue }
            $visible += , $d
            if ($d.Group -ne $lastGroup) {
                W ''
                W ('  ' + $d.Group) 'Cyan'
                $lastGroup = $d.Group
            }
            Wn '   [' 'DarkGray'; Wn $d.Key 'Yellow'; Wn '] ' 'DarkGray'
            Wn ($d.Label.PadRight(24)) 'Gray'
            W (Format-Opt $d.Field $O) 'White'
        }

        W ''
        Write-Rule
        if ($IsSettings) {
            Wn '  [R] ' 'Yellow'; Wn 'Reset all     ' 'Gray'
            Wn '  [Enter/B] ' 'Yellow'; W 'Save and go back' 'Gray'
        } else {
            Wn '  [Enter] ' 'Green'; Wn 'START     ' 'White'
            Wn '[S] ' 'Yellow'; Wn 'Save these as defaults     ' 'Gray'
            Wn '[B] ' 'Yellow'; W 'Cancel' 'Gray'
        }
        if ($hint) { W ''; W ('  ' + $hint) 'DarkYellow' }

        $k = Read-Key
        if ($IsSettings) {
            if ($k -eq 'ENTER' -or $k -eq 'ESC' -or $k -eq 'B') { Save-Settings; return 'back' }
            if ($k -eq 'R') {
                W ''
                Wn '  Reset ALL settings to defaults? (Y/N) ' 'Yellow'
                $yn = Read-Key
                if ($yn -eq 'Y') {
                    $dd = Get-Defaults
                    foreach ($kk in @($dd.Keys)) { $O[$kk] = $dd[$kk] }
                    Set-Glyphs ([bool]$O['Unicode'])
                    $hint = 'Settings were reset.'
                }
                continue
            }
        } else {
            if ($k -eq 'ENTER') { return 'start' }
            if ($k -eq 'ESC' -or $k -eq 'B') { return 'back' }
            if ($k -eq 'S') {
                foreach ($kk in @($script:S.Keys)) { if ($O.Contains($kk)) { $script:S[$kk] = $O[$kk] } }
                Save-Settings
                $hint = 'Saved. These values are now the defaults.'
                continue
            }
        }
        $hit = $null
        foreach ($d in $visible) { if ($d.Key -eq $k) { $hit = $d } }
        if ($hit) {
            Apply-Def $hit $O
            $hint = $hit.Hint
        }
    }
}

# ---------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------
$HelpQuick = @'
## Quick start
- Start the program with YT-DLP Interface.bat. It creates its settings and the tools folder next to itself.
- Main menu: press 1, paste a link, press Enter.
- The program shows title, channel and length of the video.
- On the options screen press the key in [brackets] to change a value, e.g. 2 switches the resolution.
- Press Enter to start. Download and conversion each get a progress bar.
- Finished files are in the Downloads folder (change it in Settings, key F).
## Keys
- Menus react to a single key press. Enter is only needed after typing text.
- B or Esc goes one step back. Q quits from the main menu.
- Settings (main menu 3) are your defaults. On the download screen you can change values just for this download and press S to keep them as defaults.
'@

$HelpOptions = @'
## What to download
- Type: Video (MP4) or Audio only.
## Video options
- Resolution: upper limit. Best available takes the highest quality that exists (4K, 2K, ...).
- Encoding mode: see the topic Encoding modes and profiles.
- Keep original file: keeps the downloaded source (often WEBM/MKV) next to the MP4.
- Subtitles: language codes like en or de,en. Saved as .srt files next to the video.
## Audio options
- Format: MP3 (most compatible), M4A (AAC), OPUS (small and good), FLAC / WAV (lossless container, but the source is still lossy).
- Quality: Best, or a fixed bitrate (320K ... 128K) for smaller files.
## Extras
- Thumbnail: video = save cover as .jpg, audio = embed as cover art.
- Embed metadata: title, channel, date, chapters are written into the file.
- Cut sponsor parts: removes sponsor, self-promotion and interaction reminders (YouTube, SponsorBlock database).
- Playlist: download every video of a playlist.
- Time range: download only a part of a video.
## Program settings (Settings only)
- Encoder: auto / NVENC (NVIDIA) / AMD / CPU.
- Speed limit: e.g. 5M.
- Cookies from browser: for age restricted, private or members-only videos.
- cookies.txt usage: use the cookies.txt file only for Patreon links, for all links, or never.
- Safe file names: ASCII only, or keep the full title with special characters.
- Open folder / Sound: what happens after the download.
- Update yt-dlp on start, Fancy graphics.
'@

$HelpEncoding = @'
## Encoding modes
- Quality: downloads the best stream, then converts it to MP4 with ffmpeg. The settings depend on the REAL resolution of the file.
- Fast: prefers H.264 streams (YouTube has them up to 1080p) and only repacks them into MP4. Takes seconds, no quality loss. Without H.264 it re-encodes like Quality.
- Original: no conversion. You get the file as yt-dlp downloads it (often WEBM or MKV).
## Quality profiles
- up to 720p : H.264, quality 18, slow preset (p6)
- 1080p      : H.264, quality 19, preset p5
- above 1080p: HEVC (H.265), quality 23, preset p4
- 50 / 60 fps: quality value +2 (a bit smaller files)
- A lower quality number means a better picture and a bigger file.
- Vertical videos (Shorts) are rated by their shorter side.
## Encoders
- NVIDIA = NVENC, AMD = AMF, everything else = CPU (libx264 / libx265, slower).
- Auto tests your hardware at start. If a GPU encode fails, the program retries on the CPU.
- Audio that is already AAC is copied, everything else becomes AAC 192k.
!! HEVC files play on nearly every current device. Very old TVs may need H.264 (use Fast mode or max 1080p).
'@

$HelpBatch = @'
## Playlists
- Turn on Playlist (key P) and paste a playlist link. Every video goes into a sub folder named like the playlist, numbered 001_, 002_, ...
- Failed videos are skipped and listed at the end.
- A pure YouTube playlist link is detected automatically.
## Batch download
- Main menu 2: paste several links, or use links.txt (one link per line, lines starting with # are ignored).
- In the normal link prompt you can also paste several links separated by spaces.
- All links use the same options.
## Download and convert at the same time
- With several links the program does not wait for a conversion: while one video is converted to MP4, the next one is already downloading.
- The download bar then shows the converter at its end, e.g. | Convert #1 45%. Lines that start with [#1] belong to the conversion of item 1.
- One conversion runs at a time. If downloads are much faster than the converter, the program pauses downloading while 2 files wait, so the disk does not fill up with unconverted originals.
- Audio downloads and Original mode have no separate conversion step, they run one after the other.
## Time range
- Key T on the options screen: START-END, e.g. 1:30-2:45, or 10:00- for until the end.
- The progress bar may stay empty during a cut download. This is normal.
## Video info
- Before the options screen the program asks yt-dlp for title, channel, length and best resolution.
'@

$HelpFiles = @'
## Files in the program folder
- YT-DLP Interface.bat    the program (a single file, start it with a double click)
- settings.json          your saved defaults (delete it to reset everything)
- history.log             list of finished downloads (main menu 4)
- links.txt               links for batch mode (main menu 2)
- cookies.txt             optional login cookies (main menu C helps you create it)
- cookies.txt.bak         backup of the previous cookies.txt
- benchmark.json          cached hardware info and speed test result (Tools menu)
- tools\                  subfolder with yt-dlp.exe, ffmpeg.exe, ffprobe.exe, deno.exe (installed by the setup)
## File names
- Video: <title>.mp4     Audio: <title>.mp3 (or the chosen format)
- While converting, a temporary <title>_original.<ext> exists. It is deleted afterwards unless Keep original is on.
- Subtitles and thumbnails are saved next to the video with the same name.
'@

$HelpTrouble = @'
## Warning: No supported JavaScript runtime
- YouTube needs a JS runtime for some formats. Install deno once with:  winget install DenoLand.Deno   then restart the program. Tools -> System check shows if it is found.
## ffmpeg not found
- Run Tools -> Setup, it installs ffmpeg for you. Or put ffmpeg.exe and ffprobe.exe into the tools folder.
## Video not available / age restricted / members only
- Settings -> Cookies from browser: choose the browser where you are logged in. Firefox works best. For Chrome / Edge close the browser first.
- Main menu C (Cookies) explains how to get a cookies.txt and can export or import it for you.
## Patreon says you have no access
- Patreon needs your login cookies, also for posts you have unlocked. Without a cookies.txt the program warns you before the download and leads you to the Cookies menu.
- Get the file with main menu C: automatic export from your browser, or the add-on Get cookies.txt LOCALLY (Chrome, Edge, Brave) / cookies.txt (Firefox) and then Import.
## Errors 403 or 429
- Update yt-dlp (Tools -> Update), try again later, or set a speed limit.
## GPU encoding fails
- Update your graphics driver. The program falls back to the CPU automatically.
## Strange symbols instead of bars and boxes
- Settings -> Fancy graphics: switch to No.
## A download says it finished but the file is missing
- Check history.log and the Downloads folder. If a conversion failed, the _original file is kept.
'@

$HelpSetup = @'
## First-run setup
- On the very first start the program checks which tools are installed and offers to install the missing ones. You can install everything at once or choose one by one.
- yt-dlp.exe: downloaded from the official yt-dlp GitHub release into the tools folder.
- ffmpeg.exe and ffprobe.exe: the FFmpeg build of the yt-dlp project (about 190 MB), unpacked into the tools folder.
- deno.exe: the JavaScript runtime yt-dlp needs for full YouTube support. Downloaded from the official Deno release into the tools folder.
- Cookie plugin (ChromeCookieUnlock): optional. Lets yt-dlp read the cookies of Chrome, Edge or Brave while the browser is open. It is installed to %APPDATA%\yt-dlp\plugins. The plugin repository was archived by its author, so it may stop working one day. Firefox cookies need no plugin.
- PowerShell 7: optional, installed with winget. YT-DLP Interface.bat uses it automatically when it exists, otherwise Windows PowerShell 5.1.
- All tools go into the subfolder tools (next to the program). Tools found in the program folder from older versions still work, and the setup offers to move them into tools (also Tools -> 9).
- After the setup the check is NOT repeated at the next starts.
- To run it again: Settings -> Run setup on next start (key X), or Tools -> Setup.
- If a download says a tool is missing, the program offers the setup right there.
## PC check
- The main menu shows CPU, RAM, graphics card and free disk space, each with a rating for video conversion.
- CPU rating = number of threads x clock speed (a rough estimate).
- GPU rating is based on the generation of the card, but only if a GPU encoder (NVENC or AMF) really works on your PC.
- The Convert line shows an overall grade from A (excellent) to E (weak) for converting video. Press R in the main menu for the detailed PC rating: estimated speed and time for 720p, 1080p, 1440p, 4K, Fast mode and audio. It uses the speed test result if there is one, otherwise it estimates from your CPU and GPU. It can also apply the recommended default settings (resolution and mode) for you.
## Speed test (runs only once)
- The speed test encodes a synthetic 1080p clip with every available encoder and shows how many times faster than real time it runs. 4K is roughly four times slower.
- It runs automatically only on the very first start and when the hardware changes (CPU, number of cores, RAM or graphics card). Otherwise the cached result from benchmark.json is used, so starting the program stays fast.
- A new GPU driver or a new ffmpeg version only repeats the quick encoder check, not the speed test.
- Tools -> Hardware and speed test: shows the stored result, runs the test again on demand, re-detects the hardware, and switches the automatic test on or off (also Settings, key V).
- Real videos can be faster or slower than the test clip.
'@

$HelpCookiesIntro = @'
## What is cookies.txt?
- A text file with your login sessions. yt-dlp can use it for videos that need an account: age restricted, private, members only, Patreon and similar sites.
- Treat it like a password. Anyone who has the file can use your logged-in accounts. Never share it or upload it anywhere.
## Fastest way: let the program export it (not for YouTube)
- Main menu C -> [2] Export automatically. Pick the browser (Firefox works best). The program reads the cookies and saves cookies.txt in the program folder. Close Chrome, Edge or Brave completely first.
- The export contains the cookies of ALL sites in that browser. The program offers to keep only the sites you need, for example patreon.com. Do that, it is much safer.
- If Chrome or Edge fail, use Firefox or the manual way below.
## Manual way with a browser extension
- Install an export extension: Get cookies.txt LOCALLY (Chrome, Edge, Brave) or cookies.txt (Firefox). Both are linked on the official yt-dlp cookie guide (Cookies menu -> [5]). If you ever installed the old Get cookies.txt without LOCALLY, remove it.
- Log in to the website, stay on that site, click the extension and export. A file like www.example.com_cookies.txt lands in your Downloads folder.
- Main menu C -> [3] Import: the program finds the file in Downloads, checks it, saves it as cookies.txt in the program folder and can delete the original for you.
'@

$HelpCookiesYt = @'
## YouTube (special case)
- YouTube rotates the cookies of normal browser tabs all the time, so a normal export stops working quickly. Export from a private window instead:
- 1. Open a private / incognito window and log in to YouTube.
- 2. In the SAME tab open https://www.youtube.com/robots.txt. This must be the only private tab.
- 3. Export the cookies with the extension. The extension must be allowed in private windows (extension settings).
- 4. Close the private window right after the export and never open that session again.
- 5. Import the file with Cookies menu -> [3]. If you filter, keep youtube.com AND google.com.
- Cookies menu -> [4] opens the private window for you.
- Do not use the automatic browser export for YouTube. It misses the private session cookies and the result stops working soon.
- Use YouTube cookies only when you really need them (age restricted, private, members only). Reports say YouTube can restrict accounts or IPs when cookies are used heavily.
'@

$HelpCookiesUse = @'
## Using the file
- The program uses cookies.txt from its own folder. Settings -> cookies.txt usage (key C): Only Patreon links (default), All links, or Never.
- Settings -> Cookies from browser reads a browser live instead of a file. No export needed, but Chrome and Edge may fail while the browser is open.
- Cookies expire. If downloads fail again with a login message, export a fresh file. The Cookies menu shows how old your file is.
- The previous file is kept as cookies.txt.bak when you import a new one.
'@

$HelpCookies = ($HelpCookiesIntro, $HelpCookiesYt, $HelpCookiesUse) -join "`n"

function Show-Pages([string]$Text) {
    $h = 30
    try { $h = [Console]::WindowHeight } catch { }
    $page = [Math]::Max(10, $h - 3)
    $n = 0
    foreach ($l in ($Text -split '\r?\n')) {
        if ($l.StartsWith('## '))     { W ''; W ('  ' + $l.Substring(3)) 'Cyan'; $n += 2 }
        elseif ($l.StartsWith('- '))  { Wn '   - ' 'Yellow'; W $l.Substring(2) 'Gray'; $n++ }
        elseif ($l.StartsWith('!! ')) { W ''; W ('  ' + $l.Substring(3)) 'Yellow'; $n += 2 }
        else                          { W ('  ' + $l) 'Gray'; $n++ }
        if ($n -ge $page) { Wait-Key '  -- more: press any key --'; $n = 0 }
    }
}

function Menu-Help {
    while ($true) {
        Show-Header 'Help'
        W ''
        Write-Item '1' 'Quick start and keys'
        Write-Item '2' 'All options explained'
        Write-Item '3' 'Encoding modes and quality profiles'
        Write-Item '4' 'Playlists, batch download, time range'
        Write-Item '5' 'Files and folders'
        Write-Item '6' 'Troubleshooting'
        Write-Item '7' 'First-run setup, PC rating, speed test'
        Write-Item '8' 'Cookies: how to get cookies.txt'
        Write-Item 'A' 'Show everything'
        Write-Item 'B' 'Back'
        $k = Read-Key
        if ($k -eq 'B' -or $k -eq 'ESC') { return }
        $text = $null
        switch ($k) {
            '1' { $text = $HelpQuick }
            '2' { $text = $HelpOptions }
            '3' { $text = $HelpEncoding }
            '4' { $text = $HelpBatch }
            '5' { $text = $HelpFiles }
            '6' { $text = $HelpTrouble }
            '7' { $text = $HelpSetup }
            '8' { $text = $HelpCookies }
            'A' { $text = ($HelpQuick, $HelpOptions, $HelpEncoding, $HelpBatch, $HelpFiles, $HelpTrouble, $HelpSetup, $HelpCookies) -join "`n" }
        }
        if ($text) {
            Show-Header 'Help'
            Show-Pages $text
            Wait-Key '  End of topic. Press any key...'
        }
    }
}

# ---------------------------------------------------------------------
# History, Tools
# ---------------------------------------------------------------------
function Menu-History {
    while ($true) {
        Show-Header 'History'
        W ''
        $lines = @()
        if (Test-Path -LiteralPath $HistoryFile) { $lines = @(Get-Content -LiteralPath $HistoryFile -Encoding UTF8 | Select-Object -Last 18) }
        if ($lines.Count -eq 0) {
            W '  No downloads yet.' 'DarkGray'
        } else {
            foreach ($l in $lines) {
                $p = $l -split '\|', 5
                if ($p.Count -lt 5) { continue }
                $name = $p[3]
                if ($p[1] -eq 'OK') { $name = Split-Path -Leaf $p[3]; $col = 'Green' } else { $name = $p[4]; $col = 'Red' }
                Wn ('  ' + $p[0] + '  ') 'DarkGray'
                Wn ($p[1].PadRight(5)) $col
                Wn ($p[2].PadRight(6)) 'Gray'
                W (Limit-Text $name 44) 'White'
            }
        }
        W ''
        Write-Rule
        Wn '  [C] ' 'Yellow'; Wn 'Clear history    ' 'Gray'
        Wn '[B] ' 'Yellow'; W 'Back' 'Gray'
        $k = Read-Key
        if ($k -eq 'B' -or $k -eq 'ESC') { return }
        if ($k -eq 'C') { Remove-Item -LiteralPath $HistoryFile -Force -ErrorAction SilentlyContinue }
    }
}

function Show-SystemCheck {
    Show-Header 'System check'
    W ''
    W '  Detecting hardware...' 'DarkGray'
    Detect-Hardware
    Read-Versions
    $ok = 'Green'; $no = 'Yellow'
    W ''
    Wn '  yt-dlp        : ' 'DarkGray'; W ("{0}   ({1})" -f $script:VerYt, $ytdlp) 'White'
    Wn '  ffmpeg        : ' 'DarkGray'; if ($ffmpeg) { W ("{0}   ({1})" -f $script:VerFf, $ffmpeg) 'White' } else { W 'NOT FOUND' 'Red' }
    Wn '  ffprobe       : ' 'DarkGray'; if ($ffprobe) { W $ffprobe 'White' } else { W 'not found (progress % and auto profiles need it)' 'Yellow' }
    Wn '  Graphics card : ' 'DarkGray'; W (Limit-Text $script:GpuNames 54) 'White'
    Wn '  NVENC (NVIDIA): ' 'DarkGray'; if ($script:HasNv) { W 'works' $ok } else { W 'not available' $no }
    Wn '  AMF (AMD)     : ' 'DarkGray'; if ($script:HasAmd) { W 'works' $ok } else { W 'not available' $no }
    Wn '  Encoder used  : ' 'DarkGray'; W (Resolve-Encoder $script:S.Encoder) 'Cyan'
    $js = @('deno', 'node', 'bun') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    Wn '  JS runtime    : ' 'DarkGray'
    if ($js) { W $js $ok } else { W 'none found - install deno:  winget install DenoLand.Deno' $no }
    Wn '  cookies.txt   : ' 'DarkGray'; if (Test-Path -LiteralPath $CookieFile) { W 'found' $ok } else { W 'not present (only needed for Patreon)' 'DarkGray' }
    Wn '  Settings file : ' 'DarkGray'; W $SettingsFile 'Gray'
    Wait-Key
}

# ---------------------------------------------------------------------
# Cookies: guide, automatic export, import, filter
# ---------------------------------------------------------------------
function Get-CookieInfo([string]$Path) {
    $info = [pscustomobject]@{ Valid = $false; Count = 0; Expired = 0; Domains = @(); Age = -1 }
    if (-not (Test-Path -LiteralPath $Path)) { return $info }
    try {
        $item = Get-Item -LiteralPath $Path
        $span = [DateTime]::Now - $item.LastWriteTime
        $info.Age = [int][Math]::Floor($span.TotalDays)
        $now  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $doms = @{}
        foreach ($l in [IO.File]::ReadLines($Path)) {
            if (-not $l.Trim()) { continue }
            $line = $l
            if ($line.StartsWith('#HttpOnly_')) { $line = $line.Substring(10) }
            elseif ($line.StartsWith('#')) { continue }
            $p = $line.Split("`t")
            if ($p.Count -lt 7) { continue }
            $info.Count++
            $d = $p[0].TrimStart('.').ToLower()
            $parts = $d.Split('.')
            if ($parts.Count -ge 2) { $d = $parts[$parts.Count - 2] + '.' + $parts[$parts.Count - 1] }
            $doms[$d] = $true
            $exp = 0L
            if ([long]::TryParse($p[4], [ref]$exp)) { if ($exp -gt 0 -and $exp -lt $now) { $info.Expired++ } }
        }
        $info.Domains = @($doms.Keys | Sort-Object)
        $info.Valid = ($info.Count -gt 0)
    } catch { }
    return $info
}

function Filter-CookieFile([string]$Path, [string[]]$Domains) {
    $keep = New-Object System.Collections.Generic.List[string]
    $n = 0
    foreach ($l in [IO.File]::ReadLines($Path)) {
        if (-not $l.Trim()) { continue }
        $test = $l
        if ($test.StartsWith('#HttpOnly_')) { $test = $test.Substring(10) }
        elseif ($test.StartsWith('#')) { $keep.Add($l); continue }
        $p = $test.Split("`t")
        if ($p.Count -lt 7) { continue }
        $d = $p[0].TrimStart('.').ToLower()
        $hit = $false
        foreach ($f in $Domains) { if ($d -eq $f -or $d.EndsWith('.' + $f)) { $hit = $true } }
        if ($hit) { $keep.Add($l); $n++ }
    }
    if ($n -eq 0) { return 0 }
    if ($keep.Count -eq 0 -or $keep[0] -notmatch 'Netscape|HTTP Cookie File') { $keep.Insert(0, '# Netscape HTTP Cookie File') }
    [IO.File]::WriteAllLines($Path, $keep.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    return $n
}

function Offer-CookieFilter {
    W ''
    W '  The file may contain cookies of many sites. Keep only the sites you need?' 'Gray'
    W '  Example: patreon.com,instagram.com    (YouTube needs youtube.com AND google.com)' 'DarkGray'
    $v = (Read-Host '  Sites (Enter = keep everything)').Trim()
    if (-not $v) { return }
    $d = @($v -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { ($_.ToLower() -replace '^https?://', '' -replace '^www\.', '' -replace '/.*$', '') })
    if ($d.Count -eq 0) { return }
    try {
        $n = Filter-CookieFile $CookieFile $d
        if ($n -gt 0) { W ('  Kept {0} cookies for: {1}' -f $n, ($d -join ', ')) 'Green' }
        else { W '  No cookie matched those sites - the file was left unchanged.' 'Yellow' }
    } catch { W '  Filtering failed - the unfiltered file was kept.' 'Yellow' }
}

function Install-CookieFile([string]$Src, [bool]$DeleteSource) {
    $info = Get-CookieInfo $Src
    if (-not $info.Valid) {
        W '  That file is not a valid Netscape cookies.txt (no cookie lines found).' 'Red'
        return $false
    }
    try {
        if (Test-Path -LiteralPath $CookieFile) { Copy-Item -LiteralPath $CookieFile -Destination ($CookieFile + '.bak') -Force }
        Copy-Item -LiteralPath $Src -Destination $CookieFile -Force -ErrorAction Stop
    } catch {
        W ('  Could not write cookies.txt: ' + $_.Exception.Message) 'Red'
        return $false
    }
    if ($DeleteSource) { Remove-Item -LiteralPath $Src -Force -ErrorAction SilentlyContinue }
    Offer-CookieFilter
    $i2 = Get-CookieInfo $CookieFile
    W ''
    W ('  cookies.txt saved: {0} cookies for {1} sites.' -f $i2.Count, $i2.Domains.Count) 'Green'
    if ($DeleteSource) { W '  The source file was deleted.' 'DarkGray' }
    return $true
}

function Read-Browser([string]$Prompt) {
    W ''
    W ('  ' + $Prompt) 'Gray'
    Write-Item '1' 'Firefox (recommended)'
    Write-Item '2' 'Chrome'
    Write-Item '3' 'Edge'
    Write-Item '4' 'Brave'
    Write-Item 'B' 'Cancel'
    $k = Read-Key
    if ($k -eq '1') { return 'firefox' }
    if ($k -eq '2') { return 'chrome' }
    if ($k -eq '3') { return 'edge' }
    if ($k -eq '4') { return 'brave' }
    return $null
}

function Export-CookiesFromBrowser {
    if (-not $script:ytdlp) { W '  yt-dlp is not installed - run the setup first.' 'Red'; Wait-Key; return }
    $b = Read-Browser 'Read the cookies from which browser?'
    if (-not $b) { return }
    W ''
    W '  Close the browser completely first (Chrome, Edge, Brave).' 'Yellow'
    W '  This reads ALL cookies of the browser. You can filter them afterwards.' 'Yellow'
    W '  Not for YouTube - use [4] for that.' 'Yellow'
    Wn '  Continue? (Y/N) ' 'Yellow'
    $yn = Read-Key
    W ''
    if ($yn -ne 'Y') { return }
    $tmp = Join-Path $env:TEMP ('ytdlp_cookies_' + [guid]::NewGuid().ToString('N') + '.txt')
    W '  Reading cookies from the browser...' 'DarkGray'
    $msgs = @(& $script:ytdlp '--cookies-from-browser' $b '--cookies' $tmp '--simulate' '--no-warnings' '--ignore-errors' 'https://example.com/' 2>&1 | ForEach-Object { "$_" })
    $info = Get-CookieInfo $tmp
    if (-not $info.Valid) {
        W '  Could not read cookies from that browser.' 'Red'
        foreach ($m in @($msgs | Where-Object { $_ -match 'ERROR|ookie' } | Select-Object -First 4)) { W ('  ' + (Limit-Text $m 90)) 'DarkGray' }
        W '  Tips: close the browser completely, try Firefox, or install the cookie plugin (Tools -> Setup).' 'Yellow'
        W '  Or use the manual way: [1] Guide.' 'Yellow'
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Wait-Key
        return
    }
    W ('  Found {0} cookies for {1} sites.' -f $info.Count, $info.Domains.Count) 'Green'
    $null = Install-CookieFile $tmp $true
    Wait-Key
}

function Import-CookiesFromDownloads {
    $dl = Join-Path $env:USERPROFILE 'Downloads'
    $c = @()
    if (Test-Path -LiteralPath $dl) {
        $c = @(Get-ChildItem -LiteralPath $dl -File -Filter '*.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'cookie' -and $_.LastWriteTime -gt (Get-Date).AddDays(-14) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    }
    W ''
    if ($c.Count -eq 0) {
        W ('  No cookies .txt file found in {0} (last 14 days).' -f $dl) 'Yellow'
    } else {
        W '  Found in your Downloads folder:' 'Gray'
        $i = 0
        foreach ($f in $c) {
            $i++
            $ci = Get-CookieInfo $f.FullName
            $txt = 'not a cookies file'
            if ($ci.Valid) { $txt = '{0} cookies' -f $ci.Count }
            Wn ('   [{0}] ' -f $i) 'Yellow'
            Wn ((Limit-Text $f.Name 38).PadRight(40)) 'White'
            W ('{0:yyyy-MM-dd HH:mm}  {1}' -f $f.LastWriteTime, $txt) 'DarkGray'
        }
    }
    Write-Item 'P' 'Type the path of a cookies file'
    Write-Item 'B' 'Back'
    $k = Read-Key
    $src = $null
    if ($k -match '^[1-5]$' -and ([int]$k) -le $c.Count) { $src = $c[[int]$k - 1].FullName }
    elseif ($k -eq 'P') {
        W ''
        $src = (Read-Host '  Full path of the cookies file').Trim().Trim('"')
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { W '  File not found.' 'Red'; Wait-Key; return }
    } else { return }
    $del = $false
    if ($src -like ($dl + '\*')) {
        W ''
        Wn '  Delete the original in Downloads after importing? Recommended (Y/N) ' 'Yellow'
        $yn = Read-Key
        W ''
        if ($yn -eq 'Y') { $del = $true }
    }
    $null = Install-CookieFile $src $del
    Wait-Key
}

function Start-YouTubeCookieGuide {
    Show-Header 'YouTube cookies'
    Show-Pages $HelpCookiesYt
    $b = Read-Browser 'Open a private window with YouTube now?'
    if (-not $b) { return }
    $url = 'https://www.youtube.com/'
    try {
        if ($b -eq 'firefox') { Start-Process firefox -ArgumentList '-private-window', $url }
        elseif ($b -eq 'chrome') { Start-Process chrome -ArgumentList '--incognito', $url }
        elseif ($b -eq 'edge') { Start-Process msedge -ArgumentList '-inprivate', $url }
        else { Start-Process brave -ArgumentList '--incognito', $url }
        W ''
        W '  Private window opened. Follow the steps above, then come back and use [3] Import.' 'Green'
    } catch {
        W ''
        W '  Could not start the browser. Open a private window yourself and follow the steps.' 'Yellow'
    }
    Wait-Key
}

function Menu-Cookies {
    while ($true) {
        Show-Header 'Cookies'
        $info = Get-CookieInfo $CookieFile
        W ''
        Wn '  cookies.txt   : ' 'DarkGray'
        if ($info.Valid) {
            $col = 'Green'
            if ($info.Age -gt 30) { $col = 'Yellow' }
            W ('found - {0} cookies, {1} sites, saved {2} day(s) ago' -f $info.Count, $info.Domains.Count, $info.Age) $col
            if ($info.Domains.Count -gt 0) { W ('                  ' + (Limit-Text ($info.Domains -join ', ') 52)) 'DarkGray' }
            if ($info.Expired -gt 0) { W ('                  {0} cookie(s) already expired' -f $info.Expired) 'Yellow' }
        } else {
            W 'not found' 'Yellow'
        }
        Wn '  Used for      : ' 'DarkGray'; W (Format-Opt 'CookieFileMode' $script:S) 'Gray'
        Wn '  Browser mode  : ' 'DarkGray'; W (Format-Opt 'CookiesBrowser' $script:S) 'Gray'
        W ''
        W '  cookies.txt works like a password for your accounts - never share it.' 'Yellow'
        W ''
        Write-Item '1' 'Guide: how do I get a cookies.txt?'
        Write-Item '2' 'Export automatically from my browser (not for YouTube)'
        Write-Item '3' 'Import a cookies.txt from my Downloads folder'
        Write-Item '4' 'Guided YouTube export (opens a private window)'
        Write-Item '5' 'Open the official yt-dlp cookie guide in the browser'
        Write-Item '6' 'Delete cookies.txt'
        Write-Item 'B' 'Back'
        $k = Read-Key
        if ($k -eq 'B' -or $k -eq 'ESC') { return }
        if ($k -eq '1') { Show-Header 'Cookies guide'; Show-Pages $HelpCookies; Wait-Key }
        if ($k -eq '2') { Export-CookiesFromBrowser }
        if ($k -eq '3') { Import-CookiesFromDownloads }
        if ($k -eq '4') { Start-YouTubeCookieGuide }
        if ($k -eq '5') {
            try { Start-Process 'https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp' } catch { }
        }
        if ($k -eq '6' -and (Test-Path -LiteralPath $CookieFile)) {
            W ''
            Wn '  Delete cookies.txt? (Y/N) ' 'Yellow'
            $yn = Read-Key
            if ($yn -eq 'Y') { Remove-Item -LiteralPath $CookieFile -Force -ErrorAction SilentlyContinue }
        }
    }
}

# ---------------------------------------------------------------------
# PC rating for converting video / audio
# ---------------------------------------------------------------------
function Get-BenchX([string]$Group, [string]$Codec) {
    $b = $script:Bench
    if ($b -and ($b.HwFp -eq $script:HwFp) -and $b.Results) {
        $m = @($b.Results) | Where-Object { $_.Group -eq $Group -and $_.Codec -eq $Codec } | Select-Object -First 1
        if ($m) { return [double]$m.X }
    }
    return 0.0
}

function Get-SpeedGrade([double]$x) {
    if ($x -ge 4)   { return @('Excellent', 'Green') }
    if ($x -ge 1.5) { return @('Good', 'Green') }
    if ($x -ge 0.8) { return @('OK', 'Yellow') }
    if ($x -ge 0.3) { return @('Slow', 'Yellow') }
    return @('Very slow', 'Red')
}

function Format-Minutes([double]$Min) {
    if ($Min -lt 0.1) { return '< 6 s' }
    if ($Min -lt 1)   { return ('~{0:N0} s' -f ($Min * 60)) }
    if ($Min -lt 120) { return ('~{0:N0} min' -f $Min) }
    return ('~{0:N1} h' -f ($Min / 60))
}

function Get-ConvertReport {
    $sp = $script:Spec
    $r  = $script:Rating
    if (-not $sp -or -not $r) { return $null }
    $enc = Resolve-Encoder $script:S.Encoder
    $group = 'CPU'
    if ($enc -eq 'NVENC') { $group = 'NVENC' } elseif ($enc -eq 'AMD') { $group = 'AMD' }

    $x264 = Get-BenchX $group 'H.264'
    $x265 = Get-BenchX $group 'HEVC'
    $measured = ($x264 -gt 0 -and $x265 -gt 0)
    if ($x264 -le 0 -or $x265 -le 0) {
        $score = $sp.Threads * $sp.GHz
        if ($group -eq 'NVENC') {
            if ($r.GpuR -eq 'Excellent') { $e264 = 12.0; $e265 = 10.0 }
            elseif ($r.GpuR -eq 'Very good') { $e264 = 9.0; $e265 = 7.0 }
            else { $e264 = 6.0; $e265 = 5.0 }
        } elseif ($group -eq 'AMD') {
            if ($r.GpuR -eq 'Very good') { $e264 = 7.0; $e265 = 6.0 }
            elseif ($r.GpuR -eq 'Good') { $e264 = 5.0; $e265 = 4.0 }
            else { $e264 = 3.0; $e265 = 2.5 }
        } else {
            $e264 = [Math]::Max(0.2, $score / 12.0)
            $e265 = $e264 / 3.5
        }
        if ($x264 -le 0) { $x264 = $e264 }
        if ($x265 -le 0) { $x265 = $e265 }
    }

    $mul720 = 2.25
    if ($group -ne 'CPU') { $mul720 = 1.6 }
    $rows = @(
        [pscustomobject]@{ Task = '720p  to MP4 (H.264)'; X = ($x264 * $mul720) },
        [pscustomobject]@{ Task = '1080p to MP4 (H.264)'; X = $x264 },
        [pscustomobject]@{ Task = '1440p to MP4 (HEVC)';  X = ($x265 / 1.78) },
        [pscustomobject]@{ Task = '4K    to MP4 (HEVC)';  X = ($x265 / 4.0) }
    )
    $x4k = $x265 / 4.0

    if ($x264 -ge 6 -and $x4k -ge 1.5) {
        $grade = 'A'; $label = 'Excellent'; $col = 'Green'; $res = 0; $mode = 'quality'
        $adv = 'Everything runs fast. Use Quality mode at any resolution, even 4K.'
    } elseif ($x264 -ge 3 -and $x4k -ge 0.7) {
        $grade = 'B'; $label = 'Very good'; $col = 'Green'; $res = 0; $mode = 'quality'
        $adv = 'All resolutions work. 4K takes a while, Fast mode saves time when you do not need a re-encode.'
    } elseif ($x264 -ge 1.5) {
        $grade = 'C'; $label = 'Good'; $col = 'Yellow'; $res = 1080; $mode = 'quality'
        $adv = 'Quality mode is fine up to 1080p. For 1440p and 4K prefer Fast or Original mode.'
    } elseif ($x264 -ge 0.8) {
        $grade = 'D'; $label = 'Limited'; $col = 'Yellow'; $res = 1080; $mode = 'fast'
        $adv = 'Prefer Fast mode (no re-encode). Use Quality mode only for short clips.'
    } else {
        $grade = 'E'; $label = 'Weak'; $col = 'Red'; $res = 720; $mode = 'fast'
        $adv = 'Re-encoding is slow on this PC. Use Fast or Original mode and limit the resolution.'
    }
    if ($sp.RamGB -gt 0 -and $sp.RamGB -lt 8) { $adv += ' Low RAM: avoid 4K re-encoding.' }

    $date = ''
    if ($measured -and $script:Bench.BenchDate) { $date = ([string]$script:Bench.BenchDate).Split(' ')[0] }
    return [pscustomobject]@{ Grade = $grade; Label = $label; Color = $col; Rows = $rows; Measured = $measured; Date = $date
                              Group = $group; Enc = $enc; Advice = $adv; RecRes = $res; RecMode = $mode }
}

function Show-PcRating {
    $msg = ''
    while ($true) {
        Show-Header 'PC rating'
        $sp = $script:Spec
        $r  = $script:Rating
        $rep = Get-ConvertReport
        if (-not $rep) { W ''; W '  No hardware data yet.' 'Yellow'; Wait-Key; return }
        W ''
        W '  Components' 'Cyan'
        $t = Limit-Text ('{0}  ({1}C/{2}T, {3:N1} GHz)' -f $sp.Cpu, $sp.Cores, $sp.Threads, $sp.GHz) 50
        Wn '   CPU   ' 'DarkGray'; Wn ($t.PadRight(52)) 'Gray'; W $r.CpuR $r.CpuC
        $g = 'none detected'
        if ($sp.Gpus.Count -gt 0) { $g = [string]$sp.Gpus[0] }
        if ($r.GpuTech) { $g = "$g ($($r.GpuTech))" }
        $t = Limit-Text $g 50
        Wn '   GPU   ' 'DarkGray'; Wn ($t.PadRight(52)) 'Gray'; W $r.GpuR $r.GpuC
        $t = '{0} GB' -f $sp.RamGB
        Wn '   RAM   ' 'DarkGray'; Wn ($t.PadRight(52)) 'Gray'; W $r.RamR $r.RamC
        W ''
        Wn '  Overall grade for converting video:  ' 'Gray'
        W ('{0} - {1}' -f $rep.Grade, $rep.Label) $rep.Color
        if ($rep.Measured) { W ('  Based on the speed test of {0}.  Encoder in use: {1}' -f $rep.Date, $rep.Enc) 'DarkGray' }
        else { W ('  Estimated from your hardware (run the speed test for exact numbers).  Encoder in use: {0}' -f $rep.Enc) 'DarkGray' }
        W ''
        W ('  ' + 'Task'.PadRight(24) + 'Speed'.PadRight(10) + 'Rating'.PadRight(11) + '10-minute video') 'DarkGray'
        Write-Rule
        foreach ($row in $rep.Rows) {
            $gr = Get-SpeedGrade $row.X
            Wn ('  ' + $row.Task.PadRight(24)) 'Gray'
            Wn (('{0:N1}x' -f $row.X).PadRight(10)) 'White'
            Wn ($gr[0].PadRight(11)) $gr[1]
            W (Format-Minutes (10.0 / [Math]::Max(0.01, $row.X))) 'DarkGray'
        }
        Wn ('  ' + 'Fast mode (copy H.264)'.PadRight(24)) 'Gray'; Wn ('instant'.PadRight(10)) 'White'; Wn ('Excellent'.PadRight(11)) 'Green'; W '< 10 s' 'DarkGray'
        Wn ('  ' + 'Audio (MP3, M4A, FLAC)'.PadRight(24)) 'Gray'; Wn ('very fast'.PadRight(10)) 'White'; Wn ('Excellent'.PadRight(11)) 'Green'; W '< 30 s' 'DarkGray'
        W ''
        Write-Wrapped '  Advice  ' $rep.Advice 60 'White'
        W ''
        Write-Rule
        $resText = 'best available'
        if ($rep.RecRes -gt 0) { $resText = ('max. {0}p' -f $rep.RecRes) }
        Wn '  [A] ' 'Yellow'; W ('Apply recommended defaults ({0}, {1} mode)' -f $resText, $rep.RecMode) 'Gray'
        Write-Item 'T' 'Run the speed test for exact numbers'
        Write-Item 'B' 'Back'
        if ($msg) { W ''; W ('  ' + $msg) 'Green' }
        $k = Read-Key
        if ($k -eq 'B' -or $k -eq 'ESC') { return }
        if ($k -eq 'A') {
            $script:S['Resolution'] = $rep.RecRes
            $script:S['Mode'] = $rep.RecMode
            Save-Settings
            $msg = 'Saved. New downloads now start with these defaults.'
        }
        if ($k -eq 'T') { Run-Benchmark; $msg = '' }
    }
}

function Write-BenchSpeed([string]$Codec, [double]$x) {
    $col = 'Red'
    if ($x -ge 1.5) { $col = 'Green' } elseif ($x -ge 0.9) { $col = 'Yellow' }
    $extra = ''
    if ($Codec -eq 'HEVC') { $extra = ('   (4K roughly {0:N1}x)' -f ($x / 4)) }
    W ('{0,6:N1}x real time  - {1}{2}' -f $x, (Get-SpeedWord $x), $extra) $col
}

function Show-BenchResults($b) {
    foreach ($r in @($b.Results)) {
        $label = '{0} {1}' -f $r.Group, $r.Codec
        Wn ('   ' + $label.PadRight(16)) 'Gray'
        Write-BenchSpeed $r.Codec ([double]$r.X)
    }
}

function Menu-Speed {
    while ($true) {
        Show-Header 'Hardware and speed test'
        $b = $script:Bench
        W ''
        if ($b -and $b.BenchDate) {
            W ('  Last speed test : {0}' -f $b.BenchDate) 'White'
            W ('  Tested on       : {0}' -f (Limit-Text ([string]$b.Cpu) 50)) 'DarkGray'
            W ''
            Show-BenchResults $b
        } else {
            W '  No speed test result stored yet.' 'Yellow'
        }
        W ''
        $nv = 'no'; if ($script:HasNv) { $nv = 'yes' }
        $am = 'no'; if ($script:HasAmd) { $am = 'yes' }
        W ('  GPU encoders    : NVENC {0}, AMD AMF {1}   (cached, tested again after a driver or ffmpeg change)' -f $nv, $am) 'DarkGray'
        $auto = 'Off'; if ($script:S.AutoBenchmark) { $auto = 'On' }
        W ('  Auto speed test : {0}   (runs only on the first start and when the hardware changes)' -f $auto) 'DarkGray'
        W ''
        Write-Rule
        Write-Item '1' 'Run the speed test again now'
        Write-Item '2' 'Re-detect hardware and encoders (no speed test unless the hardware changed)'
        Write-Item '3' 'Switch the automatic speed test on or off'
        Write-Item 'B' 'Back'
        $k = Read-Key
        if ($k -eq 'B' -or $k -eq 'ESC') { return }
        if ($k -eq '1') { Run-Benchmark }
        if ($k -eq '2') { Show-Header 'Hardware and speed test'; W ''; Detect-Hardware -Force; Wait-Key }
        if ($k -eq '3') { $script:S['AutoBenchmark'] = (-not [bool]$script:S.AutoBenchmark); Save-Settings }
    }
}

function Menu-Tools {
    while ($true) {
        Show-Header 'Tools'
        W ''
        Write-Item '1' 'Update yt-dlp now'
        Write-Item '2' 'System check (tools, GPU encoders, JS runtime)'
        Write-Item '3' 'Open download folder'
        Write-Item '4' 'Open program folder'
        Write-Item '5' 'Setup (install or repair yt-dlp, ffmpeg, deno, plugins)'
        Write-Item '6' 'Hardware and speed test (cached results, run again)'
        Write-Item '7' 'Cookies (guide, automatic export, import)'
        Write-Item '8' 'PC rating for converting video and audio'
        Write-Item '9' 'Move tools from the program folder into the tools folder'
        Write-Item 'B' 'Back'
        $k = Read-Key
        if ($k -eq 'B' -or $k -eq 'ESC') { return }
        if ($k -eq '1') {
            W ''
            if ($ytdlp) { & $ytdlp -U } else { W '  yt-dlp is not installed - use Setup (key 5).' 'Yellow' }
            Read-Versions
            Wait-Key
        }
        if ($k -eq '2') { Show-SystemCheck }
        if ($k -eq '3') {
            $f = [string]$script:S.DownloadFolder
            if (-not (Test-Path -LiteralPath $f)) { New-Item -ItemType Directory -Path $f -Force | Out-Null }
            Start-Process explorer.exe $f
        }
        if ($k -eq '4') { Start-Process explorer.exe $Root }
        if ($k -eq '5') {
            Invoke-Setup
            Refresh-Tools
            Read-Versions
            Detect-Hardware
        }
        if ($k -eq '6') { Menu-Speed }
        if ($k -eq '7') { Menu-Cookies }
        if ($k -eq '8') { Show-PcRating }
        if ($k -eq '9') {
            if (-not (Move-ToolsToFolder $true)) { W '  Nothing was moved.' 'DarkGray'; Start-Sleep -Seconds 1 }
            Read-Versions
        }
    }
}

# ---------------------------------------------------------------------
# Setup: download helpers and installers
# ---------------------------------------------------------------------
function Download-File([string]$Url, [string]$Dest, [string]$Label) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $resp = $null; $in = $null; $out = $null
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = 'ytdlp-downloader-setup'
        $req.AllowAutoRedirect = $true
        $resp  = $req.GetResponse()
        $total = [double]$resp.ContentLength
        $in    = $resp.GetResponseStream()
        $out   = [IO.File]::Create($Dest)
        $buf   = New-Object byte[] 81920
        $got   = 0.0
        $sw    = [Diagnostics.Stopwatch]::StartNew()
        $last  = 0
        while ($true) {
            $n = $in.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $out.Write($buf, 0, $n)
            $got += $n
            if (($sw.ElapsedMilliseconds - $last) -ge 150) {
                $last  = $sw.ElapsedMilliseconds
                $speed = ($got / 1MB) / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds)
                if ($total -gt 0) {
                    Show-Progress $Label (($got / $total) * 100) ('{0:N1} / {1:N1} MB   {2:N1} MB/s' -f ($got / 1MB), ($total / 1MB), $speed)
                } else {
                    Show-Progress $Label 0 ('{0:N1} MB   {1:N1} MB/s' -f ($got / 1MB), $speed)
                }
            }
        }
        if ($total -gt 0) { Show-Progress $Label 100 ('{0:N1} MB  done' -f ($got / 1MB)) }
        End-Progress
        return $true
    } catch {
        Hide-Progress
        W ('  Download failed: ' + $_.Exception.Message) 'Red'
        return $false
    } finally {
        if ($out)  { $out.Close() }
        if ($in)   { $in.Close() }
        if ($resp) { $resp.Close() }
    }
}

# Replaces $Dest with $Src. A plain overwrite is denied by Windows when $Dest is hidden or read-only.
function Move-OverFile([string]$Src, [string]$Dest) {
    $hidden = $false
    if ([IO.File]::Exists($Dest)) {
        $attr = [IO.File]::GetAttributes($Dest)
        $hidden = [bool]($attr -band [IO.FileAttributes]::Hidden)
        [IO.File]::SetAttributes($Dest, [IO.FileAttributes]::Normal)
        try { [IO.File]::Delete($Dest) } catch { [IO.File]::SetAttributes($Dest, $attr); throw }
    }
    [IO.File]::Move($Src, $Dest)
    if ($hidden) { [IO.File]::SetAttributes($Dest, ([IO.File]::GetAttributes($Dest) -bor [IO.FileAttributes]::Hidden)) }
}

function Expand-ZipPick([string]$Zip, [hashtable]$Map) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    $count = 0
    try {
        foreach ($e in $z.Entries) {
            foreach ($pat in @($Map.Keys)) {
                if ($e.FullName -like $pat) {
                    $target = $Map[$pat]
                    $tmp = $target + '.download'
                    try {
                        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $tmp, $true)
                        Move-OverFile $tmp $target
                        $count++
                    } catch {
                        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                        # an existing file that cannot be replaced (in use) must not stop the other files
                        if (-not (Test-Path -LiteralPath $target)) { throw }
                        W ('  Kept the existing ' + (Split-Path -Leaf $target) + ' - it could not be replaced.') 'Yellow'
                        $count++
                    }
                }
            }
        }
    } finally { $z.Dispose() }
    return $count
}

function Expand-ZipSubtree([string]$Zip, [string]$Marker, [string]$DestRoot) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    $count = 0
    try {
        foreach ($e in $z.Entries) {
            $name = $e.FullName
            $idx = $name.IndexOf($Marker)
            if ($idx -lt 0) { continue }
            $rel = $name.Substring($idx + $Marker.Length)
            if ($rel -eq '' -or $rel.EndsWith('/')) { continue }
            $target = Join-Path $DestRoot ($rel -replace '/', '\')
            $dir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            $count++
        }
    } finally { $z.Dispose() }
    return $count
}

function Test-DirWritable([string]$Dir) {
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { return $false }
        $t = Join-Path $Dir ('.write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($t, 'x')
        Remove-Item -LiteralPath $t -Force
        return $true
    } catch { return $false }
}

# All downloaded tools (yt-dlp, ffmpeg, ffprobe, deno) go into the "tools" subfolder.
# Falls back to another writable folder only if "tools" cannot be created or written.
function Get-ToolDir {
    try {
        if (-not (Test-Path -LiteralPath $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force -ErrorAction Stop | Out-Null }
        if (Test-DirWritable $ToolsDir) { return $ToolsDir }
    } catch { }
    if ($script:ytdlp) {
        $d = Split-Path -Parent $script:ytdlp
        if ($d -and (Test-DirWritable $d)) { return $d }
    }
    return $Root
}

function Add-ToPath([string]$Dir) {
    if (($env:PATH -split ';') -notcontains $Dir) { $env:PATH = "$Dir;$env:PATH" }
}

function Get-LegacyTools {
    $found = @()
    foreach ($n in @('yt-dlp', 'ffmpeg', 'ffprobe', 'deno')) {
        $old = Join-Path $Root "$n.exe"
        $new = Join-Path $ToolsDir "$n.exe"
        if ((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $new)) { $found += $old }
    }
    return $found
}

function Move-ToolsToFolder([bool]$Ask = $true) {
    $old = @(Get-LegacyTools)
    if ($old.Count -eq 0) { return $false }
    if ($Ask) {
        W ''
        W '  Found tools in the program folder:' 'Gray'
        foreach ($f in $old) { W ('   - ' + (Split-Path -Leaf $f)) 'White' }
        Wn '  Move them into the "tools" subfolder? (Y/N) ' 'Yellow'
        $k = Read-Key
        W ''
        if ($k -ne 'Y') { return $false }
    }
    try { New-Item -ItemType Directory -Path $ToolsDir -Force -ErrorAction Stop | Out-Null }
    catch { W '  Could not create the tools folder.' 'Red'; return $false }
    foreach ($f in $old) {
        $leaf = Split-Path -Leaf $f
        try { Move-Item -LiteralPath $f -Destination $ToolsDir -Force -ErrorAction Stop; W ('  Moved ' + $leaf) 'Green' }
        catch { W ('  Could not move ' + $leaf + ': ' + $_.Exception.Message) 'Yellow' }
    }
    Refresh-Tools
    return $true
}

function Install-YtDlp {
    $dir  = Get-ToolDir
    $dest = Join-Path $dir 'yt-dlp.exe'
    $tmp  = $dest + '.download'
    W '  Downloading yt-dlp.exe from the official GitHub release...' 'White'
    if (-not (Download-File 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' $tmp 'yt-dlp')) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
    try { Move-OverFile $tmp $dest }
    catch {
        W ('  Could not save the file: ' + $_.Exception.Message) 'Red'
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
    W ('  yt-dlp installed in ' + $dir) 'Green'
    Add-ToPath $dir
    return $true
}

function Install-Ffmpeg {
    $arch = 'win64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'winarm64' }
    $url = "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-${arch}-gpl.zip"
    $zip = Join-Path $env:TEMP 'ytdlp-ffmpeg-build.zip'
    W '  Downloading ffmpeg (about 190 MB, yt-dlp FFmpeg build)...' 'White'
    if (-not (Download-File $url $zip 'ffmpeg')) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        return $false
    }
    W '  Extracting ffmpeg.exe and ffprobe.exe...' 'White'
    $n = 0
    try {
        $dir = Get-ToolDir
        $map = @{ '*/bin/ffmpeg.exe' = (Join-Path $dir 'ffmpeg.exe'); '*/bin/ffprobe.exe' = (Join-Path $dir 'ffprobe.exe') }
        $n = Expand-ZipPick $zip $map
    } catch {
        W ('  Extraction failed: ' + $_.Exception.Message) 'Red'
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        return $false
    }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    if ($n -lt 1) { W '  The archive did not contain ffmpeg.exe.' 'Red'; return $false }
    W ('  ffmpeg installed in ' + $dir) 'Green'
    Add-ToPath $dir
    return $true
}

function Install-Deno {
    $arch = 'x86_64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'aarch64' }
    $url = "https://github.com/denoland/deno/releases/latest/download/deno-${arch}-pc-windows-msvc.zip"
    $zip = Join-Path $env:TEMP 'ytdlp-deno.zip'
    W '  Downloading deno (JavaScript runtime) from the official release...' 'White'
    if (-not (Download-File $url $zip 'deno')) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        return $false
    }
    $n = 0
    $dir = Get-ToolDir
    try { $n = Expand-ZipPick $zip @{ 'deno.exe' = (Join-Path $dir 'deno.exe') } }
    catch { W ('  Extraction failed: ' + $_.Exception.Message) 'Red' }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    if ($n -lt 1) { W '  deno.exe was not found in the archive.' 'Red'; return $false }
    W ('  deno installed in ' + $dir + ' (used automatically by yt-dlp).') 'Green'
    Add-ToPath $dir
    return $true
}

function Install-CookiePlugin {
    $url  = 'https://github.com/seproDev/yt-dlp-ChromeCookieUnlock/archive/refs/tags/v2024.04.29.zip'
    $zip  = Join-Path $env:TEMP 'ytdlp-cookieunlock.zip'
    $dest = Join-Path $env:APPDATA 'yt-dlp\plugins\yt-dlp-ChromeCookieUnlock\yt_dlp_plugins'
    W '  Downloading the ChromeCookieUnlock plugin...' 'White'
    if (-not (Download-File $url $zip 'plugin')) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        return $false
    }
    $n = 0
    try {
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        $n = Expand-ZipSubtree $zip '/yt_dlp_plugins/' $dest
    } catch { W ('  Installation failed: ' + $_.Exception.Message) 'Red' }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    if ($n -lt 1) { W '  The plugin files were not found in the archive.' 'Red'; return $false }
    W '  Plugin installed to %APPDATA%\yt-dlp\plugins' 'Green'
    return $true
}

function Test-Pwsh {
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { return $true }
    return (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))
}

function Test-CookiePlugin {
    if (Test-Path -LiteralPath (Join-Path $env:APPDATA 'yt-dlp\plugins\yt-dlp-ChromeCookieUnlock')) { return $true }
    $b = Join-Path $Root 'yt-dlp-plugins'
    if (Test-Path -LiteralPath $b) {
        return [bool](Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*ChromeCookieUnlock*' })
    }
    return $false
}

function Install-Pwsh {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        W '  winget was not found on this PC.' 'Yellow'
        W '  Install PowerShell 7 manually: https://aka.ms/powershell-release?tag=stable' 'Yellow'
        return $false
    }
    W '  Installing PowerShell 7 with winget (a Windows permission prompt may appear)...' 'White'
    & winget install --id Microsoft.PowerShell -e --accept-source-agreements --accept-package-agreements | Out-Host
    if (Test-Pwsh) {
        W '  PowerShell 7 installed. YT-DLP Interface.bat will use it from the next start.' 'Green'
        return $true
    }
    W '  PowerShell 7 does not seem to be installed.' 'Yellow'
    return $false
}

function Get-SetupItems {
    $deno = Find-Tool 'deno'
    $items = @()
    $items += [pscustomobject]@{ Name = 'yt-dlp';  Group = 'ytdlp';  Ok = [bool]$script:ytdlp;   Level = 'required';    Why = 'the downloader itself';                     Install = { Install-YtDlp } }
    $items += [pscustomobject]@{ Name = 'ffmpeg';  Group = 'ffmpeg'; Ok = [bool]$script:ffmpeg;  Level = 'required';    Why = 'merges and converts video and audio';       Install = { Install-Ffmpeg } }
    $items += [pscustomobject]@{ Name = 'ffprobe'; Group = 'ffmpeg'; Ok = [bool]$script:ffprobe; Level = 'recommended'; Why = 'progress percent and automatic profiles'; Install = { Install-Ffmpeg } }
    $items += [pscustomobject]@{ Name = 'deno';    Group = 'deno';   Ok = [bool]$deno;           Level = 'recommended'; Why = 'JavaScript runtime for full YouTube support'; Install = { Install-Deno } }
    $items += [pscustomobject]@{ Name = 'Cookie plugin'; Group = 'cookie'; Ok = (Test-CookiePlugin); Level = 'optional'; Why = 'Chrome/Edge cookies while the browser is open'; Install = { Install-CookiePlugin } }
    $items += [pscustomobject]@{ Name = 'PowerShell 7'; Group = 'pwsh'; Ok = (Test-Pwsh); Level = 'optional'; Why = 'newer shell, used by YT-DLP Interface.bat if present'; Install = { Install-Pwsh } }
    return $items
}

function Show-SetupTable($items) {
    W ''
    W ('  ' + 'Component'.PadRight(15) + 'Status'.PadRight(10) + 'Purpose') 'DarkGray'
    Write-Rule
    foreach ($it in $items) {
        Wn ('  ' + $it.Name.PadRight(15)) 'White'
        if ($it.Ok) { Wn ('OK'.PadRight(10)) 'Green' }
        elseif ($it.Level -eq 'required') { Wn ('MISSING'.PadRight(10)) 'Red' }
        else { Wn ('missing'.PadRight(10)) 'Yellow' }
        Wn (Limit-Text $it.Why 44) 'Gray'
        W (' [' + $it.Level + ']') 'DarkGray'
    }
}

function Invoke-Setup {
    $null = Move-ToolsToFolder $true
    while ($true) {
        Refresh-Tools
        $items = @(Get-SetupItems)
        Show-Header 'Setup'
        W ''
        W '  Checks the tools this program needs and installs missing ones for you.' 'Gray'
        W ('  Tools folder: {0}' -f (Limit-Text $ToolsDir 58)) 'DarkGray'
        W ('  Running in PowerShell {0}' -f $PSVersionTable.PSVersion) 'DarkGray'
        Show-SetupTable $items
        $missing = @($items | Where-Object { -not $_.Ok })
        W ''
        if ($missing.Count -eq 0) {
            W '  Everything is installed.' 'Green'
            break
        }
        Write-Item 'A' 'Install everything that is missing'
        Write-Item 'C' 'Choose one by one'
        Write-Item 'S' 'Skip (run the setup again later in Settings or Tools)'
        $k = Read-Key
        if ($k -eq 'S' -or $k -eq 'ESC' -or $k -eq 'ENTER' -or $k -eq 'B') { break }
        if ($k -ne 'A' -and $k -ne 'C') { continue }
        $done = @{}
        foreach ($it in $missing) {
            if ($done.ContainsKey($it.Group)) { continue }
            if ($k -eq 'C') {
                W ''
                Wn ('  Install {0}? (Y = yes, N = no, S = stop) ' -f $it.Name) 'Yellow'
                $yn = Read-Key
                W ''
                if ($yn -eq 'S' -or $yn -eq 'ESC') { break }
                if ($yn -ne 'Y') { continue }
            }
            W ''
            W ('  --- {0} ---' -f $it.Name) 'Cyan'
            $done[$it.Group] = $true
            $r = @(& $it.Install) | Select-Object -Last 1
            if (-not $r) { W ('  ' + $it.Name + ' could not be installed.') 'Red' }
        }
        Refresh-Tools
        Wait-Key
    }
    Refresh-Tools
}

function Assert-Tools {
    $miss = @()
    if (-not $script:ytdlp)  { $miss += 'yt-dlp' }
    if (-not $script:ffmpeg) { $miss += 'ffmpeg' }
    if ($miss.Count -eq 0) { return $true }
    Show-Header 'Missing tools'
    W ''
    W ('  Missing: ' + ($miss -join ', ')) 'Red'
    W '  Downloads need these tools. Run the setup now to install them? (Y/N)' 'Gray'
    $k = Read-Key
    if ($k -eq 'Y') {
        $null = Invoke-Setup
        Refresh-Tools
        Read-Versions
        $null = Detect-Hardware
    }
    return [bool]($script:ytdlp -and $script:ffmpeg)
}

# ---------------------------------------------------------------------
# PC specs, ratings, speed test
# ---------------------------------------------------------------------
$BenchFile = Join-Path $Root 'benchmark.json'
$script:Bench  = $null
$script:Spec   = $null
$script:Rating = $null

function Get-Specs {
    $sp = [pscustomobject]@{ Cpu = 'Unknown CPU'; Cores = 0; Threads = 0; GHz = 0.0; RamGB = 0; Gpus = @(); GpuInfo = @(); Os = '' }
    try {
        $procs = @(Get-CimInstance Win32_Processor)
        if ($procs.Count -gt 0) {
            $sp.Cpu     = ($procs[0].Name -replace '\s+', ' ').Trim()
            $sp.Cores   = [int](($procs | Measure-Object -Property NumberOfCores -Sum).Sum)
            $sp.Threads = [int](($procs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
            $sp.GHz     = [double]$procs[0].MaxClockSpeed / 1000.0
        }
    } catch { }
    try { $sp.RamGB = [int][Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB) } catch { }
    try {
        $vc = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -and $_.Name -notmatch 'Basic|Virtual|Remote|Parsec|Citrix' })
        $sp.Gpus    = @($vc | ForEach-Object { [string]$_.Name })
        $sp.GpuInfo = @($vc | ForEach-Object { '{0}|{1}' -f $_.Name, $_.DriverVersion })
    } catch { }
    try { $sp.Os = ((Get-CimInstance Win32_OperatingSystem).Caption -replace 'Microsoft ', '') } catch { }
    return $sp
}

function Get-Ratings($sp) {
    $score = $sp.Threads * $sp.GHz
    if ($sp.Threads -le 0)  { $cr = 'Unknown';  $cc = 'DarkGray' }
    elseif ($score -ge 50)  { $cr = 'Strong';   $cc = 'Green' }
    elseif ($score -ge 28)  { $cr = 'Good';     $cc = 'Green' }
    elseif ($score -ge 14)  { $cr = 'Moderate'; $cc = 'Yellow' }
    else                    { $cr = 'Weak';     $cc = 'Red' }

    if ($sp.RamGB -ge 16)    { $rr = 'Plenty';   $rc = 'Green' }
    elseif ($sp.RamGB -ge 8) { $rr = 'Enough';   $rc = 'Green' }
    elseif ($sp.RamGB -ge 4) { $rr = 'Low';      $rc = 'Yellow' }
    else                     { $rr = 'Very low'; $rc = 'Red' }

    $gr = 'No GPU encoder'; $gc = 'Yellow'; $tech = ''
    if ($script:HasNv) {
        $n = [string]($sp.Gpus | Where-Object { $_ -match 'NVIDIA' } | Select-Object -First 1)
        $tech = 'NVENC'; $gc = 'Green'
        if ($n -match 'RTX\s*(40|50)\d\d')        { $gr = 'Excellent' }
        elseif ($n -match 'RTX|GTX\s*16\d\d')     { $gr = 'Very good' }
        else                                      { $gr = 'Good' }
    } elseif ($script:HasAmd) {
        $n = [string]($sp.Gpus | Where-Object { $_ -match 'AMD|Radeon' } | Select-Object -First 1)
        $tech = 'AMF'; $gc = 'Green'
        if ($n -match 'RX\s*[79]\d{3}')           { $gr = 'Very good' }
        elseif ($n -match 'RX\s*[56]\d{3}')       { $gr = 'Good' }
        else                                      { $gr = 'Basic'; $gc = 'Yellow' }
    }

    if     ($gr -eq 'Excellent') { $v = 'Very fast: 1080p and 4K conversions run far faster than real time.'; $vc = 'Green' }
    elseif ($gr -eq 'Very good') { $v = 'Fast: 1080p is quick and 4K HEVC is fine.'; $vc = 'Green' }
    elseif ($gr -eq 'Good')      { $v = 'Good: 1080p is quick, 4K takes a while.'; $vc = 'Green' }
    elseif ($gr -eq 'Basic')     { $v = 'OK for 1080p. Above 1080p prefer Fast mode.'; $vc = 'Yellow' }
    elseif ($cr -eq 'Strong')    { $v = 'CPU only: 1080p is fine, 4K HEVC will be slow.'; $vc = 'Yellow' }
    elseif ($cr -eq 'Good')      { $v = 'CPU only: OK for 720p/1080p. Prefer Fast mode for 4K.'; $vc = 'Yellow' }
    elseif ($cr -eq 'Moderate')  { $v = 'CPU only: slow. Use Fast or Original mode, re-encode only up to 720p.'; $vc = 'Yellow' }
    else                         { $v = 'CPU only: very slow. Use Fast or Original mode.'; $vc = 'Red' }
    if ($sp.RamGB -gt 0 -and $sp.RamGB -lt 8) { $v += ' Low RAM: avoid 4K re-encoding.' }

    return [pscustomobject]@{ CpuR = $cr; CpuC = $cc; RamR = $rr; RamC = $rc; GpuR = $gr; GpuC = $gc; GpuTech = $tech; Verdict = $v; VerdictC = $vc }
}

function Get-FreeSpace {
    try {
        $root = [IO.Path]::GetPathRoot([string]$script:S.DownloadFolder)
        $di = New-Object -TypeName System.IO.DriveInfo -ArgumentList $root
        return [pscustomobject]@{ Drive = $root; GB = [Math]::Round($di.AvailableFreeSpace / 1GB) }
    } catch { return $null }
}

function Write-Wrapped([string]$Prefix, [string]$Text, [int]$Width, [string]$Color) {
    $pad = ' ' * $Prefix.Length
    $line = ''
    $first = $true
    foreach ($word in ($Text -split '\s+')) {
        if (($line.Length + $word.Length + 1) -gt $Width -and $line.Length -gt 0) {
            if ($first) { Wn $Prefix 'DarkGray'; $first = $false } else { Wn $pad 'DarkGray' }
            W $line $Color
            $line = ''
        }
        if ($line.Length -gt 0) { $line += ' ' }
        $line += $word
    }
    if ($line.Length -gt 0) {
        if ($first) { Wn $Prefix 'DarkGray' } else { Wn $pad 'DarkGray' }
        W $line $Color
    }
}

function Show-SpecsPanel {
    $sp = $script:Spec
    $r  = $script:Rating
    if (-not $sp -or -not $r) { return }
    W ''
    W '  Your PC' 'Cyan'
    $t = Limit-Text ('{0}  ({1}C/{2}T, {3:N1} GHz)' -f $sp.Cpu, $sp.Cores, $sp.Threads, $sp.GHz) 52
    Wn '   CPU   ' 'DarkGray'; Wn ($t.PadRight(54)) 'Gray'; W $r.CpuR $r.CpuC
    $t = '{0} GB' -f $sp.RamGB
    Wn '   RAM   ' 'DarkGray'; Wn ($t.PadRight(54)) 'Gray'; W $r.RamR $r.RamC
    $g = 'none detected'
    if ($sp.Gpus.Count -gt 0) { $g = [string]$sp.Gpus[0] }
    if ($r.GpuTech) { $g = "$g ($($r.GpuTech))" }
    $t = Limit-Text $g 52
    Wn '   GPU   ' 'DarkGray'; Wn ($t.PadRight(54)) 'Gray'; W $r.GpuR $r.GpuC
    $fs = Get-FreeSpace
    if ($fs) {
        $dc = 'Green'
        if ($fs.GB -lt 20) { $dc = 'Yellow' }
        if ($fs.GB -lt 5)  { $dc = 'Red' }
        $t = '{0} GB free on {1}' -f $fs.GB, $fs.Drive
        Wn '   Disk  ' 'DarkGray'; W $t $dc
    }
    $rep = Get-ConvertReport
    if ($rep) {
        Wn '   Convert  ' 'DarkGray'
        Wn ('Grade {0} - {1}' -f $rep.Grade, $rep.Label) $rep.Color
        W '   (details: press R)' 'DarkGray'
        Write-Wrapped '            ' $rep.Advice 58 'Gray'
    }
    if ($script:Bench -and $script:Bench.Results) {
        $res = @($script:Bench.Results)
        $parts = @()
        foreach ($gn in @($res | ForEach-Object { $_.Group } | Select-Object -Unique)) {
            $h = @($res | Where-Object { $_.Group -eq $gn -and $_.Codec -eq 'H.264' })[0]
            $e = @($res | Where-Object { $_.Group -eq $gn -and $_.Codec -eq 'HEVC' })[0]
            $s = "$gn"
            if ($h) { $s += (' H.264 {0:N1}x' -f $h.X) }
            if ($e) { $s += (' HEVC {0:N1}x' -f $e.X) }
            $parts += $s
        }
        $dt = ''
        if ($script:Bench.BenchDate) { $dt = ' (' + ([string]$script:Bench.BenchDate).Split(' ')[0] + ')' }
        Write-Wrapped '   Speed    ' ('1080p speed test' + $dt + ': ' + ($parts -join '  |  ')) 58 'Gray'
    } elseif ($script:ffmpeg) {
        W '   Speed     not tested yet - see Tools -> Hardware and speed test' 'DarkGray'
    }
}

function Get-HwFingerprint($sp) {
    return ('{0}|{1}|{2}|{3}|{4}' -f $sp.Cpu, $sp.Cores, $sp.Threads, $sp.RamGB, ($sp.Gpus -join ';'))
}

function Save-HwCache([string]$Hw, [string]$Enc, $Results, [string]$BenchDate) {
    $r = @()
    if ($Results) { $r = @($Results) }
    $obj = [ordered]@{
        HwFp      = $Hw
        EncFp     = $Enc
        Cpu       = [string]$script:Spec.Cpu
        HasNv     = [bool]$script:HasNv
        HasAmd    = [bool]$script:HasAmd
        BenchDate = $BenchDate
        Results   = $r
    }
    try { $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BenchFile -Encoding UTF8 } catch { }
    Load-Bench
}

# Hardware fingerprint (CPU, cores, RAM, GPU names)  -> decides if the speed test must run again.
# Encoder fingerprint (hardware + GPU driver + ffmpeg version) -> decides if the encoders are tested again.
function Detect-Hardware([switch]$Force) {
    $sp = Get-Specs
    $script:Spec = $sp
    $names = ($sp.Gpus -join ' ; ')
    $script:GpuNames = $names
    $hw  = Get-HwFingerprint $sp
    $enc = $hw + '#' + ($sp.GpuInfo -join ';') + '#' + $script:VerFf
    $script:HwFp  = $hw
    $script:EncFp = $enc
    $b = $script:Bench

    if (-not $script:ffmpeg) {
        $script:HasNv = $false
        $script:HasAmd = $false
        $script:Rating = Get-Ratings $sp
        return
    }

    $cached = [bool]($b -and (-not $Force) -and ($b.EncFp -eq $enc))
    if ($cached) {
        $script:HasNv  = [bool]$b.HasNv
        $script:HasAmd = [bool]$b.HasAmd
    } else {
        W '  Testing GPU encoders...' 'DarkGray'
        $script:HasNv  = ($names -match 'NVIDIA') -and (Test-Enc 'h264_nvenc')
        $script:HasAmd = ($names -match 'AMD|Radeon') -and (Test-Enc 'h264_amf')
    }
    $script:Rating = Get-Ratings $sp

    $benchValid = [bool]($b -and ($b.HwFp -eq $hw) -and $b.BenchDate)
    if (-not $cached) {
        $keep = @()
        $keepDate = ''
        if ($benchValid) { $keep = @($b.Results); $keepDate = [string]$b.BenchDate }
        Save-HwCache $hw $enc $keep $keepDate
    }
    if ((-not $benchValid) -and $script:S.AutoBenchmark) {
        W ''
        if ($b -and $b.HwFp) { W '  Hardware change detected - running the speed test again.' 'Yellow' }
        else { W '  First start on this PC - running the one-time speed test.' 'Yellow' }
        W '  This takes about a minute. The result is cached.' 'DarkGray'
        Start-Sleep -Milliseconds 1200
        Run-Benchmark
    }
}

function Load-Bench {
    if (Test-Path -LiteralPath $BenchFile) {
        try { $script:Bench = Get-Content -LiteralPath $BenchFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $script:Bench = $null }
    }
}

function Get-SpeedWord([double]$x) {
    if ($x -ge 4)   { return 'very fast' }
    if ($x -ge 1.5) { return 'fast' }
    if ($x -ge 0.9) { return 'about real time' }
    return 'slow'
}

function Run-Benchmark {
    if (-not $script:ffmpeg) {
        W '  ffmpeg is missing - run the setup first.' 'Red'
        Wait-Key
        return
    }
    Show-Header 'Speed test'
    W ''
    W '  Encodes a synthetic 1080p test clip with every available encoder.' 'Gray'
    W '  Takes roughly 30 to 90 seconds. Real videos can be faster or slower.' 'DarkGray'
    W ''
    $tests = @(
        @{ Group = 'CPU'; Codec = 'H.264'; Dur = 6; Enc = @('-c:v', 'libx264', '-preset', 'medium', '-crf', '20') },
        @{ Group = 'CPU'; Codec = 'HEVC';  Dur = 4; Enc = @('-c:v', 'libx265', '-preset', 'medium', '-crf', '23') }
    )
    if ($script:HasNv) {
        $tests += @{ Group = 'NVENC'; Codec = 'H.264'; Dur = 10; Enc = @('-c:v', 'h264_nvenc', '-preset', 'p5', '-rc', 'vbr', '-cq', '19', '-b:v', '0') }
        $tests += @{ Group = 'NVENC'; Codec = 'HEVC';  Dur = 10; Enc = @('-c:v', 'hevc_nvenc', '-preset', 'p4', '-rc', 'vbr', '-cq', '23', '-b:v', '0') }
    }
    if ($script:HasAmd) {
        $tests += @{ Group = 'AMD'; Codec = 'H.264'; Dur = 10; Enc = @('-c:v', 'h264_amf', '-quality', 'quality', '-rc', 'cqp', '-qp_i', '19', '-qp_p', '21') }
        $tests += @{ Group = 'AMD'; Codec = 'HEVC';  Dur = 10; Enc = @('-c:v', 'hevc_amf', '-quality', 'quality', '-rc', 'cqp', '-qp_i', '23', '-qp_p', '25') }
    }
    $results = @()
    foreach ($t in $tests) {
        $label = '{0} {1}' -f $t.Group, $t.Codec
        Wn ('   ' + $label.PadRight(16)) 'Gray'
        $clip = 'testsrc2=size=1920x1080:rate=30:duration={0}' -f $t.Dur
        $a = @('-hide_banner', '-loglevel', 'error', '-nostdin', '-f', 'lavfi', '-i', $clip, '-pix_fmt', 'yuv420p') + $t.Enc + @('-f', 'null', '-')
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $script:ffmpeg @a 2>&1 | Out-Null
        $code = $LASTEXITCODE
        $sw.Stop()
        if ($code -ne 0) { W 'failed' 'Red'; continue }
        $x = [Math]::Round($t.Dur / [Math]::Max(0.05, $sw.Elapsed.TotalSeconds), 1)
        $results += [pscustomobject]@{ Group = $t.Group; Codec = $t.Codec; X = $x }
        Write-BenchSpeed $t.Codec $x
    }
    Save-HwCache $script:HwFp $script:EncFp $results (Get-Date -Format 'yyyy-MM-dd HH:mm')
    W ''
    if ($results.Count -gt 0) { W '  Result saved. It is cached and shown in the main menu.' 'DarkGray' }
    else { W '  No encoder finished the test. Check Tools -> Setup and try again.' 'Yellow' }
    Wait-Key
}

# ---------------------------------------------------------------------
# Download menus
# ---------------------------------------------------------------------
function New-DownloadOptions {
    $o = Copy-Dict $script:S
    $o['Section'] = ''
    return $o
}

# Patreon answers "no access" without login cookies. Explains that before the download starts
# and leads to the Cookies menu. Returns $false when the user cancels.
function Confirm-Cookies([string[]]$Urls, $O) {
    while ($true) {
        $need = @($Urls | Where-Object { $_ -match 'patreon\.com' -and @(Get-CookieArgs $O $_).Count -eq 0 })
        if ($need.Count -eq 0) { return $true }
        $unused = (Test-Path -LiteralPath $CookieFile)   # a cookies.txt exists, but its usage is set to Never
        Show-Header 'Cookies needed'
        W ''
        W '  Patreon needs your login cookies.' 'Yellow'
        W '  Without them Patreon answers "no access", even for posts you have unlocked.' 'Gray'
        W ''
        if ($unused) {
            W '  You have a cookies.txt, but "cookies.txt usage" is set to Never (Settings, key C).' 'Gray'
        } else {
            W '  No cookies.txt was found in the program folder. Two ways to get it:' 'Gray'
            W '   - The Cookies menu can export it from your browser automatically (Firefox works best).' 'Gray'
            W '   - Or install a browser add-on: "Get cookies.txt LOCALLY" (Chrome, Edge, Brave) or' 'Gray'
            W '     "cookies.txt" (Firefox). Log in to patreon.com, export there, then import the' 'Gray'
            W '     file in the Cookies menu.' 'Gray'
        }
        W ''
        if ($unused) { Write-Item 'U' 'Use cookies.txt for this download' }
        Write-Item 'C' 'Open the Cookies menu'
        Write-Item 'D' 'Download anyway (will probably fail)'
        Write-Item 'B' 'Cancel'
        $k = Read-Key
        if ($k -eq 'U' -and $unused) { $O['CookieFileMode'] = 'patreon' }
        if ($k -eq 'C') { $null = Menu-Cookies }
        if ($k -eq 'D') { return $true }
        if ($k -eq 'B' -or $k -eq 'ESC') { return $false }
    }
}

function Menu-NewDownload {
    if (-not (Assert-Tools)) { return }
    while ($true) {
        Show-Header 'New download'
        W ''
        W '  Paste a link (YouTube, Patreon, ...). Several links separated by spaces work too.' 'Gray'
        W '  Empty input = back to the main menu.' 'DarkGray'
        W ''
        $in = (Read-Host '  Link').Trim()
        if (-not $in) { return }
        $urls = @($in -split '\s+' | Where-Object { $_ })
        $O = New-DownloadOptions
        $meta = $null
        $script:showMetaFlag = $null
        if ($urls.Count -eq 1) {
            W ''
            W '  Fetching video info...' 'DarkGray'
            $meta = Get-Meta $urls[0] $O
            $script:showMetaFlag = $true
        } else {
            W ("  {0} links recognised." -f $urls.Count) 'Cyan'
            Start-Sleep -Milliseconds 600
        }
        $r = Show-Options $O $false $meta
        $script:showMetaFlag = $null
        if ($r -eq 'start' -and (Confirm-Cookies $urls $O)) {
            Show-Header 'Downloading'
            Start-Queue $urls $O
            Wait-Key
        }
    }
}

function Menu-Batch {
    if (-not (Assert-Tools)) { return }
    while ($true) {
        Show-Header 'Batch download'
        W ''
        Write-Item '1' 'Paste several links (one per line, empty line = done)'
        Write-Item '2' 'Load links.txt from the program folder'
        Write-Item 'B' 'Back'
        $k = Read-Key
        if ($k -eq 'B' -or $k -eq 'ESC') { return }
        $urls = @()
        if ($k -eq '1') {
            W ''
            W '  Paste links now. Finish with an empty line.' 'Gray'
            while ($true) {
                $l = (Read-Host '  Link').Trim()
                if (-not $l) { break }
                foreach ($p in ($l -split '\s+')) { if ($p) { $urls += $p } }
            }
        } elseif ($k -eq '2') {
            if (-not (Test-Path -LiteralPath $LinksFile)) {
                $tpl = "# One link per line. Lines starting with # are ignored.`r`n"
                Set-Content -LiteralPath $LinksFile -Value $tpl -Encoding UTF8
                W ''
                W '  links.txt did not exist - it was created. Add your links, save it and try again.' 'Yellow'
                Start-Process notepad.exe $LinksFile
                Wait-Key
                continue
            }
            $urls = @(Get-Content -LiteralPath $LinksFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
        } else { continue }

        if ($urls.Count -eq 0) { W '  No links found.' 'Yellow'; Wait-Key; continue }
        $O = New-DownloadOptions
        $script:showMetaFlag = $null
        W ("  {0} links loaded." -f $urls.Count) 'Cyan'
        Start-Sleep -Milliseconds 600
        $r = Show-Options $O $false $null
        if ($r -eq 'start' -and (Confirm-Cookies $urls $O)) {
            Show-Header 'Downloading'
            Start-Queue $urls $O
            Wait-Key
        }
    }
}

# ---------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------
Clear-Host
W ''
W "  YT-DLP DOWNLOADER v$($script:Version) - starting..." 'Cyan'
if ($script:S.SetupPending) {
    Invoke-Setup
    $script:S['SetupPending'] = $false
    Save-Settings
    Refresh-Tools
}
if ($ytdlp -and $script:S.AutoUpdate) {
    W '  Checking for yt-dlp updates...' 'DarkGray'
    & $ytdlp -U --no-warnings
}
Load-Bench
Read-Versions
W '  Detecting hardware...' 'DarkGray'
Detect-Hardware

# ---------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------
$running = $true
while ($running) {
    Show-Header 'Main menu'
    W ''
    Wn '   [1] ' 'Yellow'; Wn 'New download        ' 'White'; W 'paste a link' 'DarkGray'
    Wn '   [2] ' 'Yellow'; Wn 'Batch download      ' 'White'; W 'several links or links.txt' 'DarkGray'
    Wn '   [3] ' 'Yellow'; Wn 'Settings            ' 'White'; W 'defaults, encoder, folder, cookies' 'DarkGray'
    Wn '   [4] ' 'Yellow'; Wn 'History             ' 'White'; W 'your last downloads' 'DarkGray'
    Wn '   [5] ' 'Yellow'; Wn 'Tools               ' 'White'; W 'update, system check, open folders' 'DarkGray'
    Wn '   [C] ' 'Yellow'; Wn 'Cookies             ' 'White'; W 'get, export or import cookies.txt' 'DarkGray'
    Wn '   [R] ' 'Yellow'; Wn 'PC rating           ' 'White'; W 'how well can this PC convert video?' 'DarkGray'
    Wn '   [H] ' 'Yellow'; Wn 'Help                ' 'White'; W 'every option explained' 'DarkGray'
    Wn '   [Q] ' 'Yellow'; W 'Quit' 'White'
    Show-SpecsPanel
    $k = Read-Key
    switch ($k) {
        '1' { Menu-NewDownload }
        '2' { Menu-Batch }
        '3' { [void](Show-Options $script:S $true $null) }
        '4' { Menu-History }
        '5' { Menu-Tools }
        'C' { Menu-Cookies }
        'R' { Show-PcRating }
        'H' { Menu-Help }
        'Q' { $running = $false }
        'ESC' { $running = $false }
    }
}
Clear-Host
