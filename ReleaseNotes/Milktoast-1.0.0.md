# Milktoast 1.0.0

Matroska files now play in QuickTime Player.

Open an `.mkv` and Milktoast rewraps its streams into a QuickTime-compatible movie
without re-encoding them, then hands it to QuickTime Player — so playback,
AirPlay, Picture in Picture, and the track menus are all the ones you already
know. A 2.3 GB episode is ready in under two seconds.

**Highlights**

- HEVC files that used to play black now play, correctly tagged.
- DTS, TrueHD, Opus, and Vorbis soundtracks are converted while keeping their
  surround channels; FLAC stays lossless as ALAC.
- Subtitles, chapters, and every alternate audio track come along.
- Reopening a file you have already watched is instant.
- ffmpeg is bundled — nothing else to install.

Requires macOS 14 or later.
