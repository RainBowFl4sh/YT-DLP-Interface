# Changelog

All notable changes to YT-DLP Interface are listed here, newest version first.

## 2.5

### New
- **Encoder choice.** The *Encoder* option (key `E`, now also on the download screen) offers:
  - *Auto* – uses the encoder that was faster in the speed test, GPU or CPU, checked separately
    for H.264 and HEVC. Without a speed test result the GPU is preferred.
  - *NVENC* / *AMD* / *CPU* – always use that one.
  - *GPU + CPU* – with several videos two are converted at the same time, one on the graphics
    card and one on the processor. A single video still uses the GPU only.
- **Built-in update.** At every start the program looks for a newer release on GitHub, shows
  the changes and asks whether to install it (`Y` install and restart, `N` not now, `S` skip
  this version). The previous file is kept as `YT-DLP Interface.bat.bak`. The check can be
  switched off in Settings (key `W`) and started by hand with Tools → `U`.

### Notes
- The built-in update works from this version on. Version 2.4 and older have to be replaced
  by hand once.

## 2.4

### New
- **Download and convert at the same time.** With several links (batch, `links.txt`,
  playlists) the program no longer waits for a conversion to finish. While one video is
  converted to MP4, the next one is already downloading.
  - The download bar shows the state of the converter at its end, e.g. `| Convert #1 45%`.
  - Lines starting with `[#1]` belong to the conversion of item 1.
  - If downloads are much faster than the converter, downloading pauses while two files are
    waiting, so the disk does not fill up with unconverted originals.
- **Patreon cookie check.** Before a Patreon download without usable cookies the program
  explains why it would fail with "no access" and leads to the Cookies menu (automatic browser
  export, or import of a file made with the *Get cookies.txt LOCALLY* / *cookies.txt* add-on).
- When a download fails with a login-related error, a hint points to the Cookies menu.

### Notes
- Audio downloads and Original mode have no separate conversion step and still run one after
  the other.

## 2.3.1 – 2026-10-01

### Fixed
- The setup failed with `Access to the path '...\tools\ffmpeg.exe' is denied` when an existing
  `ffmpeg.exe` or `ffprobe.exe` was marked hidden or read-only. Windows refuses to overwrite
  such files, so a missing `ffprobe.exe` could not be installed.
- The same problem when the setup replaced an existing `yt-dlp.exe`.

### Improved
- A tool that cannot be replaced because it is currently running no longer aborts the setup.
  The existing file is kept and the remaining files are still installed.

## 2.3 – 2026-10-01

First public release.

### Changed
- The program is now a single file, `YT-DLP Interface.bat`. The separate
  `ytdlp-downloader.ps1` is no longer needed.
- Faster conversion start: the source video is analysed with one ffprobe call instead of three.

### Fixed
- Subtitles and thumbnails lost every `_original` in their name, also inside a video title.
  Only the marker at the end is removed now.
- The yt-dlp update check at the start used a misspelled option (`--no-warning`).
- The tools folder was added to `PATH` again with every installed tool.
