# Release Guide

Milktoast is distributed as a signed, notarized, stapled `.app` inside a
notarized `.dmg`, published to GitHub Releases. The product page at
<https://binoio.github.io/milktoast/> resolves its download button from the
latest release via the GitHub API, so publishing is all that is needed to update
it.

## Prerequisites

- Xcode, so `xcrun`, `codesign`, `notarytool`, and `stapler` are available.
- A **Developer ID Application** identity in the keychain (override with
  `MILKTOAST_SIGN_IDENTITY`).
- Notary credentials in a keychain profile. Any profile for the same team works,
  so an existing `edith-notary` / `atmo-notary` / `kona-notary` is picked up
  automatically; otherwise create one (never commit credentials):

  ```sh
  xcrun notarytool store-credentials milktoast-notary \
    --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
  ```

  Override the choice with `MILKTOAST_NOTARY_PROFILE`.
- `ffmpeg` and `ffprobe` on `PATH` (`brew install ffmpeg`) — they are copied into
  the bundle with their libraries relocated and re-signed.
- `gh auth login` with access to `binoio/milktoast`.

## One-step release

1. Bump `VERSION`.
2. Write `ReleaseNotes/Milktoast-X.Y.Z.md` — it becomes the GitHub release body.
3. Update `CHANGELOG.md`.
4. Commit everything, then from the repo root:

```sh
./Scripts/release.sh
```

The script:

1. **Preflight** — clean working tree, tag not already used, version newer than
   the latest tag, release notes present, signing identity in the keychain,
   notary profile reachable, `gh` authenticated.
2. **Tests** — the full suite must pass.
3. **Build** — `Scripts/build.sh` compiles the release products, assembles
   `build/Milktoast.app`, stamps the version from `VERSION` and the build number
   from the commit count, embeds `ffmpeg`/`ffprobe` with their libraries
   relocated to `@executable_path/../Frameworks`, and signs inside-out.
4. **Verify the bundle** — bundle id, version, all three helpers present, the
   app icon, and that `ffmpeg` links nothing outside the bundle (an absolute
   Homebrew path here would mean the app only runs on the build machine).
5. **Notarize** — zip the app, submit, wait, staple, re-zip so the archive
   carries the ticket.
6. **Disk image** — stage the stapled app with an `/Applications` symlink, build
   a UDZO `.dmg`, sign it, notarize it, staple it.
7. **Verify** — `codesign --verify --deep --strict`, `spctl --assess`, and
   `stapler validate` on both artifacts.
8. **Publish** — tag, push the tag, and create the GitHub release with the
   `.dmg` and the `.zip` attached.

To rehearse without publishing:

```sh
./Scripts/release.sh --dry-run
```

This performs everything through stapling and verification, then stops.

## Signing model

`Scripts/codesign_app.sh` signs **inside-out and never uses `--deep`**, which is
unsupported for distribution and silently mis-signs nested code:

1. the bundled FFmpeg `.dylib`s in `Contents/Frameworks`,
2. the helper executables in `Contents/Helpers` (`ffmpeg`, `ffprobe`, and the
   `milktoast` CLI), each with the app's entitlements,
3. the app bundle itself.

Milktoast is **not sandboxed** — a sandboxed parent cannot hand its file-access
grants to a child process, so every ffmpeg run would fail. It uses the hardened
runtime with one exception, `com.apple.security.cs.disable-library-validation`,
because the helpers load the FFmpeg libraries shipped beside them. See the
comments in `Support/Milktoast.entitlements`.

## Post-release checks

```sh
codesign --verify --deep --strict build/Milktoast.app
codesign -d --entitlements - build/Milktoast.app     # disable-library-validation only
spctl -a -vv -t exec build/Milktoast.app             # "Notarized Developer ID"
xcrun stapler validate dist/Milktoast-X.Y.Z.dmg
```

Then confirm the product page picked up the release — the **Download for macOS**
button should point at the `.dmg` and the version line should show the new tag.

## Not wired up

There is no Sparkle auto-update feed. Milktoast has no `docs/appcast.xml`,
`SUFeedURL`, or EdDSA key, so users update by downloading a new build. Adding it
would follow the pattern in `edith` and `kona`: add the Sparkle package
dependency, embed and sign `Sparkle.framework` in `Scripts/codesign_app.sh`,
commit the public key as `SUPublicEDKey`, and have `release.sh` run
`generate_appcast` before publishing.
