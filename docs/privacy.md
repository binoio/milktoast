# Privacy Policy for Milktoast

**Last updated:** September 26, 2026

## Overview

Milktoast is a macOS app that rewraps Matroska (`.mkv`) files into a container
QuickTime Player can open, then hands the result to a player. This policy
explains what it does with your data.

## Data Collection

**Milktoast does not collect, transmit, or share any personal data.**

There is no analytics, no telemetry, no crash reporting, and no account. The app
makes no network connections of any kind — it has no networking code and the
bundled `ffmpeg` is invoked only against local files.

## What Milktoast Reads

Only the movie you open, and only to read it. Milktoast never modifies, moves,
or deletes your original file.

Opening a movie from Finder — by double-clicking it, dragging it onto the app,
or choosing it in the open panel — grants access to that one file through macOS
Launch Services. Milktoast requests no blanket file access and no Automation
permission, which is why it does not normally appear in System Settings →
Privacy & Security.

## What Milktoast Writes

Prepared movies are copies of your video's existing streams in a different
container. By default they are written next to the original file, as
`Episode.mp4` beside `Episode.mkv`, and they stay there for you to manage;
Milktoast never overwrites a file it did not create. Settings → Output can move
them to `~/Library/Caches/io.bino.milktoast/` instead, where they are excluded
from Time Machine and cleaned up on a budget you control.

Everything stays on your Mac. Nothing is uploaded anywhere.

Preferences are stored locally in the standard macOS defaults database
(`~/Library/Preferences/io.bino.milktoast.plist`).

## Third-Party Components

Milktoast bundles [FFmpeg](https://ffmpeg.org) to read and rewrap media. FFmpeg
runs entirely on your Mac and is given only the file you opened.

Handing a prepared movie to QuickTime Player (or another player you choose) uses
the standard macOS "open document" mechanism. What that app does afterwards is
governed by its own privacy policy.

## Changes

Any change to this policy will be published in this file in the project
repository at <https://github.com/binoio/milktoast>.

## Contact

Questions: open an issue at <https://github.com/binoio/milktoast/issues>.
