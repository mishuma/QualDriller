import AVFoundation
import Foundation
import Speech

enum DrillCommand {
    case yes, no, repeatCommand, ready
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

    private var expectingReady = false
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

    func start(expectingReady: Bool) {
        stop()
        guard unavailableReason == nil, let recognizer, recognizer.isAvailable else { return }

        self.expectingReady = expectingReady
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
                        if let cmd = Self.classify(alt, expectingReady: self.expectingReady) {
                            self.stop()
                            self.onCommand?(cmd)
                            return
                        }
                    }
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

    static func classify(_ raw: String, expectingReady: Bool) -> DrillCommand? {
        let t = normalize(raw)
        guard !t.isEmpty else { return nil }
        func has(_ alternatives: String) -> Bool {
            t.range(of: "\\b(\(alternatives))\\b", options: .regularExpression) != nil
        }
        if expectingReady {
            return has("i'?m ready|i am ready|ready|i'?m set|set|go") ? .ready : nil
        }
        // Order matters: "repeat command" must win outright.
        if has("repeat|say again|again|come again|one more time") { return .repeatCommand }
        if has("no|nope|negative|not ready|hold|wait|stand by|standby") { return .no }
        if has("yes|yeah|yep|yup|yes sir|affirmative|shooter ready") { return .yes }
        return nil
    }
}

/// Offline text to speech. The built-in system voices are on-device, so this
/// works with no signal.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {

    private let synth = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    var enabled = true

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String) async {
        guard enabled else {
            try? await Task.sleep(for: .milliseconds(120))
            return
        }
        await withCheckedContinuation { c in
            self.continuation = c
            let u = AVSpeechUtterance(string: text)
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
            u.postUtteranceDelay = 0.05
            u.volume = 1.0
            synth.speak(u)
        }
    }

    func cancel() {
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
}
