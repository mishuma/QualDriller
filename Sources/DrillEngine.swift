import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// The examiner.
///
/// Per task:
///   0. QUEUED — the drill is named on screen but nothing has been read out and
///      nothing is armed. "Start" (or the Start button) begins it; the arrows
///      move to the next or previous drill without shooting this one; Reload
///      refills all magazines. This is the only phase in which any of those
///      three things can happen, and it is entered before every task.
///   1. read the command
///   2. "Shooter ready?" (or "Standby.", per `readyPrompt`)
///   3. shooter answers Yes / No (= Pause) / Repeat command / Do over
///      (Reload is a queued-state button only — see refillAll)
///        Yes      -> delay, buzzer, timed string
///        No       -> pause in place; Yes resumes to the buzzer, Repeat re-reads
///        Repeat   -> start again from step 1
///        Do over  -> see below
///        anything else -> "I don't understand", keep listening
///   4. the string runs until the expected shot count is reached, or the shooter
///      taps Stop, or says "do over", or the run times out
///   5. read the time back
///
/// "Do over" means "the last thing I attempted, again":
///   * said while a string is running -> that run is voided and re-run
///   * said at any other time         -> go back to the most recently shot drill
@MainActor
final class DrillEngine: ObservableObject {

    // MARK: - Published UI state

    @Published var phase: String = "idle"
    @Published var hint: String = ""
    @Published var commandText: String = "Load a task list, then press Start."
    @Published var timerText: String = "0.00"
    @Published var timerTint: TimerTint = .neutral
    @Published var verdict: String = ""
    @Published var transcript: String = ""
    @Published var level: Float = 0
    @Published var results: [RunResult] = []
    @Published var tasks: [DrillTask] = []
    @Published var isRunning = false
    @Published var banner: String?
    @Published var logLines: [LogLine] = []
    /// Cumulative shot times for the string in progress, for the live readout.
    @Published var liveShots: [Double] = []
    @Published var expectedShots: ShotCount = .fixed(1)
    @Published var ammo: AmmoState = .loaded(AmmoState.defaultCapacities)
    /// Position in the running order while queued, so the arrows can be
    /// disabled at the ends rather than silently doing nothing.
    @Published var queuedIndex = 0
    @Published var queuedCount = 0

    var canGoNext: Bool { phase == "queued" && queuedIndex + 1 < queuedCount }
    var canGoPrev: Bool { phase == "queued" && queuedIndex > 0 }

    enum TimerTint { case neutral, running, pass, fail }

    /// What the examiner says after reading the command. Wording only — the
    /// drill still waits for an answer either way.
    enum ReadyPrompt: String, CaseIterable, Identifiable {
        case shooterReady, standby
        var id: String { rawValue }
        var title: String { self == .shooterReady ? "Shooter ready?" : "Standby." }
        var spoken: String { title }
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let who: String     // "EXAM" | "YOU" | ""
        let text: String
    }

    // MARK: - Settings
    //
    // @Published + UserDefaults rather than @AppStorage: @AppStorage is a
    // DynamicProperty and only works inside a View, so it would neither persist
    // here nor vend the `$engine.x` bindings the settings screen needs.

    private static let d = UserDefaults.standard

    @Published var useRandomDelay: Bool { didSet { Self.d.set(useRandomDelay, forKey: "useRandomDelay") } }
    @Published var fixedDelay: Double   { didSet { Self.d.set(fixedDelay, forKey: "fixedDelay") } }
    @Published var sensitivity: Double  { didSet { Self.d.set(sensitivity, forKey: "sensitivity") } }
    @Published var blankingMs: Double   { didSet { Self.d.set(blankingMs, forKey: "blankingMs") } }
    @Published var maxRunSeconds: Double { didSet { Self.d.set(maxRunSeconds, forKey: "maxRunSeconds") } }
    @Published var resultPause: Double  { didSet { Self.d.set(resultPause, forKey: "resultPause") } }
    @Published var shuffle: Bool        { didSet { Self.d.set(shuffle, forKey: "shuffle") } }
    @Published var speakAloud: Bool     { didSet { Self.d.set(speakAloud, forKey: "speakAloud") } }
    @Published var readBackTime: Bool   { didSet { Self.d.set(readBackTime, forKey: "readBackTime") } }
    @Published var listenForVoice: Bool { didSet { Self.d.set(listenForVoice, forKey: "listenForVoice") } }
    /// Dead time after each detected shot. See AudioCore.arm — live fire wants
    /// ~100 ms, shouting "Bang!" wants ~300 ms.
    @Published var refractoryMs: Double { didSet { Self.d.set(refractoryMs, forKey: "refractoryMs") } }
    /// Rounds loaded into magazines 1, 2, 3 at the start of every session.
    @Published var magCapacities: [Int] { didSet { Self.d.set(magCapacities, forKey: "magCapacities") } }
    /// Swap to the next magazine automatically when the current one runs dry.
    /// Without this, live fire would require narrating every reload out loud.
    @Published var autoAdvanceOnEmpty: Bool { didSet { Self.d.set(autoAdvanceOnEmpty, forKey: "autoAdvanceOnEmpty") } }
    /// Hard floor under the calibrated threshold. The threshold is derived from
    /// the room's noise floor, which in a quiet bay lands far below a gunshot
    /// and well within reach of a holster draw. Raising the floor is the blunt
    /// fix for that and costs nothing in timing accuracy.
    @Published var minThreshold: Double { didSet { Self.d.set(minThreshold, forKey: "minThreshold") } }
    /// Reject crossings that are not impulsive. See AudioCore.arm.
    @Published var impulseGate: Bool    { didSet { Self.d.set(impulseGate, forKey: "impulseGate") } }
    @Published var impulseRatio: Double { didSet { Self.d.set(impulseRatio, forKey: "impulseRatio") } }
    /// Log the measured impulse ratio for every detection and every rejection,
    /// which is the only way to pick a ratio from real range data.
    @Published var logImpulse: Bool     { didSet { Self.d.set(logImpulse, forKey: "logImpulse") } }
    /// Wording of the prompt after the command is read.
    @Published var readyPrompt: ReadyPrompt {
        didSet { Self.d.set(readyPrompt.rawValue, forKey: "readyPrompt") }
    }
    /// Which of the two curated voices the examiner speaks with.
    @Published var voicePreference: Speaker.VoicePreference {
        didSet {
            Self.d.set(voicePreference.rawValue, forKey: "voicePreference")
            speaker.preference = voicePreference
        }
    }

    // MARK: - Collaborators

    let audio = AudioCore()
    let voice = VoiceCommands()
    let speaker = Speaker()

    private var sessionTask: Task<Void, Never>?
    private var aborted = false

    /// Bumped by every start and every stop. A session task carries the value it
    /// was born with and dies the moment it no longer matches, so a task that was
    /// suspended when the session ended can never resurrect and drive the UI —
    /// which is what made End Session look intermittent.
    private var generation = 0

    private func alive(_ gen: Int) -> Bool { !aborted && gen == generation }

    private enum InputResult { case command(DrillCommand), unrecognized, aborted }
    private var inputContinuation: CheckedContinuation<InputResult, Never>?

    private var detectContinuation: CheckedContinuation<UInt64?, Never>?
    private var detectTimeout: Task<Void, Never>?
    /// Detections that landed while nothing was awaiting one. Without this a
    /// shot fired in the gap between two awaits would be dropped, which matters
    /// now that we collect a whole string.
    private var pendingDetections: [UInt64] = []

    private var ticker: Task<Void, Never>?
    private var manualEndRequested = false
    private var doOverRequested = false

    // Live string state. These are engine properties rather than locals in
    // runTask because the reload handler mutates them from a voice callback
    // while the collection loop is suspended on a detection.
    private var runShotHosts: [UInt64] = []
    private var runShotConsumed: [Bool] = []
    private var runReloads: [Double] = []
    private var runT0: UInt64?
    private var ammoAtRunStart: AmmoState?

    private enum TaskOutcome {
        case completed
        case doOver(duringRun: Bool)
        case stopped
    }

    // MARK: - Setup

    init() {
        let d = Self.d
        d.register(defaults: [
            "useRandomDelay": true, "fixedDelay": 2.0, "sensitivity": 1.0,
            "blankingMs": 350.0, "maxRunSeconds": 30.0, "shuffle": false,
            "speakAloud": true, "readBackTime": true, "listenForVoice": true,
            "resultPause": 1.2, "refractoryMs": 300.0,
            "magCapacities": AmmoState.defaultCapacities, "autoAdvanceOnEmpty": true,
            // The gate ships OFF. Its ratio has never been measured against a
            // real gunshot or a real holster, and a wrong value deletes shots
            // silently — which is worse than the false holster shot it fixes.
            // Turn on logging, shoot one string, then set it from the numbers.
            "minThreshold": 0.0, "impulseGate": false, "impulseRatio": 6.0,
            "logImpulse": true, "readyPrompt": ReadyPrompt.shooterReady.rawValue
        ])
        useRandomDelay = d.bool(forKey: "useRandomDelay")
        fixedDelay     = d.double(forKey: "fixedDelay")
        sensitivity    = d.double(forKey: "sensitivity")
        blankingMs     = d.double(forKey: "blankingMs")
        maxRunSeconds  = d.double(forKey: "maxRunSeconds")
        resultPause    = d.double(forKey: "resultPause")
        refractoryMs   = d.double(forKey: "refractoryMs")
        shuffle        = d.bool(forKey: "shuffle")
        speakAloud     = d.bool(forKey: "speakAloud")
        readBackTime   = d.bool(forKey: "readBackTime")
        listenForVoice = d.bool(forKey: "listenForVoice")
        magCapacities  = (d.array(forKey: "magCapacities") as? [Int]) ?? AmmoState.defaultCapacities
        autoAdvanceOnEmpty = d.bool(forKey: "autoAdvanceOnEmpty")
        minThreshold   = d.double(forKey: "minThreshold")
        impulseGate    = d.bool(forKey: "impulseGate")
        impulseRatio   = d.double(forKey: "impulseRatio")
        logImpulse     = d.bool(forKey: "logImpulse")
        readyPrompt = ReadyPrompt(rawValue: d.string(forKey: "readyPrompt") ?? "") ?? .shooterReady
        voicePreference = Speaker.VoicePreference(
            rawValue: d.string(forKey: "voicePreference") ?? "") ?? .male
        ammo = .loaded((d.array(forKey: "magCapacities") as? [Int]) ?? AmmoState.defaultCapacities)

        tasks = TaskList.loadSaved() ?? TaskList.bundled()
        commandText = "\(tasks.count) tasks loaded. Press Start."

        audio.onLevel = { [weak self] p in
            Task { @MainActor in self?.level = p }
        }
        audio.onDetect = { [weak self] host, ratio in
            Task { @MainActor in self?.deliverDetection(host, ratio: ratio) }
        }
        audio.onReject = { [weak self] ratio in
            Task { @MainActor in
                guard let self, self.logImpulse else { return }
                self.log("", String(format: "ignored — impulse %.1f× (gate %.1f×)",
                                    ratio, self.impulseRatio))
            }
        }
        // Captured directly, not through `self`: this runs on the audio render
        // thread and must not touch main-actor state.
        let voiceRef = voice
        audio.onMicBuffer = { buf in
            voiceRef.feed(buf)             // lock-guarded, no actor hop
        }
        voice.onCommand = { [weak self] cmd in
            guard let self else { return }
            self.log("YOU", Self.describe(cmd))
            if cmd == .doOver {
                self.requestDoOver()
            } else {
                self.deliver(.command(cmd))
            }
        }
        voice.onUnrecognized = { [weak self] text in
            self?.log("YOU", text)
            self?.deliver(.unrecognized)
        }
        voice.onTranscript = { [weak self] text in
            self?.transcript = text
        }
    }

    func prepare() async {
        await voice.requestAuthorization()
        do {
            try audio.start()
        } catch {
            banner = "Could not start audio: \(error.localizedDescription). "
                   + "The drill still runs — use Stop to mark the last shot."
        }
        if let reason = voice.unavailableReason {
            banner = reason
            listenForVoice = false
        } else if audio.isBluetoothOutput {
            banner = "Bluetooth audio is connected. Its latency is large and unstable, "
                   + "which corrupts the timing. Use the speaker or wired headphones."
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - Session control

    func start() {
        guard !isRunning, !tasks.isEmpty else { return }
        aborted = false
        isRunning = true
        logLines.removeAll()
        // Ammunition is session-scoped: magazines are filled once here and
        // deplete across every drill until the session ends.
        ammo = .loaded(magCapacities)
        log("EXAM", "Loaded \(magCapacities.prefix(3).map(String.init).joined(separator: " / ")).")

        speaker.resume()
        speaker.preference = voicePreference
        generation += 1
        let gen = generation
        sessionTask = Task { await runSession(gen) }
    }

    /// Ends the session immediately and unconditionally, from any phase.
    ///
    /// Order matters. `generation` is bumped first so any task that wakes up
    /// mid-teardown sees itself as stale; `speaker.cancel()` latches the
    /// synthesiser off so queued lines never start; then both continuations are
    /// resolved so a task suspended on an answer or a shot resumes and exits.
    func stopSession() {
        generation += 1
        aborted = true
        doOverRequested = false
        manualEndRequested = false

        speaker.cancel()
        voice.stop()
        audio.disarm()
        stopTicker()

        deliver(.aborted)
        resolveDetection(nil)
        pendingDetections.removeAll()

        sessionTask?.cancel()
        sessionTask = nil

        isRunning = false
        phase = "idle"
        hint = ""
        expectedShots = .fixed(1)
        liveShots = []
        queuedCount = 0
        commandText = "Session stopped."
        log("EXAM", "Session ended.")
    }

    // MARK: - Queued-state controls
    //
    // All three are legal only while queued. Advancing the running order or
    // re-loading every magazine in the middle of a timed string would corrupt
    // the run, so the guard is here rather than in the view.

    func queuedNext() { guard canGoNext else { return }; answer(.nextTask) }
    func queuedPrev() { guard canGoPrev else { return }; answer(.prevTask) }

    /// REFILL — top every magazine back up to its configured capacity and go
    /// back to magazine one, un-retiring the ones already swapped past.
    ///
    /// Queued state only. This is the shooter off the clock, picking their
    /// magazines up off the ground and refilling them. It is a different verb
    /// from RELOAD (`reloadNow`) on purpose: refilling the magazines is not
    /// reloading the gun, and the two must never be reachable from the same
    /// phase or they will be pressed interchangeably.
    func refillAll() {
        guard phase == "queued" else { return }
        ammo.refill(to: magCapacities)
        log("EXAM", "Refill — \(magCapacities.prefix(3).map(String.init).joined(separator: " / ")).")
    }

    /// Manual fallback for the end of a string — always available.
    func stopString() {
        guard phase == "timing" else { return }
        manualEndRequested = true
        deliverDetection(AudioCore.now(), ratio: 0)
    }

    func answer(_ cmd: DrillCommand) {
        log("YOU", Self.describe(cmd) + "  (button)")
        if cmd == .doOver {
            requestDoOver()
        } else {
            voice.stop()
            deliver(.command(cmd))
        }
    }

    /// RELOAD — swap the magazine in the gun for the next one. Timed string
    /// only, and a button only.
    ///
    /// Timed only because reloading the gun is something you do on the clock;
    /// between drills the operation you want is REFILL (`refillAll`), which is
    /// a different verb and lives in a different phase so the two can never be
    /// confused for one another.
    ///
    /// Button only because there is no voice "reload" and there must not be
    /// one. The shout itself crosses the amplitude threshold and is counted as
    /// a shot, because the detector hears loudness and not words. The
    /// retroactive un-count that once compensated for that could delete a
    /// genuine shot fired inside the window, so the command and the heuristic
    /// were both removed.
    func reloadNow() {
        guard phase == "timing" else { return }

        // A reload with rounds still in the gun is a tactical reload (or a
        // ditched magazine after a malfunction). The abandoned rounds are gone
        // — that magazine is on the ground and is never used again this string.
        // REFILL is what puts them back, and only between drills.
        let abandoned = ammo.roundsInCurrent

        guard ammo.reload() else {
            log("EXAM", "No magazines remaining.")
            return
        }
        let mag = ammo.currentMagazine
        var line = "Reload — magazine \(mag?.id ?? 0), \(mag?.rounds ?? 0) rounds."
        if abandoned > 0 { line += " \(abandoned) abandoned." }
        log("EXAM", line)
        if let t0 = runT0 {
            runReloads.append(AudioCore.elapsed(from: t0, to: AudioCore.now()))
        }
    }

    private func requestDoOver() {
        doOverRequested = true
        voice.stop()
        speaker.cancel()
        if phase == "timing" {
            resolveDetection(nil)          // break the collection loop
        } else {
            deliver(.command(.doOver))
        }
    }

    // MARK: - The drill

    private func runSession(_ gen: Int) async {
        speaker.enabled = speakAloud

        var order = Array(tasks.indices)
        if shuffle { order.shuffle() }

        var i = 0
        var lastShotIndex: Int?

        // Every task is entered through the queued state, including a task being
        // re-run after a do-over. Nothing is armed and nothing is spoken until
        // the shooter says Start, so the gun can be holstered, the magazines
        // topped off, or the drill skipped, without the clock caring.
        sessionLoop: while alive(gen) {
            if order.isEmpty || i >= order.count { break sessionLoop }
            if i < 0 { i = 0 }

            switch await awaitQueued(tasks[order[i]], number: i + 1, total: order.count, gen: gen) {
            case .aborted:
                return
            case .next:
                i = min(i + 1, order.count - 1)     // clamps: no wrap at the ends
                continue sessionLoop
            case .prev:
                i = max(i - 1, 0)
                continue sessionLoop
            case .start:
                break
            }

            switch await runTask(tasks[order[i]], number: i + 1, total: order.count, gen: gen) {
            case .stopped:
                return
            case .completed:
                lastShotIndex = i
                i += 1
            case .doOver(let duringRun):
                // During a run: re-run this one. Otherwise: back to whatever was
                // last actually shot, which is what "do over" means out loud.
                if !duringRun, let last = lastShotIndex { i = last }
                log("EXAM", "Do over.")
                await speaker.say("Do over.")
            }
        }

        voice.stop()
        isRunning = false
        phase = "idle"
        hint = ""
        expectedShots = .fixed(1)
        queuedCount = 0
        if !aborted {
            commandText = "Session complete."
            await speaker.say("Session complete.")
        }
    }

    private enum QueuedOutcome { case start, next, prev, aborted }

    /// Holds before a drill until the shooter says Start, or arrows away.
    ///
    /// Nothing is spoken here on purpose. The examiner reading the command is
    /// step 1, and the whole point of this state is that the shooter controls
    /// when that happens — so the drill is shown, not read.
    private func awaitQueued(_ task: DrillTask, number: Int, total: Int,
                             gen: Int) async -> QueuedOutcome {
        phase = "queued"
        commandText = task.text
        hint = "task \(number) of \(total) · \(task.shotsLabel) · “start”"
        queuedIndex = number - 1
        queuedCount = total
        verdict = ""
        transcript = ""
        timerText = "0.00"
        timerTint = .neutral
        liveShots = []
        expectedShots = task.shots

        while alive(gen) {
            let result: InputResult = await withCheckedContinuation { c in
                self.inputContinuation = c
                if listenForVoice { voice.start(mode: .queued) }
            }
            voice.stop()
            switch result {
            case .aborted:                 return .aborted
            case .command(.start):         return .start
            case .command(.nextTask):      return .next
            case .command(.prevTask):      return .prev
            // Nothing else can arrive: `.queued` mode classifies only "start"
            // and never reports an unrecognised utterance. Keep waiting.
            default:                       continue
            }
        }
        return .aborted
    }

    private func runTask(_ task: DrillTask, number: Int, total: Int, gen: Int) async -> TaskOutcome {
        verdict = ""
        timerText = "0.00"
        timerTint = .neutral
        transcript = ""
        liveShots = []
        expectedShots = task.shots
        manualEndRequested = false
        doOverRequested = false

        // ---- steps 1-3: read the command, ask, take the answer -------------
        commandLoop: while alive(gen) {
            phase = "reading command"
            hint = "task \(number) of \(total) · \(task.shotsLabel)"
            commandText = task.text
            voice.stop()
            log("EXAM", task.text)
            await speaker.say(task.text)
            if !alive(gen) { return .stopped }

            log("EXAM", readyPrompt.spoken)
            await speaker.say(readyPrompt.spoken)
            if !alive(gen) { return .stopped }

            phase = "awaiting reply"
            hint = "“yes” · “pause” · “repeat command” · “do over”"

            switch await awaitAnswer() {
            case .aborted:
                return .stopped
            case .doOver:
                return .doOver(duringRun: false)
            case .repeatCommand:
                continue commandLoop
            case .no:
                // Pause in place. No separate "I'm ready" step any more — the
                // same vocabulary resumes, re-reads, or bails out.
                phase = "paused"
                hint = "“yes” to continue · “repeat command” · “do over”"
                log("EXAM", "Paused.")
                await speaker.say("Paused.")
                if !alive(gen) { return .stopped }

                pauseLoop: while alive(gen) {
                    switch await awaitAnswer() {
                    case .aborted:         return .stopped
                    case .doOver:          return .doOver(duringRun: false)
                    case .repeatCommand:   continue commandLoop
                    case .yes:             break pauseLoop
                    case .no:
                        log("EXAM", "Still paused.")
                        await speaker.say("Still paused.")
                    }
                }
                break commandLoop
            case .yes:
                break commandLoop
            }
        }
        if !alive(gen) { return .stopped }

        voice.stop()

        // ---- step 4: delay, buzzer, timed string ---------------------------
        // Ending here beats letting the shooter stand through a 30 s timeout
        // with an empty gun.
        if ammo.totalRemaining <= 0 {
            phase = "out of ammunition"
            hint = "all magazines spent — End Session or restart"
            commandText = "Out of ammunition."
            log("EXAM", "Out of ammunition.")
            await speaker.say("Out of ammunition.")
            aborted = true
            return .stopped
        }

        let delay = useRandomDelay ? Double.random(in: 2.0...4.0) : max(0.6, fixedDelay)
        phase = "standby"
        hint = "wait for the buzzer · \(task.shotsLabel)"

        audio.beginCalibration()
        try? await Task.sleep(for: .seconds(max(0.35, delay - 0.30)))
        if !alive(gen) { return .stopped }
        let noise = audio.endCalibration()
        // The floor is applied AFTER the sensitivity divisor, so it is a real
        // floor and not just another term the divisor can undo.
        let calibrated = max(0.015, max(noise * 6, 0.06) / Float(sensitivity))
        let threshold = min(0.95, max(calibrated, Float(minThreshold)))

        let scheduled = audio.scheduleBuzz(lead: 0.30)

        // T0 is the mic hearing the buzzer, so start and stop share one acoustic
        // path and the latencies cancel. Single-shot arm for this one.
        pendingDetections.removeAll()
        audio.arm(fromHost: scheduled, threshold: max(threshold, 0.22))
        let heard = await awaitDetection(timeout: 0.80)
        audio.disarm()
        if !alive(gen) { return .stopped }

        let t0: UInt64
        let reference: String
        if let heard {
            t0 = heard
            reference = "mic-referenced"
        } else {
            t0 = scheduled &+ AudioCore.secToHost(audio.outputLatency)
            reference = String(format: "scheduled +%.0fms", audio.outputLatency * 1000)
        }

        phase = "timing"
        hint = "\(task.shotsLabel) · RELOAD · “do over”"
        startTicker(from: t0)

        runShotHosts = []
        runShotConsumed = []
        runReloads = []
        runT0 = t0
        ammoAtRunStart = ammo

        pendingDetections.removeAll()
        audio.arm(fromHost: t0 &+ AudioCore.secToHost(blankingMs / 1000),
                  threshold: threshold,
                  refractory: max(0.02, refractoryMs / 1000),
                  impulse: impulseGate ? Float(impulseRatio) : 0)
        // "Do over" is the only thing heard here. Reload is the button beside
        // it, never a word. "Bang" and "Rack" need no recognition at all — they
        // are counted because they are loud, which is why a malfunction
        // clearance costs a round exactly like a shot does.
        if listenForVoice { voice.start(mode: .doOverOnly) }

        let deadline = AudioCore.now() &+ AudioCore.secToHost(maxRunSeconds)

        /// Has the string finished on its own terms?
        func stringComplete() -> Bool {
            switch task.shots {
            case .fixed(let want):
                return runShotHosts.count >= want
            case .magazine:
                return runShotConsumed.contains(true) && ammo.roundsInCurrent <= 0
            case .openEnded:
                return runShotConsumed.contains(true) && ammo.totalRemaining <= 0
            }
        }

        while alive(gen), !doOverRequested, !stringComplete() {
            let remaining = AudioCore.elapsed(from: AudioCore.now(), to: deadline)
            if remaining <= 0 { break }
            guard let t = await awaitDetection(timeout: remaining) else { break }
            if doOverRequested { break }

            // Every audible event costs a round: a shot fires one, a rack ejects
            // one. The detector cannot tell them apart and does not need to.
            var consumed = ammo.consume()
            if !consumed, autoAdvanceOnEmpty, ammo.hasSpareMagazine {
                ammo.reload()
                consumed = ammo.consume()
                runReloads.append(AudioCore.elapsed(from: t0, to: t))
                log("EXAM", "Magazine \(ammo.currentMagazine?.id ?? 0) (automatic).")
            }

            runShotHosts.append(t)
            runShotConsumed.append(consumed)
            liveShots = runShotHosts.map { AudioCore.elapsed(from: t0, to: $0) }
            if manualEndRequested { break }
        }

        audio.disarm()
        voice.stop()
        stopTicker()

        if !alive(gen) { return .stopped }
        if doOverRequested {
            // The run did not happen, so neither did the ammunition it burned.
            if let snapshot = ammoAtRunStart { ammo = snapshot }
            return .doOver(duringRun: true)
        }

        // ---- step 5: report -------------------------------------------------
        let shots = runShotHosts.map { AudioCore.elapsed(from: t0, to: $0) }.filter { $0 > 0 }
        liveShots = shots

        var verdictText: String
        if let total = shots.last {
            timerText = String(format: "%.2f", total)
            let wanted = task.shots.fixedValue
            let short = wanted.map { shots.count < $0 } ?? false

            if short, let wanted {
                verdictText = "SHORT"
                timerTint = .fail
                verdict = "SHORT — \(shots.count) of \(wanted) shots"
            } else if let par = task.par {
                if total <= par {
                    verdictText = "PASS"; timerTint = .pass; verdict = "PASS"
                } else {
                    verdictText = "FAIL"; timerTint = .fail
                    verdict = String(format: "FAIL  (+%.2fs)", total - par)
                }
            } else {
                verdictText = "—"; timerTint = .neutral; verdict = ""
            }

            phase = "result"
            hint = manualEndRequested
                ? "stopped manually"
                : String(format: "%@ · threshold %.3f · %d shot%@",
                         reference, threshold, shots.count, shots.count == 1 ? "" : "s")

            if readBackTime {
                // Keep listening: a late "do over" during the readback still
                // voids this result. Recognition can easily lag the last shot.
                if listenForVoice { voice.start(mode: .doOverOnly) }

                if resultPause > 0 {
                    try? await Task.sleep(for: .seconds(resultPause))
                }
                if !alive(gen) { return .stopped }
                if doOverRequested { voice.stop(); discardAttempt(); return .doOver(duringRun: false) }

                let timePhrase = String(format: "%.2f seconds", total)
                log("EXAM", timePhrase)
                await speaker.say(timePhrase)

                if !doOverRequested, verdictText != "—" {
                    try? await Task.sleep(for: .milliseconds(450))
                    if !alive(gen) { return .stopped }
                    let call: String
                    switch verdictText {
                    case "PASS":
                        call = "Pass."
                    case "SHORT":
                        call = "Short. \(shots.count) of \(task.shots.fixedValue ?? 0) shots."
                    default:
                        call = task.par.map { String(format: "Fail. Par was %.1f seconds.", $0) }
                             ?? "Fail."
                    }
                    log("EXAM", call)
                    await speaker.say(call)
                }
                voice.stop()
                if doOverRequested { discardAttempt(); return .doOver(duringRun: false) }
            }
        } else {
            verdictText = "DNF"
            timerText = "--.--"
            timerTint = .fail
            verdict = "NO SHOT DETECTED"
            phase = "result"
            hint = "timed out after \(Int(maxRunSeconds))s"
            log("EXAM", "No shot detected. Time out.")
            await speaker.say("No shot detected. Time out.")
        }

        results.append(RunResult(index: number,
                                 text: task.text,
                                 par: task.par,
                                 expected: task.shots,
                                 shots: shots,
                                 reloads: runReloads,
                                 verdict: verdictText,
                                 manual: manualEndRequested))

        // Breathing room before the next command. "Do over" is still live here.
        phase = "ready for next"
        hint = "“do over” to repeat this drill · \(ammo.totalRemaining) rounds left"
        if listenForVoice { voice.start(mode: .doOverOnly) }
        try? await Task.sleep(for: .seconds(max(1.4, resultPause)))
        voice.stop()
        if !alive(gen) { return .stopped }
        if doOverRequested {
            discardAttempt(removeLastResult: true)
            return .doOver(duringRun: false)
        }

        return .completed
    }

    /// A do-over means the attempt did not count: drop its recorded result and
    /// give back the ammunition it burned.
    private func discardAttempt(removeLastResult: Bool = false) {
        if removeLastResult, !results.isEmpty { results.removeLast() }
        if let snapshot = ammoAtRunStart { ammo = snapshot }
    }

    // MARK: - Awaiting the shooter's answer

    /// What the shooter can actually answer "Shooter ready?" with. Deliberately
    /// narrower than DrillCommand: reload is handled out of band and must not
    /// be mistaken for an answer.
    private enum Answer { case yes, no, repeatCommand, doOver, aborted }

    /// Loops on "I don't understand" per the spec until a real answer arrives.
    private func awaitAnswer() async -> Answer {
        while !aborted {
            switch await awaitOneAnswer() {
            case .aborted:                 return .aborted
            case .command(.yes):           return .yes
            case .command(.no):            return .no
            case .command(.repeatCommand): return .repeatCommand
            case .command(.doOver):        return .doOver
            // start / next / prev are queued-state only and cannot be produced
            // in `.answers` mode, but the switch has to be total.
            case .command:                 continue
            case .unrecognized:
                log("EXAM", "I don't understand.")
                await speaker.say("I don't understand.")
            }
        }
        return .aborted
    }

    private func awaitOneAnswer() async -> InputResult {
        transcript = ""
        return await withCheckedContinuation { c in
            self.inputContinuation = c
            // Started only after the continuation exists, so a fast answer
            // cannot be delivered into the void.
            if listenForVoice { voice.start(mode: .answers) }
        }
    }

    private func deliver(_ r: InputResult) {
        guard let c = inputContinuation else { return }
        inputContinuation = nil
        c.resume(returning: r)
    }

    // MARK: - Detection plumbing

    private func awaitDetection(timeout: Double) async -> UInt64? {
        if !pendingDetections.isEmpty {
            return pendingDetections.removeFirst()
        }
        return await withCheckedContinuation { c in
            self.detectContinuation = c
            self.detectTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.resolveDetection(nil)
            }
        }
    }

    /// A detection arrived from the audio thread. Hand it to whoever is waiting,
    /// or queue it so it isn't lost between two awaits.
    ///
    /// `ratio` is how impulsive the crossing was. It is logged rather than acted
    /// on here — the gate itself lives on the audio thread, because a decision
    /// made up here would already have lost the sample that justified it.
    private func deliverDetection(_ host: UInt64, ratio: Float) {
        if logImpulse, ratio > 0, phase == "timing" {
            log("", String(format: "shot %d — impulse %.1f×", runShotHosts.count + 1, ratio))
        }
        if detectContinuation != nil {
            resolveDetection(host)
        } else {
            pendingDetections.append(host)
        }
    }

    private func resolveDetection(_ host: UInt64?) {
        guard let c = detectContinuation else { return }
        detectContinuation = nil
        detectTimeout?.cancel()
        detectTimeout = nil
        c.resume(returning: host)
    }

    // MARK: - Live timer readout

    private func startTicker(from t0: UInt64) {
        stopTicker()
        timerTint = .running
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                let e = AudioCore.elapsed(from: t0, to: AudioCore.now())
                self?.timerText = String(format: "%.2f", max(0, e))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Misc

    func loadTasks(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            banner = "Could not read that file."
            return
        }
        let parsed = TaskList.parse(text)
        guard !parsed.isEmpty else {
            banner = "No tasks found in that file. Expected one task per line: "
                   + "text | par | shots"
            return
        }
        tasks = parsed
        try? TaskList.save(text)
        banner = nil
        commandText = "\(tasks.count) tasks loaded. Press Start."
    }

    /// Speaks a sample line so a voice can be judged before a session rather
    /// than discovered mid-drill.
    func previewVoice() {
        speaker.resume()
        speaker.enabled = true
        speaker.preference = voicePreference
        Task { await speaker.say("Shooter ready? Three point four two seconds. Pass.") }
    }

    func resetToBundled() {
        try? FileManager.default.removeItem(at: TaskList.savedURL)
        tasks = TaskList.bundled()
        commandText = "\(tasks.count) tasks loaded. Press Start."
    }

    private func log(_ who: String, _ text: String) {
        logLines.append(LogLine(who: who, text: text))
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }

    private static func describe(_ c: DrillCommand) -> String {
        switch c {
        case .yes: return "Yes"
        case .no: return "Pause"
        case .repeatCommand: return "Repeat command"
        case .doOver: return "Do over"
        case .start: return "Start"
        case .nextTask: return "Next drill"
        case .prevTask: return "Previous drill"
        }
    }
}
