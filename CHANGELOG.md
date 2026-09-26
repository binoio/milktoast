# Changelog

## 1.0.0 — 2026-09-26

First release. A native Swift/SwiftUI rewrite of the QTmkv idea: open a
Matroska file, get it playing in QuickTime Player.

### Added

- SwiftUI launcher with a drop target, a job queue, per-file progress with an
  ETA, and a plain-language explanation of every track decision.
- `MilktoastCore`, a Foundation-only remux engine: ffprobe model, codec policy,
  ffmpeg argument builder, progress parser, and cache logic.
- `milktoast` command-line driver, shipped inside the app bundle, with `--plan`,
  `--remux-only`, `--cache-info`, and `--clear-cache`.
- Playback choices: QuickTime Player, the system default, another app, or
  prepare-only — which stops after the remux and offers an explicit
  "Open in QuickTime" button instead of launching anything.
- Prepared movies are written next to the original by default (`Episode.mkv` →
  `Episode.mp4`), stamped with an extended attribute so Milktoast can recognise
  and reuse its own output, rebuild it when the source or settings change, and
  never overwrite a file someone else put there. ffmpeg writes to a hidden
  scratch file that is renamed into place only on success.
- Settings → Output can keep prepared movies in a managed cache instead. That
  mode is content-addressed with LRU and age eviction — applied at launch,
  before each job, and when the queue empties — and is where the cleanup toggle
  and the size/age budgets live (20 GB / 7 days by default). The cache is
  excluded from Time Machine.
- ffmpeg and ffprobe bundled into the app with their libraries relocated and
  re-signed, so a notarized Milktoast.app has no external dependencies.
- 105 tests, including real ffmpeg round-trips, runnable in a Linux container.

### Improvements over the QTmkv approach

- Every audio track is preserved rather than only the first, with language and
  default flags intact.
- Text subtitles are converted to `tx3g` instead of being dropped, and chapters
  are carried over.
- Lossless audio (FLAC, TrueHD, PCM) becomes ALAC rather than lossy AAC, and
  surround stays surround instead of being folded to stereo.
- 10-bit H.264, VP9, and pre-Sonoma AV1 are detected and re-encoded; everything
  QuickTime can decode is copied untouched.
- Output goes to MP4 by default so subtitles become selectable `sbtl` tracks
  rather than legacy `text` tracks burned over the picture.
- No `+faststart` pass, which halves the I/O for local playback.
- Results are cached and evicted on a budget instead of being dumped in `/tmp`
  with a timestamp suffix.
