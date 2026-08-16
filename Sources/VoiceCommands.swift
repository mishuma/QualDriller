import AVFoundation
import Foundation
import Speech

enum DrillCommand {
    case yes            // also "continue", "resume", "I'm ready"
    case no             // also "pause" — pauses in place
    case repeatCommand
    case doOver
}

extension VoiceCommands {
    /// What the recogniser will accept right now.
    enum Mode {
        /// The full vocabulary, used between runs.
        case answers
        /// Only "do over". Used while the timer is running and through the
        /// readback, where every other utterance must be ignored — including
        /// "Bang" and "Rack", which are counted by loudness and never by words.
        case doOverOnly
    }
}

/// Fully offline speech command recognition.
///
/// `requiresOnDeviceRecognition = true` is set unconditionally — this app must
/// work with no signal, so we would rather have recognition fail loudly than
/// silently reach for the network. The vocabulary is four phrases, so the
/// on-device model is more than adequate.
///
/// Never used for timing. See the timing contract in AudioCore.
@MainActor
final class VoiceCommands {

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// The audio tap runs on the render thread and cannot hop to the main actor
    /// without dropping buffers, so the live request is held in a small
    /// lock-guarded box that both threads may touch.
    private let live = LiveRequestBox()

    private final class LiveRequestBox: @unchecked Sendable {
        private var lock = os_unfair_lock_s()
        private var req: SFSpeechAudioBufferRecognitionRequest?
        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
            os_unfair_lock_lock(&lock); req = r; os_unfair_lock_unlock(&lock)
        }
        func append(_ b: AVAudioPCMBuffer) {
            os_unfair_lock_lock(&lock)
            let r = req
            os_unfair_lock_unlock(&lock)
            r?.append(b)
        }
    }

    /// Called with a matched command.
    var onCommand: ((DrillCommand) -> Void)?
    /// Called when the speaker clearly said something that isn't a command.
    var onUnrecognized: ((String) -> Void)?
    /// Live transcript, for the on-screen readout.
    var onTranscript: ((String) -> Void)?

    private var mode: Mode = .answers
    private var settleWork: DispatchWorkItem?
    private var latestTranscript = ""

    /// Milliseconds of silence after which an unmatched transcript is treated
    /// as final. Partial results are used for responsiveness, so we need our
    /// own end-of-utterance rule.
    var settleDelay: TimeInterval = 1.1

    // MARK: - Availability

    private(set) var micAuthorized = false
    private(set) var speechAuthorized = false

    var onDeviceAvailable: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    /// Non-nil when voice input cannot be used; the string explains why and is
    /// shown in the UI. The drill remains fully playable with the buttons.
    var unavailableReason: String? {
        if recognizer == nil { return "US English speech recognition is not available on this device." }
        if !speechAuthorized { return "Speech recognition permission was denied. Enable it in Settings › QualDriller." }
        if !micAuthorized { return "Microphone permission was denied. Enable it in Settings › QualDriller." }
        if !onDeviceAvailable {
            return "The offline speech model isn't installed. Connect to a network once, or turn on "
                 + "Settings › General › Keyboard › Enable Dictation, then relaunch. Until then use the buttons."
        }
        return nil
    }

    func requestAuthorization() async {
        speechAuthorized = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
        micAuthorized = await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { granted in
                c.resume(returning: granted)
            }
        }
    }

    // MARK: - Listening

    func start(mode: Mode) {
        stop()
        guard unavailableReason == nil, let recognizer, recognizer.isAvailable else { return }

        self.mode = mode
        latestTranscript = ""

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.taskHint = .confirmation
        request = req
        live.set(req)

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    guard !text.isEmpty else { return }
                    self.latestTranscript = text
                    self.onTranscript?(text)

                    // Check every alternative, not just the best one — "yes" is
                    // short and often loses to a homophone in the top slot.
                    for alt in ([text] + result.transcriptions.prefix(3).map(\.formattedString)) {
                        if let cmd = Self.classify(alt, mode: self.mode) {
                            self.stop()
                            self.onCommand?(cmd)
                            return
                        }
                    }
                    // Mid-string everything else is noise by definition — we are
                    // hearing gunfire and shouting.
                    guard self.mode == .answers else { return }
                    if result.isFinal {
                        self.flushUnrecognized()
                    } else {
                        self.scheduleSettle()
                    }
                }
                if error != nil, self.task != nil {
                    self.flushUnrecognized()
                }
            }
        }
    }

    /// Called from the audio render thread. Must not block or allocate.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        live.append(buffer)
    }

    func stop() {
        settleWork?.cancel(); settleWork = nil
        live.set(nil)
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
    }

    private func scheduleSettle() {
        settleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flushUnrecognized() }
        settleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: w)
    }

    private func flushUnrecognized() {
        let text = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        onUnrecognized?(text)
    }

    // MARK: - Matching

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func classify(_ raw: String, mode: Mode) -> DrillCommand? {
        let t = normalize(raw)
        guard !t.isEmpty else { return nil }
        func has(_ alternatives: String) -> Bool {
            t.range(of: "\\b(\(alternatives))\\b", options: .regularExpression) != nil
        }

        // "do over" is checked first and is the only thing heard mid-string.
        // Note "again" is deliberately NOT a repeat synonym: "do it again" must
        // resolve to doOver, not repeatCommand.
        if has("do over|do it over|do it again|redo|start over|scratch that") {
            return .doOver
        }
        guard mode == .answers else { return nil }

        if has("repeat|repeat command|say again|come again|one more time") { return .repeatCommand }
        if has("no|nope|negative|pause|hold|wait|stand by|standby|not ready") { return .no }
        if has("yes|yeah|yep|yup|yes sir|affirmative|shooter ready|continue|resume|go|i'?m ready|i am ready|ready|set")
            { return .yes }
        return nil
    }
}

/// Offline text to speech. The built-in system voices are on-device, so this
/// works with no signal.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {

    /// Exactly two choices. Which concrete voice each resolves to is decided at
    /// runtime by quality, not pinned by name, so downloading a better voice
    /// later upgrades the app without a code change.
    enum VoicePreference: String, CaseIterable, Identifiable {
        case male, female
        var id: String { rawValue }
        var title: String { self == .male ? "Male" : "Female" }
    }

    private let synth = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    var enabled = true

    var preference: VoicePreference = .male {
        didSet { resolved = nil }
    }
    private var resolved: AVSpeechSynthesisVoice?

    /// Latched by `cancel()`. Every `say` is a no-op until `resume()` clears it.
    ///
    /// This is what makes End Session actually end the session: cancelling only
    /// the utterance in flight is useless when the caller's very next line is
    /// another `say`, so the examiner talks on through the whole readback while
    /// the drill keeps walking forward.
    private(set) var isStopped = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func resume() { isStopped = false }

    func currentVoice() -> AVSpeechSynthesisVoice? {
        if resolved == nil { resolved = Self.bestVoice(for: preference) }
        return resolved
    }

    func say(_ text: String) async {
        guard enabled, !isStopped else {
            if enabled { return }
            try? await Task.sleep(for: .milliseconds(120))
            return
        }
        await withCheckedContinuation { c in
            self.continuation = c
            let u = AVSpeechUtterance(string: text)
            u.voice = currentVoice()
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
            u.postUtteranceDelay = 0.05
            u.volume = 1.0
            synth.speak(u)
        }
    }

    func cancel() {
        isStopped = true
        synth.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    // MARK: - Choosing a voice

    /// The joke voices. Two filters are needed: the legacy set (Zarvox, Bells,
    /// Trinoids, Albert, Fred...) all share the `.speech.synthesis.voice.`
    /// identifier prefix, but the newer character voices (Grandma, Rocko, Flo,
    /// Shelley...) use ordinary `com.apple.voice.compact.*` identifiers and can
    /// only be excluded by name.
    private static let novelty: Set<String> = [
        "albert", "bad news", "bahh", "bells", "boing", "bubbles", "cellos",
        "deranged", "good news", "hysterical", "jester", "junior", "kathy",
        "organ", "pipe organ", "princess", "ralph", "superstar", "trinoids",
        "whisper", "wobble", "zarvox", "bruce", "agnes", "victoria", "vicki",
        "fred", "grandma", "grandpa", "rocko", "shelley", "sandy", "eddy",
        "flo", "reed", "wobble"
    ]

    /// Voices Apple ships that actually sound like a person reading a range
    /// command. Used only as a tie-break behind quality.
    private static let preferred: Set<String> = [
        "alex", "evan", "nathan", "aaron", "tom", "daniel", "oliver", "arthur",
        "ava", "allison", "samantha", "susan", "nicky", "zoe", "joelle", "kate"
    ]

    /// `gender` is `.unspecified` on a number of older voices, so fall back to
    /// what the voice actually is.
    private static let knownFemale: Set<String> = [
        "samantha", "ava", "allison", "susan", "nicky", "zoe", "joelle", "karen",
        "moira", "tessa", "fiona", "serena", "kate", "martha", "catherine",
        "matilda", "veena", "carmit", "damayanti", "melina", "milena", "nora"
    ]
    private static let knownMale: Set<String> = [
        "alex", "aaron", "evan", "nathan", "tom", "daniel", "oliver", "arthur",
        "gordon", "lee", "rishi", "fred", "ralph", "bruce", "reed", "jacques"
    ]

    private static func effectiveGender(_ v: AVSpeechSynthesisVoice) -> AVSpeechSynthesisVoiceGender {
        if v.gender != .unspecified { return v.gender }
        let n = v.name.lowercased()
        if knownFemale.contains(n) { return .female }
        if knownMale.contains(n) { return .male }
        return .unspecified
    }

    /// Higher is better: quality dominates, then a US accent to match the
    /// recogniser's locale, then the shortlist above.
    private static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        var r = v.quality.rawValue * 1000
        if v.language == "en-US" { r += 200 }
        else if v.language == "en-GB" || v.language == "en-AU" { r += 100 }
        if preferred.contains(v.name.lowercased()) { r += 50 }
        return r
    }

    static func bestVoice(for pref: VoicePreference) -> AVSpeechSynthesisVoice? {
        let wanted: AVSpeechSynthesisVoiceGender = pref == .male ? .male : .female
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { v in
            guard v.language.hasPrefix("en") else { return false }
            guard !v.identifier.contains(".speech.synthesis.voice.") else { return false }
            guard !novelty.contains(v.name.lowercased()) else { return false }
            return effectiveGender(v) == wanted
        }
        return candidates.max { rank($0) < rank($1) }
    }

    /// "Alex · en-US · enhanced", for showing which voice a preference resolved
    /// to. If this reads wrong on the device, the filters above are the place
    /// to look.
    static func describe(_ v: AVSpeechSynthesisVoice?) -> String {
        guard let v else { return "no suitable voice installed" }
        let q: String
        switch v.quality {
        case .premium:  q = "premium"
        case .enhanced: q = "enhanced"
        default:        q = "standard"
        }
        return "\(v.name) · \(v.language) · \(q)"
    }
}
