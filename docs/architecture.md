# Architecture

## Why the launcher model

AVFoundation has no Matroska demuxer. Asking it to open an `.mkv` fails
outright:

```
isPlayable: false
Error Domain=AVFoundationErrorDomain Code=-11828 "Cannot Open"
  NSLocalizedFailureReason=This media format is not supported.
```

After Milktoast:

```
isPlayable: true
vide: ["hvc1"]
soun: ["alac"]
DECODED FRAME 640x360
```

Because the remux is unavoidable for *any* Mac-native player, the only real
design question is what plays the result. QuickTime Player wins on capability
(AirPlay, PiP, HDR, media keys, trimming, export) and on maintenance — Apple
keeps it current. A bespoke `AVPlayerView` would have to re-earn all of that and
would still run the same ffmpeg step first.

The one thing a bespoke player could add is skipping the temporary file
entirely, by piping ffmpeg into a local HLS server and feeding AVPlayer
segments. That trades a 1.7-second wait for a much larger moving-parts budget
and worse seeking. It is not worth it while a remux costs less than two seconds.

## Modules

```
MilktoastCore  ── MediaProbe            ffprobe JSON → typed Swift
         ── PlaybackCapabilities  what the host's decoders support
         ── CompatibilityPolicy   per-codec copy / convert / drop
         ── RemuxPlanner          probe + policy → an ordered output plan
         ── FFmpegCommand         plan → argv
         ── ProgressParser        ffmpeg -progress → typed snapshots
         ── RemuxCache*           content-addressed cache and eviction
         ── ProcessRunner         async child process with cancellation
         ── RemuxService          the orchestration of all of the above

App      ── AppModel              serial job queue, tool resolution, lifecycle
         ── RemuxJob              one file's phase, progress, and plan
         ── PlayerHandoff         NSWorkspace open in the chosen player
         ── Views                 drop zone, job rows, settings

CLI      ── MilktoastCommand            headless driver over the same engine
```

Everything above `App` is Foundation-only, which is what lets the full suite —
including real ffmpeg round-trips — run in a Linux container.

## Decisions worth knowing

**`hvc1`, not `hev1`.** QuickTime renders HEVC only when the sample entry is
`hvc1` (out-of-band parameter sets). Matroska carries HEVC with no such tag, so
a naive remux produces a file that opens and plays black. `-tag:v hvc1` is the
single highest-value line in the project.

**MP4 over MOV.** The MOV muxer writes `mov_text` as a legacy `text` media
track, which QuickTime overlays on the picture unconditionally. The MP4 muxer
writes the same samples as an `sbtl` track that appears in the Subtitles menu.
Track dispositions do not change this — both muxers always mark subtitle tracks
enabled — so the container *is* the mechanism. MOV is used only when a copied
stream has no MP4 sample entry (ProRes, MJPEG, DV, raw PCM).

**No `+faststart`.** Moving `moov` to the front requires a second pass over the
entire file. It matters for progressive HTTP download and for nothing else. A
local handoff pays twice the I/O for no benefit.

**Surround is preserved.** A 5.1 DTS track becomes 5.1 AC-3 at 640 kbps, not
stereo AAC. 7.1 goes to E-AC-3 because ffmpeg's AC-3 encoder stops at six
channels.

**Lossless stays lossless.** FLAC, TrueHD, and PCM become ALAC when they fit in
ALAC's eight channels, rather than being thrown at a lossy encoder.

**Capabilities are injected, not queried inline.** `PlaybackCapabilities` is a
value the planner receives, so codec support can be asserted at every macOS
version in tests, and a future OS needs a change in exactly one factory method.

**The cache key includes the settings.** Changing the surround target or turning
subtitles off must not silently reuse output built under the old rules, so
`RemuxOptions.fingerprint` and a `policyVersion` are hashed in alongside the
source's identity.
