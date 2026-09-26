# Milktoast

**Milktoast** makes Matroska files play in QuickTime Player. Mild by design: it
does one small thing and gets out of the way.

It is a launcher, not a player. When you open an `.mkv`, Milktoast rewraps the
streams into a QuickTime-compatible container — without re-encoding them — and
hands the result to QuickTime Player. Playback, AirPlay, Picture in Picture,
audio- and subtitle-track menus, media keys, and trimming are all QuickTime's,
exactly as they are for any other movie.

A 2.3 GB, 63-minute H.264 episode takes about 1.7 seconds to prepare on an
Apple-silicon SSD. Nothing is transcoded; the bytes are copied.

## Why a launcher and not a player

AVFoundation cannot demux Matroska at all — an `.mkv` fails to open with
"This media format is not supported", so *any* native player would still need
the same ffmpeg step. Given that the remux is unavoidable, QuickTime Player is
the better front end: it already has the native transport controls, AirPlay
routing, HDR handling, and system integration, and it keeps getting them from
Apple for free.

The remux engine is a standalone module (`MilktoastCore`), so a player target
could be added later without touching any of the logic below.

## What it fixes

| Problem | What Milktoast does |
| --- | --- |
| HEVC shows a black picture | Re-tags the stream `hvc1`; QuickTime only renders HEVC under that sample entry |
| DTS / TrueHD / Opus / Vorbis audio is silent | Converts to AC-3, E-AC-3, or AAC — surround stays surround, never folded to stereo |
| FLAC audio is unsupported | Re-wraps as ALAC, so it stays lossless |
| 10-bit H.264 (High 10) plays black | Re-encodes, because Apple has no High 10 decoder |
| VP9 is unsupported | Re-encodes with VideoToolbox |
| AV1 | Copied untouched on macOS 14+, re-encoded before that |
| Subtitles are lost | Text subtitles become `tx3g` tracks in QuickTime's Subtitles menu |
| Commentary and alternate languages are lost | Every audio track is carried over, with its language and default flag |
| Chapters are lost | Carried over as a chapter track |

Image-based subtitles (Blu-ray PGS, DVD VobSub) are skipped — no QuickTime
container has a sample entry for them.

## Install

```sh
./Scripts/build.sh      # builds build/Milktoast.app with ffmpeg bundled inside
./Scripts/install.sh    # copies it to /Applications and links the CLI
```

`build.sh` embeds the ffmpeg and ffprobe found on your `PATH`, together with
their libraries, and rewrites their load commands so the app is self-contained
(~39 MB). Pass `--no-helpers` to depend on a system ffmpeg instead.

To make Milktoast the default for Matroska files: select one in Finder, press ⌘I, set
**Open with** to Milktoast, then click **Change All…**.

## Use

* Double-click an `.mkv`, or drag one onto Milktoast, or drop one on its window.
* A progress window appears; it explains every decision it made about your
  tracks. Once QuickTime starts playing, Milktoast quits.
* Opening the same file again is instant — the prepared movie is still cached.

Nothing has to happen automatically. Settings → Playback offers **"Just prepare
it — I'll open it myself"**, which stops after the remux and leaves the job row
with an **Open in QuickTime** button and a Reveal in Finder button; the window
stays up until you dismiss it. A finished job keeps a **Play Again** button in
either mode.

Milktoast opens movies through `NSWorkspace`, the same mechanism Finder uses — not
Apple Events — so it never asks for Automation permission and never appears
under System Settings → Privacy & Security → Automation.

From the command line:

```sh
milktoast Movie.mkv              # prepare and play
milktoast --plan Movie.mkv       # show what would happen; touches nothing
milktoast --remux-only Movie.mkv # prepare and print the path
milktoast --cache-info           # where the cache is and how big it is
milktoast --clear-cache
```

## How it works

1. **Probe.** `ffprobe -show_streams -show_chapters -show_format` is decoded
   into typed Swift.
2. **Plan.** `CompatibilityPolicy` decides, per stream, between copy, convert,
   and drop, given the host's decoder capabilities. `RemuxPlanner` turns that
   into an ordered set of output tracks plus the human-readable warnings the UI
   shows.
3. **Remux.** `FFmpegCommand` builds the argument vector; `ffmpeg -progress
   pipe:1` streams progress back. There is no `+faststart` pass — that would
   rewrite the whole file a second time for a benefit only HTTP streaming gets.
4. **Hand off.** `NSWorkspace` opens the result in QuickTime Player.

### The container choice

Output is MP4 by default and MOV only when a copied stream needs it (ProRes,
motion JPEG, DV, raw PCM). This is not cosmetic: the MOV muxer writes timed text
as a legacy `text` track, which QuickTime burns over the picture whether or not
the source had subtitles enabled. MP4 writes a real `sbtl` track, which lands in
the Subtitles menu and stays off until asked. QuickTime Player opens both.

### The cache

Prepared movies live in `~/Library/Caches/io.bino.milktoast/remux/<key>/`, where
the key hashes the source's name, size, and modification time together with the
settings that affect output. Editing or replacing a file invalidates its entry;
sub-second timestamp jitter from a copy tool does not. A completion marker is
written only after ffmpeg exits cleanly, so an interrupted job is never played.

**They are cleaned up for you.** Eviction runs at launch, before each remux, and
again once the queue drains. It removes partial leftovers first, then anything
past the age limit, then least-recently-used entries until the size cap is met —
7 days and 20 GB by default, both adjustable in Settings → Cache. The limits are
deliberately modest: a cache hit saves a second or two, not minutes.

Two backstops cover the case where you prepare a movie and never open Milktoast
again: the directory is under `~/Library/Caches`, which macOS reclaims on its
own under disk pressure, and it is flagged `isExcludedFromBackup`, so
multi-gigabyte derived files never reach Time Machine. To reclaim the space
immediately, use Settings → Cache → Empty Cache Now, or `milktoast --clear-cache`.

Your original `.mkv` is only ever read. Nothing is written next to it, and
nothing is modified.

## Development

```
Core/       MilktoastCore — the remux engine. Foundation only; builds on Linux.
App/        The SwiftUI launcher (macOS only).
CLI/        The headless driver, shipped inside the bundle as `milktoast`.
Tests/      105 tests: unit tests plus real ffmpeg round-trips.
Scripts/    build, run, test, icon, install, uninstall, notarize, release.
Support/    Info.plist, entitlements, generated icons.
```

```sh
./Scripts/test.sh            # native run
./Scripts/test.sh --docker   # same suite in a Linux container
./Scripts/run.sh Movie.mkv   # debug build, launched on a file
./Scripts/generate_icon.sh   # regenerate the icon
```

The integration tests synthesize small Matroska files with ffmpeg, run them
through the real pipeline, and probe the results — asserting that HEVC comes out
tagged `hvc1`, that FLAC becomes ALAC, that subtitles become `tx3g`, that a
cache hit does not even re-probe, and that a failed job leaves nothing playable
behind. Each one skips itself if the encoder it needs is missing, so the suite
stays green without ffmpeg installed.

CI runs the whole suite in `swift:6.1-noble` with ffmpeg installed
(`.github/workflows/ci.yml`) — no macOS runners.

### Distribution

```sh
CODESIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
NOTARY_PROFILE=milktoast-notary \
  ./Scripts/build_and_notarize.sh
```

produces a stapled `dist/Milktoast-<version>.zip` and `.dmg`. `Scripts/release.sh
<version>` runs the tests, requires release notes, builds those artifacts, and
tags the commit.

Milktoast is deliberately not sandboxed: a sandboxed parent cannot pass its
file-access grants to a child process, so every ffmpeg run would fail. See the
comments in `Support/Milktoast.entitlements`.

It also asks for no blanket privacy permission. Opening a movie from Finder
grants access to that one file through Launch Services, which is why Milktoast does
not show up in System Settings → Privacy & Security until a movie on an external
or network volume forces macOS to ask. The `NS*UsageDescription` strings in
`Support/Info.plist` supply the text for those prompts.

## Uninstall

```sh
./Scripts/uninstall.sh
```

Removes the app, the CLI symlink, the cache, the preferences, and the Launch
Services registration.
