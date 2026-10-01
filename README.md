# YT-DLP Interface

A menu-driven console front end for [yt-dlp](https://github.com/yt-dlp/yt-dlp) on Windows.
The whole program is a single file, `YT-DLP Interface.bat` — download it, double-click it, done.

No installation and no command line knowledge needed. On the first start the program
offers to download the tools it needs (yt-dlp, ffmpeg, deno) for you.

## Features

- **Video and audio downloads** from every site yt-dlp supports
- **MP4 output** with three encoding modes:
  - *Quality* – re-encode, tuned to the real resolution of the video
  - *Fast* – copy H.264 streams without re-encoding (seconds, no quality loss)
  - *Original* – keep the file exactly as yt-dlp downloads it
- **GPU encoding** with NVIDIA NVENC or AMD AMF, automatic fallback to the CPU
- **Audio only** as MP3, M4A, OPUS, FLAC or WAV
- **Playlists** (each into its own numbered sub folder) and **batch downloads** (paste several links or use `links.txt`)
- **Time range** – download only a part of a video
- Subtitles, thumbnails, embedded metadata, SponsorBlock
- **Cookie helper** for age-restricted, private or members-only videos (guide, browser export, import, site filter)
- **PC rating and speed test** – shows how fast your PC converts video and recommends default settings
- Progress bars for download and conversion, download history, built-in help for every option

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (included in Windows). PowerShell 7 is used automatically if it is installed.
- Internet access for the first-run setup

## Getting started

1. Download `YT-DLP Interface.bat` and put it into a folder of its own (the program creates files next to itself).
2. Double-click it.
3. The first-run setup lists the missing tools. Press `A` to install everything.
4. In the main menu press `1`, paste a link, press Enter, then Enter again to start.

Windows may show a SmartScreen warning the first time, because the file was downloaded
from the internet. This is normal for scripts: choose **More info → Run anyway**, or
right-click the file → **Properties → Unblock**. The file is plain text, so you can open it
in any editor and read exactly what it does before running it.

## Tools installed by the setup

Everything is downloaded from the official sources into a `tools` sub folder next to the program:

| Tool | Purpose | Source |
| --- | --- | --- |
| yt-dlp | the downloader itself | [yt-dlp releases](https://github.com/yt-dlp/yt-dlp/releases) |
| ffmpeg + ffprobe | merging and converting (about 190 MB) | [yt-dlp FFmpeg builds](https://github.com/yt-dlp/FFmpeg-Builds) |
| deno | JavaScript runtime for full YouTube support | [Deno releases](https://github.com/denoland/deno/releases) |
| ChromeCookieUnlock (optional) | read Chrome / Edge / Brave cookies while the browser is open | [seproDev/yt-dlp-ChromeCookieUnlock](https://github.com/seproDev/yt-dlp-ChromeCookieUnlock) |
| PowerShell 7 (optional) | newer shell, installed with winget | Microsoft |

You can also place `yt-dlp.exe`, `ffmpeg.exe` and `ffprobe.exe` into the `tools` folder yourself,
or have them in your `PATH`.

## Files the program creates

| File | Content |
| --- | --- |
| `settings.json` | your saved defaults (delete it to reset everything) |
| `history.log` | list of finished downloads |
| `links.txt` | links for batch mode |
| `benchmark.json` | cached hardware info and speed test result |
| `cookies.txt` | optional login cookies |
| `tools\` | yt-dlp, ffmpeg, ffprobe, deno |
| `Downloads\` | default download folder (can be changed in Settings) |

> **Keep `cookies.txt` private.** It works like a password for your logged-in accounts.
> Never share it or upload it anywhere.

## Using Windows PowerShell 5.1 only

Open the `.bat` file in a text editor and change `set "USE_PS7=1"` near the top to `set "USE_PS7=0"`.

## How can one file be a batch file and a PowerShell script?

The first lines are a small batch header that starts PowerShell and tells it to run the rest
of the same file. PowerShell sees that header as a comment, and the batch interpreter never
reads past it.

## Troubleshooting

The built-in help (main menu → `H` → Troubleshooting) covers the common cases:
missing JavaScript runtime, age-restricted videos, errors 403 / 429, failing GPU encoding
and strange symbols instead of boxes.

## Changelog

### 2.3.1 (hotfix)

- **Fixed:** the setup failed with `Access to the path '...\tools\ffmpeg.exe' is denied` when
  an existing `ffmpeg.exe` or `ffprobe.exe` was marked hidden or read-only. Windows refuses to
  overwrite such files, so a missing `ffprobe.exe` could not be installed.
- **Fixed:** the same problem when the setup replaced an existing `yt-dlp.exe`.
- **Improved:** a tool that cannot be replaced because it is currently running no longer aborts
  the setup. The existing file is kept and the remaining files are still installed.

## Disclaimer

This project is not affiliated with yt-dlp, FFmpeg or any video platform. Only download
content you have the right to download, and respect the terms of service of the sites you use.

## License

[MIT](LICENSE)
