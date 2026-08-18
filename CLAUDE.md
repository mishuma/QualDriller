# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project Overview

QualDriller is an offline iOS app (SwiftUI) that runs firearms qualifier
drills for **dry practice only** — no live fire, no network, no telemetry.
It queues a drill, speaks the command, waits for "ready", buzzes, times the
string by listening for the shooter's shouted "bang", and scores against a
par time. See [README.md](README.md) for the full safety brief and feature
list.

**Safety-critical copy.** The README's dry-practice safety warnings and any
in-app safety text exist because misuse of this app near a loaded firearm is
a real injury risk. Never soften, shorten, or remove safety language when
touching `README.md`, onboarding copy, or in-app strings — treat it as
load-bearing, not boilerplate. If a change touches that language, flag it
explicitly rather than folding it into an unrelated edit.

## Architecture

Single-target SwiftUI app, no external dependencies (Foundation/SwiftUI/
AVFoundation only). Seven source files under `Sources/`:

| File | Lines | Responsibility |
|---|---|---|
| `QualDrillerApp.swift` | 10 | App entry point |
| `ContentView.swift` | 639 | SwiftUI views |
| `DrillEngine.swift` | 1160 | The examiner state machine — queued → armed → timing → scored. Read this first when changing behavior. Already over this project's 800-line file-size ceiling — extract before extending it further. |
| `AudioCore.swift` | 366 | Sample-accurate loudness/vocal-onset detection — listens for the shouted "bang", not gunfire |
| `VoiceCommands.swift` | 412 | Spoken command recognition ("start", "ready", etc.) |
| `TaskList.swift` | 236 | Parses the drill/task file; defines what ends a timed string |
| `Ammo.swift` | 115 | Magazine pool model — partial mags return to the pool, they aren't discarded |

## Build System — XcodeGen

`project.yml` is the source of truth. `QualDriller.xcodeproj` and
`Info.plist` are **generated and gitignored** — never hand-edit them, and
regenerate after any `project.yml` change:

```bash
xcodegen generate
```

## Running Tests

Tests run against a **macOS**, not iOS, test bundle target
(`QualDrillerTests`). This is deliberate, not a mistake: this machine's
CoreSimulator install doesn't line up with the installed Xcode, so booting
an iOS Simulator to run tests does not work here. Only the pure-logic files
(`Ammo.swift`, `TaskList.swift` — Foundation-only, no UIKit/SwiftUI) are
compiled directly into the test target, so they build and run natively on
macOS with no simulator involved.

```bash
xcodegen generate
xcodebuild test -scheme QualDrillerTests -destination 'platform=macOS'
```

Do not add UI-layer, `AudioCore`, or `VoiceCommands` tests to this target —
they depend on iOS-only frameworks and won't compile into a macOS bundle.
Covering those requires either a real-device run or fixing the
CoreSimulator/Xcode mismatch first.

## Building the App

```bash
xcodegen generate
xcodebuild build -scheme QualDriller -destination 'generic/platform=iOS Simulator'
```

Compiling for the simulator destination works on this machine even though
*running* on a booted simulator does not — use this to verify the app
target compiles without needing a working simulator.

## Development Notes

- Deployment targets: iOS 17.0 (app), macOS 13.0 (test bundle only — the app
  itself never runs on macOS)
- No package manager, no third-party dependencies
- `DEVELOPMENT_TEAM` in `project.yml` is the author's Apple ID team — change
  it in `project.yml`, not in Xcode, if it needs to move
