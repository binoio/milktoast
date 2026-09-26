# Troubleshooting

## Milktoast does not appear under "Open with"

Launch Services caches bundle registrations. `Scripts/install.sh` registers the
app, but if a stale entry is in the way:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/Milktoast.app
```

To reset every file association on the machine (heavy-handed, and it undoes all
your other choices too):

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -kill -r -domain local -domain system -domain user
```

## "Milktoast is damaged and can't be opened"

Gatekeeper's message for an unsigned or unnotarized build carrying a quarantine
attribute. For a local build:

```sh
xattr -cr /Applications/Milktoast.app
```

For distribution, build with `Scripts/build_and_notarize.sh` instead.

## "Milktoast could not find ffmpeg"

The bundle normally carries its own copy in `Contents/Helpers`. If you built
with `--no-helpers`, install one:

```sh
brew install ffmpeg
```

Check what the app would use:

```sh
milktoast --plan ~/Movies/Example.mkv
```

## Playback starts but there is no sound

Look at the job's "What Milktoast did" disclosure. If the track was dropped, the codec
had no path into a QuickTime container. If it was converted and is still silent,
try a different surround target in Settings → Tracks — some receivers refuse
E-AC-3 over AirPlay.

## Subtitles do not appear

They are off until you turn them on: QuickTime Player's **View → Subtitles**
menu. Image-based subtitles (Blu-ray PGS, DVD VobSub) are never carried over;
the job detail says so when it skips them.

## A conversion is taking minutes instead of seconds

The source video is in a codec QuickTime cannot decode (VP9, 10-bit H.264, AV1
on macOS 13), so it is being re-encoded rather than copied. `milktoast --plan` on the
file reports `Mode: video re-encode required (slow)` when this is the case.

## What happens to the prepared .mp4 files?

They are cached so that reopening a movie is instant, and they are cleaned up
automatically. Milktoast applies the cache budget at launch, before each remux,
and again once its queue is empty: partial leftovers go first, then anything
past the age limit, then the least recently used until the size cap is met.
Defaults are 7 days and 20 GB; both are in Settings → Cache.

The cache sits in `~/Library/Caches/io.bino.milktoast`, which macOS may reclaim
on its own when the disk fills, and it is excluded from Time Machine backups.
Your original `.mkv` is never touched.

To reclaim the space right now:

```sh
milktoast --cache-info     # where it is and how big
milktoast --clear-cache    # delete every prepared movie
```

or Settings → Cache → **Empty Cache Now**. Deleting a cached movie only means
the next open of that file takes a second or two again.

## Milktoast does not appear in System Settings → Privacy & Security

That is expected, and it is a good sign. Opening a movie from Finder — by
double-clicking it, dragging it onto Milktoast, or choosing it in the open panel —
grants Milktoast access to that one file through Launch Services. No blanket
permission is requested, so no entry is created.

Milktoast appears under **Files and Folders** only once macOS actually has to ask,
which in practice means a movie on an external drive or a network share. The
explanations shown in those prompts come from the `NS*UsageDescription` keys in
`Support/Info.plist`.

If a movie on an external or network volume fails to open, check **Files and
Folders** and **Full Disk Access** there. Note that a locally built, ad-hoc
signed Milktoast.app gets a new code identity on every rebuild, so any grant you give
one build will not carry over to the next — a notarized build signed with a
stable Developer ID identity keeps its grants.

## I would rather open the movie myself

Settings → Playback → **"Just prepare it — I'll open it myself"**. Milktoast then
stops once the movie is ready and leaves the job row with an **Open in
QuickTime** button and a Reveal in Finder button, and the window stays up.

The command line does the same thing:

```sh
milktoast --remux-only Movie.mkv      # prints the path, opens nothing
open -a "QuickTime Player" "$(milktoast --remux-only Movie.mkv)"
```
