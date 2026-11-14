# Release a build without a Mac

The iOS app is built by GitHub Actions on a macOS runner. Until that first build
passes, part of the Swift code is only *statically* reviewed: this machine has no
Swift toolchain and not enough free disk for one. This guide narrows what the
first failing run can tell you and what to send back.

## What the pipeline checks, in order

| Step | Wall time | Catches |
| --- | --- | --- |
| `parse` | ~1 min | Syntax errors in every `.swift` file (`swiftc -parse`, no SDK needed). |
| `Generate project` | ~2 min | Invalid `project.yml`, missing target or scheme, XcodeGen version drift. |
| `Build (unsigned)` | ~4 min | Everything else: types, actor isolation, API availability, asset catalog, Info.plist. |

`brew install xcodegen` adds a few minutes on a cold cache and is unchanged
across runs.

## Reading a failure

The `build` job writes `build.log` and uploads it as the `xcodebuild-log`
artifact when it fails. Download that artifact; the useful lines are near the
bottom, shaped like:

```
/Users/runner/work/<repo>/<repo>/DshMobile/DshMobile/Model/BridgeAPI.swift:153:24: error: ...
```

Send that file, or just the `error:` lines, and the fix is usually a one-line
edit. Do not send the whole log unless nothing else is visible.

## Naming the build

The artifact is always called `DshMobile-ipa`. Inside it, the file is
`DshMobile-<CFBundleShortVersionString>-unsigned.ipa`. To change the version,
edit `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `DshMobile/project.yml`;
the workflow reads the value back from the built bundle, so the two cannot drift.

## Installing it

An unsigned IPA cannot be installed by drag-and-drop. Re-sign it with your own
Apple ID on a tool that owns that flow:

- **Sideloadly** — Windows or Mac, drag the IPA in, sign, install over USB or Wi-Fi.
- **AltStore / SideStore** — on-device, refreshes the 7-day free-team signature for you.

A free Apple ID signature expires after 7 days and needs a refresh; a paid
developer account lasts a year. This is an Apple restriction, not a property of
this project.

## Simulator alternative

macOS runners can also boot a simulator, but an `.ipa` cannot be installed into
one. If you want a fast iteration loop without a phone, run on a Mac with Xcode:
open `DshMobile/DshMobile.xcodeproj` after `xcodegen generate` and choose an iOS
Simulator destination. The bridge's default `host: 0.0.0.0` already accepts the
simulator's `127.0.0.1` connections.
