# QualDriller

An offline iPhone examiner for firearms qualifier drills, for **dry practice
only**. It queues a drill, reads the command aloud, asks "Shooter ready?",
buzzes, times the string, and reads your time back.

Every "shot" is **you saying so out loud** — you shout "bang", the app hears
loudness and stops the clock. There is no live fire anywhere in this app's
design, and it will not work as a live-fire timer.

Everything runs on the device. No network at any point, no accounts, no
telemetry, nothing leaves the phone.

---

## ⚠️ SAFETY — READ THIS FIRST

**NEVER USE THIS APP AT A LIVE FIRING RANGE, OR WITH AMMUNITION OF ANY KIND
PRESENT. IT IS FOR DRY PRACTICE ONLY.**

Dry practice means **no ammunition**. Not in the firearm, not in the magazines,
not in your pockets, not in the room.

**Blanks are not dry fire.** A blank is live ammunition — primer, propellant,
high-pressure gas and burning particulate leaving the muzzle. Blanks cycle the
action, they have caused fatal injuries at close range, and they demand exactly
the same range protocol as any other live round. Do not use blanks with this
app. Use an unloaded firearm with empty magazines, or dummy rounds / snap caps
if you want to practise reloads.

Before every dry-practice session, without exception:

1. Unload the firearm and remove the magazine.
2. Visually **and** physically check the chamber. Look, then feel with a finger.
3. Take all ammunition — including blanks and loaded magazines — out of the room
   entirely. Not on the table. Out.
4. Check the chamber again.
5. Point at a safe backstop that would stop a round if you are wrong about steps
   1–4. An interior wall is not a backstop.
6. Announce to yourself that dry practice has begun, and when it is over,
   announce that it is over before you bring ammunition back into the room.

**This app is a stopwatch, not a safety device.** It cannot see your firearm,
does not know whether it is loaded, and will happily run a drill against a
loaded gun. Its "magazines", "rounds" and "reloads" are bookkeeping numbers on a
screen — they have no connection to the physical firearm in your hands. Nothing
this app displays or announces should ever be treated as confirmation that a
firearm is safe.

The author provides this software as-is, with no warranty of any kind, and
accepts no liability for any injury, death, or damage arising from its use or
misuse. You are solely responsible for firearm safety at all times. If you are
new to dry practice, get instruction from a qualified instructor before doing it
alone.

---

## What it does

- **Queues each drill** before running it. The drill is shown but nothing is
  spoken and no microphone is armed until you say "start" or press START. You
  can arrow between drills, or refill magazines, without the clock caring.
- **Reads the command** aloud in a chosen system voice, then asks "Shooter
  ready?" (or "Standby.", your preference) and waits for your answer.
- **Buzzes** after a fixed 2 s or a random 2–4 s delay.
- **Times the string** to your last shout, recording a split for every shot.
- **Scores it** against the drill's par time — PASS, FAIL, or `SHORT — 2 of 3`
  if you did not make the count.
- **Tracks ammunition** across the whole session, so a drill can begin with a
  partly depleted magazine, and calls "Empty mag. Reload!" when you run dry.
- **Exports CSV** — every shot time, every split, every reload, per drill.

### Voice commands

Only these, and every one has a large on-screen button. Voice is the
convenience; the buttons are the guarantee.

| When | Say |
|---|---|
| Queued, before a drill | "start" / "go" / "ready" / "begin" |
| At "Shooter ready?" | "yes" / "pause" / "repeat command" / "do over" |
| During a string, or the readback | "do over" |

**"Do over"** means *the last thing I attempted, again* — said during a string
it voids that run; said afterwards it goes back to the drill you most recently
shot. Either way the attempt is discarded: the result is removed and the
ammunition is put back.

Your shots are **not** voice commands. The app hears loudness, never words, so
"bang", "rack" and anything else all count identically.

---

## Reloads

Two different things, deliberately given different names and different phases,
because reloading the gun is not the same as refilling your magazines.

- **RELOAD** — on the clock. Swaps the magazine in the gun for the one with the
  most rounds in it. The one you take out keeps its rounds and goes back on the
  belt, so a tactical reload costs you time, not ammunition.
- **REFILL** — between drills, in the queued state only. Tops every magazine
  back up to the loadout in force.

**When the gun runs dry you do not have to press anything.** The examiner calls
"Empty mag. Reload!" with the clock still running, then listens. An empty gun
cannot fire, so the next noise it hears cannot be a shot — shout "reload", or
shout anything, and it is counted as the reload. The clock never stops, so the
reload costs you time exactly as it would on the line.

If every magazine is empty, the app holds at the queued state and refuses to
start another drill until you REFILL. It does not end your session.

---

## The task list

`Resources/tasks.txt` ships inside the app. To use your own, put a `.txt` file
in Files or iCloud Drive and use **Settings › Import a task list**.

> The imported copy is saved on the device and **overrides the bundled file from
> then on**. If you later edit `Resources/tasks.txt` and rebuild and nothing
> changes, that is why — use **Settings › Reset to built-in list**.

```
# Lines starting with # or // are ignored.
#   <command text> | <par seconds> | <shots> | <reload>

1. From the holster, one round to the center of mass. | 4.0 | 1
2. From the holster, two to the chest, one to the head. | 6.0 | 3
3. From the ready position, fire until empty. | 8.0 | mag
4. Bringing the target out to 7 yards, two to the body. | 4.0 | 2 | 10/10/1
5. Untimed drill, scored on nothing. | - | 2
```

- **par** — a number, or `-` for "time it but don't score it".
- **shots** — a positive integer, or `mag` for "until the magazine runs dry".
  Omitted means 1. (`*` for open-ended still parses, but an open-ended string
  cannot stop the timer or be scored, so prefer a number or `mag`.)
- **reload** — optional fourth field, a magazine loadout like `10/10/1`, applied
  when that drill is queued. A qualifier is often staged: you shoot part of it
  on one loadout, then re-load differently for the rest.

Leading numbering is optional.

**Shot counts are never inferred from the command text, by design.** Real
command scripts are full of decoy numbers — *"7 yards"*, *"you have six
seconds"*, *"15 yards"* — and drills like *"fire until empty"* have no knowable
count. Guessing would silently mis-time runs.

**A count that spans a reload is arithmetic on what is left**, not on a full
magazine, because ammunition carries over between drills. If your magazines
start 10/10/5 and the first four drills use one round each, then "fire until
empty, reload, two more" is 6 + 2 = 8. Change a loadout and every such count
needs recomputing — which is why `mag` is preferable wherever it fits.

---

## How the timing actually works

This matters, because the obvious implementation is wrong.

**Speech recognition is never in the timing path.** Recognition results arrive
200–800 ms after the utterance with jitter larger than the quantity being
measured. It handles only the untimed verbal commands.

**The stop signal is an amplitude threshold on raw microphone samples**,
evaluated inside the audio render callback and timestamped from
`AVAudioTime.hostTime` plus the sample offset within the buffer. Dispatching to
the UI afterwards costs microseconds and cannot move the timestamp.

**T0 is the moment the microphone hears the buzzer**, not the moment the buzzer
was scheduled. Start and stop then travel the same speaker → air → microphone
path, so output and input latency cancel exactly instead of being estimated. If
the mic cannot hear the buzzer, it falls back to the scheduled time corrected by
`AVAudioSession.outputLatency`.

**Do not use Bluetooth headphones.** Their output latency is 100–200 ms and
unstable, which breaks both references. The app detects a Bluetooth route and
warns you. Use the speaker or wired earbuds.

**The threshold recalibrates before every buzzer**, from the room's noise floor
measured during the standby window. A quiet room and a noisy one both work
without touching a slider.

**One shout must be one event**, and that takes two mechanisms. A *dead time*
after each event sets how close two separate shouts may be. A *release gate*
then waits for your voice to actually stop — the level has to fall back toward
the noise floor — before anything else can register. Without the gate, a
drawn-out "baaang" or a shouted "reload" is still above the threshold when the
dead time expires and reports a second time.

### Known limits

- **Splits measured by shouting are your speech cadence, not your shooting.** A
  spoken word cannot be much under 300 ms, so treat shouted splits as a check
  that the plumbing works, not as a measure of your shooting.
- **The app cannot tell your shout from other loud noises.** A holster draw, a
  dropped object or a door can all register. *Settings › Ignore quiet sounds*
  puts a floor under the trigger level if something in your room keeps counting.
- **The examiner is deafened while it speaks.** Its voice comes out of the same
  speaker the microphone is listening to, so a shot during "Empty mag. Reload!"
  is not detected. You are reloading, so it should not arise.
- **`.measurement` audio mode** disables automatic gain and noise suppression,
  which is what makes absolute thresholding meaningful. It also makes the buzzer
  and the voice quieter than a normal app's audio. Turn the phone volume up.
- **This is not a shot timer.** It cannot hear gunshots, and it is not designed
  to. See the safety notice.

---

## Build and install

You need a Mac with Xcode and a USB cable. Build to a physical iPhone — the
Simulator has no usable microphone timing.

```sh
brew install xcodegen          # once
cd QualDriller
xcodegen                       # writes QualDriller.xcodeproj
open QualDriller.xcodeproj
```

Then in Xcode: select the **QualDriller** target → **Signing & Capabilities** →
pick your Team (a free Apple ID works) → choose your iPhone as the destination →
**⌘R**.

> `QualDriller.xcodeproj` is **generated** and is not in version control. Do not
> hand-edit it — changes made in the Xcode GUI, especially the Team, are wiped
> the next time `xcodegen` runs. Project settings belong in `project.yml`.
> Re-run `xcodegen` after adding a source file.

**Set your own team.** `project.yml` carries `DEVELOPMENT_TEAM` and
`PRODUCT_BUNDLE_IDENTIFIER` for the original author. Change both to your own
before building, or clear `DEVELOPMENT_TEAM` and pick your team in Xcode.

**Signing with a free Apple ID expires after 7 days**, after which the app
refuses to launch. Rebuild from Xcode before a practice session. A paid
developer account extends this to a year.

### Before you go somewhere with no signal

The offline speech model has to be on the phone already. Once, while you still
have a connection:

- **Settings › General › Keyboard › Enable Dictation** — this is what downloads
  the on-device model.
- Launch QualDriller, open its Settings, and check that **Offline model** reads
  *installed*. If it reads *missing*, voice input stays off and the app says so
  in a banner. Every step still works on the buttons.

`requiresOnDeviceRecognition` is set unconditionally, so recognition fails
loudly rather than quietly reaching for the network.

---

## Layout

```
QualDriller/
  project.yml                  XcodeGen project definition
  Sources/
    QualDrillerApp.swift       entry point
    ContentView.swift          UI, settings, results, CSV export
    DrillEngine.swift          the examiner state machine
    AudioCore.swift            buzzer, mic tap, sample-accurate detection
    VoiceCommands.swift        offline recognition + matching, offline TTS
    TaskList.swift             task parsing, results, CSV
    Ammo.swift                 magazines and rounds
  Resources/
    tasks.txt                  default task list
  Tools/
    make_icon.py               regenerates the app icon
```

---

## License

Not yet chosen. Until a licence file is added, all rights are reserved by
default and you do not have permission to copy, modify or redistribute this
code. If you want it to be usable, add a `LICENSE` file — MIT and Apache-2.0
are the usual choices, and Apache-2.0 includes an explicit patent grant and a
warranty disclaimer.
