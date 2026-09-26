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

Release builds are signed and notarized by `Scripts/release.sh`, so a downloaded
Milktoast opens without this step.

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

## Where does the prepared .mp4 go, and is it cleaned up?

By default it is written next to the original: `Episode.mkv` gets an
`Episode.mp4` beside it, and it stays there. Milktoast does not delete files it
puts in your folders — that is yours to manage, the same as any other movie.

It will never overwrite something it did not create. Each movie it writes is
stamped with an extended attribute naming the source and settings behind it. An
unstamped `Episode.mp4` already in the folder is left alone and the output
becomes `Episode (Milktoast).mp4`.

If you would rather they were managed for you, Settings → Output →
**"In Milktoast's cache folder"**. That mode adds a **Cleanup** section with an
on/off toggle and size and age budgets (20 GB and 7 days by default). With
cleanup on, Milktoast applies the budget at launch, before each job, and when
its queue empties. With it off, prepared movies are kept until you empty the
cache yourself; half-written leftovers are still removed.

Either way:

```sh
milktoast --cache-info     # where the cache is and how big
milktoast --clear-cache    # delete every cached movie
```

Deleting a prepared movie only means the next open of that file takes a second
or two again. Your original `.mkv` is never touched.

## I would rather open the movie myself

Settings → Playback → **"Just prepare it — I'll open it myself"**. Milktoast then
stops once the movie is ready and leaves the job row with an **Open in
QuickTime** button and a Reveal in Finder button, and the window stays up.

The command line does the same thing:

```sh
milktoast --remux-only Movie.mkv      # prints the path, opens nothing
open -a "QuickTime Player" "$(milktoast --remux-only Movie.mkv)"
```
