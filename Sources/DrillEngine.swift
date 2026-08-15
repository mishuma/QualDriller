import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// The examiner.
///
/// Per task:
///   1. read the command
///   2. "Shooter ready?"
///   3. shooter answers Yes / No / Repeat Command  (anything else -> "I don't understand")
///   4. Yes  -> delay, buzzer, timer runs until the last shot
///      No   -> wait for "I'm ready", then as above
///      Repeat -> start again from step 1
///   5. read the time back
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

    enum TimerTint { case neutral, running, pass, fail }

    struct LogLine: Identifiable {
        let id = UUID()
        let who: String     // "EXAM" | "YOU" | ""
        let text: String
    }

    // MARK: - Settings
    //
    // Deliberately @Published + UserDefaults rather than @AppStorage:
    // @AppStorage is a DynamicProperty and only works inside a View, so it
    // would neither persist nor vend the `$engine.x` bindings the settings
    // screen needs.

    private static let d = UserDefaults.standard

    @Published var useRandomDelay: Bool { didSet { Self.d.set(useRandomDelay, forKey: "useRandomDelay") } }
    @Published var fixedDelay: Double   { didSet { Self.d.set(fixedDelay, forKey: "fixedDelay") } }
    @Published var sensitivity: Double  { didSet { Self.d.set(sensitivity, forKey: "sensitivity") } }
    @Published var blankingMs: Double   { didSet { Self.d.set(blankingMs, forKey: "blankingMs") } }
    @Published var maxRunSeconds: Double { didSet { Self.d.set(maxRunSeconds, forKey: "maxRunSeconds") } }
    @Published var shuffle: Bool        { didSet { Self.d.set(shuffle, forKey: "shuffle") } }
    @Published var speakAloud: Bool     { didSet { Self.d.set(speakAloud, forKey: "speakAloud") } }
    @Published var readBackTime: Bool   { didSet { Self.d.set(readBackTime, forKey: "readBackTime") } }
    @Published var listenForVoice: Bool { didSet { Self.d.set(listenForVoice, forKey: "listenForVoice") } }

    // MARK: - Collaborators

    let audio = AudioCore()
    let voice = VoiceCommands()
    let speaker = Speaker()

    private var sessionTask: Task<Void, Never>?
    private var aborted = false

    private enum InputResult { case command(DrillCommand), unrecognized, aborted }
    private var inputContinuation: CheckedContinuation<InputResult, Never>?

    private var detectContinuation: CheckedContinuation<UInt64?, Never>?
    private var detectTimeout: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var lastStopWasManual = false

    // MARK: - Setup

    init() {
        let d = Self.d
        d.register(defaults: [
            "useRandomDelay": true, "fixedDelay": 2.0, "sensitivity": 1.0,
            "blankingMs": 350.0, "maxRunSeconds": 30.0, "shuffle": false,
            "speakAloud": true, "readBackTime": true, "listenForVoice": true
        ])
        useRandomDelay = d.bool(forKey: "useRandomDelay")
        fixedDelay     = d.double(forKey: "fixedDelay")
        sensitivity    = d.double(forKey: "sensitivity")
        blankingMs     = d.double(forKey: "blankingMs")
        maxRunSeconds  = d.double(forKey: "maxRunSeconds")
        shuffle        = d.bool(forKey: "shuffle")
        speakAloud     = d.bool(forKey: "speakAloud")
        readBackTime   = d.bool(forKey: "readBackTime")
        listenForVoice = d.bool(forKey: "listenForVoice")

        tasks = TaskList.loadSaved() ?? TaskList.bundled()
        commandText = "\(tasks.count) tasks loaded. Press Start."

        audio.onLevel = { [weak self] p in
            Task { @MainActor in self?.level = p }
        }
        audio.onDetect = { [weak self] host in
            Task { @MainActor in self?.resolveDetection(host) }
        }
        // Captured directly, not through `self`: this runs on the audio render
        // thread and must not touch main-actor state.
        let voiceRef = voice
        audio.onMicBuffer = { buf in
            voiceRef.feed(buf)             // lock-guarded, no actor hop
        }
        voice.onCommand = { [weak self] cmd in
            self?.log("YOU", Self.describe(cmd))
            self?.deliver(.command(cmd))
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
                   + "The drill still runs — use Stop Timer to mark the last shot."
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
        sessionTask = Task { await runSession() }
    }

    func stopSession() {
        aborted = true
        speaker.cancel()
        voice.stop()
        audio.disarm()
        stopTicker()
        deliver(.aborted)
        resolveDetection(nil)
        sessionTask?.cancel()
        sessionTask = nil
        isRunning = false
        phase = "idle"
        hint = ""
        commandText = "Session stopped."
    }

    /// Manual fallback for the stop signal — always available.
    func manualStop() {
        guard detectContinuation != nil, phase == "timing" else { return }
        lastStopWasManual = true
        resolveDetection(AudioCore.now())
    }

    func answer(_ cmd: DrillCommand) {
        log("YOU", Self.describe(cmd) + "  (button)")
        voice.stop()
        deliver(.command(cmd))
    }

    // MARK: - The drill

    private func runSession() async {
        speaker.enabled = speakAloud

        var order = Array(tasks.indices)
        if shuffle { order.shuffle() }

        for (i, idx) in order.enumerated() {
            if aborted { break }
            await runTask(tasks[idx], number: i + 1, total: order.count)
            if aborted { break }
            try? await Task.sleep(for: .milliseconds(700))
        }

        voice.stop()
        isRunning = false
        phase = "idle"
        hint = ""
        if !aborted {
            commandText = "Session complete."
            await speaker.say("Session complete.")
        }
    }

    private func runTask(_ task: DrillTask, number: Int, total: Int) async {
        verdict = ""
        timerText = "0.00"
        timerTint = .neutral
        transcript = ""
        lastStopWasManual = false

        // ---- steps 1-3: read the command, ask, take the answer -----------
        commandLoop: while !aborted {
            phase = "reading command"
            hint = "task \(number) of \(total)"
            commandText = task.text
            voice.stop()
            log("EXAM", task.text)
            await speaker.say(task.text)
            if aborted { return }

            log("EXAM", "Shooter ready?")
            await speaker.say("Shooter ready?")
            if aborted { return }

            phase = "awaiting reply"
            hint = "say “yes”, “no”, or “repeat command”"

            switch await awaitAnswer(expectingReady: false) {
            case .aborted:
                return
            case .command(.repeatCommand):
                continue commandLoop
            case .command(.no):
                phase = "standing by"
                hint = "say “I'm ready” when set"
                log("EXAM", "Standing by.")
                await speaker.say("Standing by.")
                if aborted { return }
                if case .aborted = await awaitAnswer(expectingReady: true) { return }
                break commandLoop
            case .command(.yes), .command(.ready):
                break commandLoop
            case .unrecognized:
                continue commandLoop     // unreachable; awaitAnswer retries internally
            }
        }
        if aborted { return }

        voice.stop()

        // ---- step 4: delay, buzzer, timer --------------------------------
        let delay = useRandomDelay ? Double.random(in: 2.0...4.0) : max(0.6, fixedDelay)
        phase = "standby"
        hint = "wait for the buzzer"

        // Learn the room's noise floor during the standby window so the
        // threshold adapts to a quiet living room or a loud range bay.
        audio.beginCalibration()
        try? await Task.sleep(for: .seconds(max(0.35, delay - 0.30)))
        if aborted { return }
        let noise = audio.endCalibration()
        let threshold = min(0.95, max(0.015, max(noise * 6, 0.06) / Float(sensitivity)))

        let scheduled = audio.scheduleBuzz(lead: 0.30)

        // Reference T0 to the microphone hearing the buzzer. Start and stop then
        // share one acoustic + input path and the latencies cancel exactly.
        audio.arm(fromHost: scheduled, threshold: max(threshold, 0.22))
        let heard = await awaitDetection(timeout: 0.80)
        audio.disarm()
        if aborted { return }

        let t0: UInt64
        let reference: String
        if let heard {
            t0 = heard
            reference = "mic-referenced"
        } else {
            // Headphones, or the buzzer was too quiet to detect. Fall back to the
            // scheduled time corrected for output latency — good to a few ms on
            // wired routes, poor over Bluetooth.
            t0 = scheduled &+ AudioCore.secToHost(audio.outputLatency)
            reference = String(format: "scheduled +%.0fms", audio.outputLatency * 1000)
        }

        phase = "timing"
        hint = "yell “Bang!” on the last shot"
        startTicker(from: t0)
        audio.arm(fromHost: t0 &+ AudioCore.secToHost(blankingMs / 1000), threshold: threshold)

        let shot = await awaitDetection(timeout: maxRunSeconds)
        audio.disarm()
        stopTicker()
        if aborted { return }

        // ---- step 5: report ----------------------------------------------
        let elapsed = shot.map { AudioCore.elapsed(from: t0, to: $0) }
        var verdictText: String

        if let elapsed, elapsed > 0 {
            timerText = String(format: "%.2f", elapsed)
            if let par = task.par {
                if elapsed <= par {
                    verdictText = "PASS"
                    timerTint = .pass
                    verdict = "PASS"
                } else {
                    verdictText = "FAIL"
                    timerTint = .fail
                    verdict = String(format: "FAIL  (+%.2fs)", elapsed - par)
                }
            } else {
                verdictText = "—"
                timerTint = .neutral
                verdict = ""
            }
            phase = "result"
            hint = lastStopWasManual
                ? "stopped manually"
                : String(format: "%@ · threshold %.3f", reference, threshold)

            if readBackTime {
                var phrase = String(format: "%.2f seconds", elapsed)
                if let par = task.par {
                    phrase += verdictText == "PASS"
                        ? ". Pass."
                        : String(format: ". Fail. Par was %.1f seconds.", par)
                }
                log("EXAM", phrase)
                await speaker.say(phrase)
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
                                 time: (elapsed ?? 0) > 0 ? elapsed : nil,
                                 verdict: verdictText,
                                 manual: lastStopWasManual))
    }

    // MARK: - Awaiting the shooter's answer

    /// Loops on "I don't understand" per the spec until a real command arrives.
    private func awaitAnswer(expectingReady: Bool) async -> InputResult {
        while !aborted {
            let r = await awaitOneAnswer(expectingReady: expectingReady)
            switch r {
            case .command, .aborted:
                return r
            case .unrecognized:
                log("EXAM", "I don't understand.")
                await speaker.say("I don't understand.")
            }
        }
        return .aborted
    }

    private func awaitOneAnswer(expectingReady: Bool) async -> InputResult {
        transcript = ""
        if listenForVoice { voice.start(expectingReady: expectingReady) }
        return await withCheckedContinuation { c in
            self.inputContinuation = c
        }
    }

    private func deliver(_ r: InputResult) {
        guard let c = inputContinuation else { return }
        inputContinuation = nil
        c.resume(returning: r)
    }

    // MARK: - Awaiting a threshold crossing

    private func awaitDetection(timeout: Double) async -> UInt64? {
        await withCheckedContinuation { c in
            self.detectContinuation = c
            self.detectTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.resolveDetection(nil)   // Task inherits @MainActor here
            }
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
            banner = "No tasks found in that file. Expected one task per line, optionally numbered."
            return
        }
        tasks = parsed
        try? TaskList.save(text)
        banner = nil
        commandText = "\(tasks.count) tasks loaded. Press Start."
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
        case .no: return "No"
        case .repeatCommand: return "Repeat command"
        case .ready: return "I'm ready"
        }
    }
}
