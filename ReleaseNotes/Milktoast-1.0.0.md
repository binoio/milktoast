# Milktoast 1.0.0

Matroska files now play in QuickTime Player.

Open an `.mkv` and Milktoast rewraps its streams into a QuickTime-compatible
movie without re-encoding them, then hands it to QuickTime Player — so playback,
AirPlay, Picture in Picture, and the track menus are all the ones you already
know. A 2.3 GB episode is ready in under two seconds.

## Highlights

- **HEVC files that used to play black now play.** Matroska carries HEVC
  untagged; Milktoast re-tags it `hvc1`, which is the sample entry QuickTime
  actually renders.
- **Soundtracks survive.** DTS, TrueHD, Opus, and Vorbis are converted while
  keeping their surround channels — 5.1 stays 5.1 rather than folding to stereo.
  FLAC stays lossless as ALAC.
- **Nothing gets left behind.** Every audio track keeps its language and default
  flag, chapters come along, and text subtitles become selectable tracks in
  QuickTime's Subtitles menu rather than being burned over the picture.
- **The prepared movie lands next to the original.** `Episode.mkv` gets an
  `Episode.mp4` beside it, ready to open any time. A file Milktoast did not
  create is never overwritten, and your original is only ever read. Settings →
  Output can keep prepared movies in a managed cache instead.
- **Opening the same file again is instant.**
- **It asks for nothing.** No network access, no analytics, no Automation
  permission, and no blanket file access.
- **ffmpeg is bundled**, so there is nothing else to install.

Also included: a `milktoast` command-line tool inside the app bundle, with
`--plan` to see exactly what would happen to a file without touching it.

Requires macOS 14 or later. Signed and notarized.
