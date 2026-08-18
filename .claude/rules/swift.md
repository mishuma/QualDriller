# Swift Conventions — QualDriller

Project-specific conventions for this repo. General Swift/SwiftUI patterns,
concurrency, and testing guidance come from the globally-installed ecc
Swift skills (`swiftui-patterns`, `swift-concurrency-6-2`,
`swift-protocol-di-testing`) — this file only covers what's specific to
QualDriller.

## Doc comments carry the WHY, not just the WHAT

Every core type in this codebase leads with a doc comment explaining the
domain reasoning, not just what the type is — e.g. `Ammo.swift`'s magazine
pool comment explains *why* a swapped magazine goes back in the pool instead
of being discarded (that's how a tactical reload actually works). When
adding or modifying domain logic (drill state, ammo, audio detection
thresholds, voice command parsing), keep that standard: a reader unfamiliar
with dry-fire practice should understand the domain constraint the code is
encoding, not just the mechanism.

## Keep pure logic Foundation-only

`Ammo.swift` and `TaskList.swift` import nothing but `Foundation` on
purpose — it's what lets them compile into the macOS test bundle without
pulling in UIKit/SwiftUI (see "Running Tests" in the repo's `CLAUDE.md` for
why the test target is macOS, not iOS). If you add new pure-logic files
that should be unit-tested, keep them Foundation-only and add them
explicitly to the `QualDrillerTests` target's `sources` list in
`project.yml`, the same way `Ammo.swift`/`TaskList.swift` are listed there.

## DrillEngine.swift is past this project's size ceiling

At 1160 lines it already exceeds the file-size guidance elsewhere in this
setup (200–400 typical, 800 max). Don't grow it further — new
responsibilities belong in a new file that `DrillEngine` composes, not in
`DrillEngine` itself.

## Never weaken safety-facing strings

Any string surfaced to the user around loading, arming, or the safety
warnings (README, onboarding, in-app alerts) exists for a physical-safety
reason. Treat wording changes there as a safety review, not copy editing —
if in doubt, ask before rewording.

## Do not protocol-extract AudioCore for testability

The `swift-protocol-di-testing` skill installed in `.claude/skills/` will
recommend hiding external dependencies behind protocols so they can be
faked in tests. Applied to `AudioCore.swift`, that advice is wrong here.

Read the header comment in that file before touching it. Its timing
contract depends on timestamps captured on the audio render thread from
`AVAudioTime.hostTime` plus the sample offset inside the buffer. A
protocol boundary in that path adds a dispatch the contract does not
allow, and existing detector heuristics were tuned against the real path,
not an abstraction of it. This is the "simplification" the comment warns
against.

Put the seam one layer up instead: fake the stream of audio events that
`DrillEngine` consumes. That gives you deterministic tests of drill logic,
par timing, and scoring while leaving the render path untouched. Apply the
skill's protocol-DI patterns to speech recognition, persistence, or
anything else off the timing path — never to sample-accurate capture.
