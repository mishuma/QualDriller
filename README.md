# QualDriller

An offline iPhone examiner for firearms qualifier drills. It reads a task,
asks "Shooter ready?", waits for your spoken answer, delays, buzzes, times you
to the last shot, and reads the time back.

Everything runs on the device. No network at any point.

---

## The drill sequence

1. The app reads the next command from the task list.
2. It asks **"Shooter ready?"**
3. You answer **"Yes"**, **"Pause"** (or "No"), **"Repeat command"**, or **"Do over"**.
   Anything else and it replies *"I don't understand"* and keeps listening.
   - **Repeat command** → back to step 1.
   - **Pause** → it holds in place. Say **"Yes"** to continue to the buzzer, or
     **"Repeat command"** to hear the drill again. It stays paused until you say so.
   - **Yes** → straight to step 4.
4. It waits (2 s fixed, or random 2–4 s), then sounds the buzzer and starts the timer.
5. The timer runs until the drill's shot count is reached, recording a split for
   every shot. It also ends if you tap **Stop**, say **"Do over"**, or the run
   times out. Open-ended drills (`*`) run until you tap Stop.
6. It reads the total time back and scores it against par. Splits are on screen
   and in the CSV export.

**"Do over"** means *the last thing I attempted, again*:
- said while a string is running → that run is voided and re-run, nothing recorded
- said at any other time → go back to the drill you most recently shot

Every voice step has a large on-screen button. Voice is the convenience; the
buttons are the guarantee.

---

## Build and install

You need a Mac with Xcode and a USB cable. Building to a physical iPhone is
required — the Simulator has no usable microphone timing.

### Fast path

```sh
brew install xcodegen          # once
cd QualDriller
xcodegen                       # writes QualDriller.xcodeproj
open QualDriller.xcodeproj
```

Then in Xcode: select the **QualDriller** target → **Signing & Capabilities** →
pick your Team (a free Apple ID works) → choose your iPhone as the destination →
**⌘R**.

### Without XcodeGen

1. Xcode → **File › New › Project › iOS › App**. Name it `QualDriller`,
   interface **SwiftUI**, language **Swift**.
2. Delete the generated `ContentView.swift` and `QualDrillerApp.swift`.
3. Drag every file from `Sources/` and `Resources/tasks.txt` into the project,
   with **Copy items if needed** checked.
4. Target → **Info** → add two rows:
   - `Privacy - Microphone Usage Description` — *"QualDriller listens for your spoken replies and detects your shot to stop the timer."*
   - `Privacy - Speech Recognition Usage Description` — *"Speech recognition runs entirely on this device and is used only to hear yes, no, repeat command, and I'm ready."*
5. Set the deployment target to **iOS 17.0** and run on your iPhone.

### Before you go somewhere with no signal

The offline speech model has to be present on the phone. Once, while you still
have a connection:

- **Settings › General › Keyboard › Enable Dictation** — this is what downloads
  the on-device model.
- Launch QualDriller and open its Settings. **Offline model** must read
  *installed*. If it reads *missing*, the app will say so in a banner and voice
  input stays off until it's there. The drill still runs on the buttons.

**Signing with a free Apple ID expires after 7 days.** Rebuild from Xcode before
a range day, or the app will refuse to launch. A paid developer account
($99/yr) extends this to a year.

---

## The task list

`Resources/tasks.txt` ships inside the app. To use your own, put a `.txt` file
in Files or iCloud Drive and use **Settings › Import a task list** — the
imported copy is saved locally and survives relaunch.

```
# Lines starting with # or // are ignored.
#   <command text> | <par seconds> | <shots>

1. From the holster, one round to the center of mass. | 4.0 | 1
2. From the holster, two to the chest, one to the head. | 6.0 | 3
3. From the ready position, fire until empty. | 8.0 | *
4. Untimed drill, scored on nothing | - | 2
```

Numbering is optional. `par` may be a number or `-` for "time it but don't score
it". `shots` may be a positive integer or `*` for open ended; omitted means 1.
The older `[2.5s]` and `(par 2.5)` forms still parse as a par time.

**Shot counts are never inferred from the command text, by design.** Real
command scripts are full of decoy numbers — *"7 yards"*, *"you have six
seconds"*, *"15 yards"* — and drills like *"fire until empty"* or *"finish all
your magazines"* have no knowable count at all. Guessing would silently mis-time
runs, so the count is explicit or it is open ended.

---

## How the timing actually works

This matters, because the obvious implementation is wrong.

**Speech recognition is never in the timing path.** Recognition results arrive
200–800 ms after the utterance with high jitter — larger than the quantity
being measured. It handles only the untimed verbal exchange in steps 2–3.

**The stop signal is an amplitude threshold on raw microphone samples**,
evaluated inside the audio render callback and timestamped from
`AVAudioTime.hostTime` plus the sample offset within the buffer. Everything
after that — dispatching to the UI, formatting the number — happens well after
the timestamp is captured and cannot move it.

**T0 is the moment the microphone hears the buzzer**, not the moment the buzzer
was scheduled. Start and stop then travel the same speaker → air → microphone →
input-buffer path, so output and input latency cancel exactly rather than being
estimated. If the mic can't hear the buzzer (headphones), it falls back to the
scheduled time corrected by `AVAudioSession.outputLatency`, which is good to a
few milliseconds on wired routes.

**Do not use Bluetooth headphones.** Their output latency is 100–200 ms and
unstable, which breaks both references. The app detects a Bluetooth route and
warns you. Use the speaker or wired earbuds.

**The threshold recalibrates before every buzzer.** The app measures the room's
noise floor during the standby window and sets the trigger at 6× that, floored
at 0.06, divided by your sensitivity setting. A quiet room and a loud bay both
work without you touching a slider.

**Blanking** ignores the first 350 ms after T0 so the buzzer doesn't stop its
own timer. It also means a shot inside that window can't be detected. Shorten it
if you're using headphones and the buzzer isn't bleeding into the mic.

### Known limits

- Live fire: a gunshot is a huge transient and detects reliably, but ear
  protection over the phone's mic or a shooter on the next lane can both fool a
  simple threshold. The app has no way to tell your shot from your neighbour's.
- **Shot dead time** (Settings › Shot detection) is how long the detector
  ignores the mic after each shot, so one shot reports once instead of once per
  threshold crossing. A gunshot is a 1–3 ms transient, so live fire wants
  ~100 ms. A shouted "Bang!" lasts 300–500 ms and needs ~300 ms, or one shout
  counts as several shots. No single value serves both — set it for how you are
  practising. Default is 300 ms, tuned for dry practice.
- **Splits measured by shouting are your speech cadence, not your shooting.**
  The split feature is only meaningful with live fire (or dry-fire with an
  audible trigger/steel). Treat shouted splits as a smoke test of the plumbing.
- **"Do over" during a run is detected as shots**, because your voice crosses
  the same threshold. That is unavoidable with one microphone and it does not
  matter — the run is voided. It does mean the phrase can finish a nearly
  complete string before recognition lands, so "do over" stays live through the
  result pause and readback and will still void the result.
- `.measurement` audio mode disables AGC and noise suppression, which is what
  makes absolute thresholding meaningful. It also makes the buzzer quieter than
  a normal app's audio. Turn the phone volume up.

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
  Resources/
    tasks.txt                  default task list
```
