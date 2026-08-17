import AVFoundation
import Foundation
import os

/// Sample-accurate audio for the drill.
///
/// TIMING CONTRACT — do not "simplify" this:
///  * Every event is timestamped in mach host time, captured on the audio
///    render thread from `AVAudioTime.hostTime` plus the sample offset inside
///    the buffer. Dispatching the result to the main queue afterwards costs
///    microseconds and cannot move the timestamp.
///  * Speech recognition is never in the timing path. Its results arrive
///    hundreds of milliseconds late with high jitter — larger than the
///    quantity being measured.
///  * T0 is preferably the moment the *microphone hears the buzzer*, not the
///    moment the buzzer was scheduled. Start and stop then travel the same
///    acoustic + input path, so output and input latency cancel exactly
///    instead of being estimated.
final class AudioCore {

    // MARK: - Host time helpers

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    static func hostToSec(_ h: UInt64) -> Double {
        Double(h) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
    static func secToHost(_ s: Double) -> UInt64 {
        UInt64(max(0, s) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }
    static func now() -> UInt64 { mach_absolute_time() }
    static func elapsed(from a: UInt64, to b: UInt64) -> Double {
        b >= a ? hostToSec(b - a) : -hostToSec(a - b)
    }

    // MARK: - Graph

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buzzBuffer: AVAudioPCMBuffer?
    private(set) var isRunning = false

    /// Called on the main queue with the host time of a threshold crossing and
    /// the impulse ratio measured at that crossing (see `impulseRatio`). The
    /// ratio is reported whether or not the gate is enabled, so a range session
    /// produces the numbers needed to set the gate.
    var onDetect: ((UInt64, Float) -> Void)?
    /// Called on the main queue when a crossing was loud enough but was thrown
    /// away by the impulse gate, with the ratio it measured. At most one per
    /// buffer, so a long scrape reports once rather than fifty times.
    var onReject: ((Float) -> Void)?
    /// Called on the main queue, throttled, with the block peak (0...1).
    var onLevel: ((Float) -> Void)?
    /// Called on the AUDIO THREAD. Forward to the recognizer; do nothing slow.
    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?

    // Detector state. Touched from the audio thread — keep the critical
    // sections to a handful of instructions.
    private var lock = os_unfair_lock_s()
    private var armed = false
    private var armAtHost: UInt64 = 0
    private var refractoryHost: UInt64 = 0     // 0 == fire once, then disarm
    private var threshold: Float = 0.25
    private var calibrating = false
    private var noisePeak: Float = 0
    private var meterCount = 0
    /// Minimum ratio of the crossing sample to the amplitude envelope just
    /// before it. 0 disables the gate entirely. See `arm`.
    private var impulseRatio: Float = 0

    // Envelope follower. Audio thread only — never touched under the lock,
    // because it is advanced over every sample of every buffer and the lock is
    // taken once per buffer.
    /// Time constant of the envelope follower. Long enough that a scrape or a
    /// shout has raised it before its own peak arrives, short enough that it
    /// has collapsed again between two 0.15 s splits.
    private static let envTimeConstant = 0.015
    private var envelope: Float = 0
    private var envCoeff: Float = 0
    private var envSampleRate: Double = 0

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        // .measurement disables AGC / EQ / noise processing, which is what makes
        // absolute amplitude thresholding meaningful. It also means the buzzer is
        // NOT echo-cancelled out of the input — which is exactly what we want,
        // because we reference T0 to the mic hearing it.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)

        let outFmt = AVAudioFormat(standardFormatWithSampleRate: session.sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outFmt)
        engine.mainMixerNode.outputVolume = 1.0
        buzzBuffer = Self.makeBuzz(format: outFmt)

        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, when in
            self?.process(buf, when)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Audio thread

    private func process(_ buf: AVAudioPCMBuffer, _ when: AVAudioTime) {
        onMicBuffer?(buf)

        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        let sr = buf.format.sampleRate

        var peak: Float = 0
        for i in 0..<n {
            let a = Swift.abs(ch[i])
            if a > peak { peak = a }
        }

        let base: UInt64 = when.isHostTimeValid ? when.hostTime : mach_absolute_time()

        os_unfair_lock_lock(&lock)
        if calibrating, peak > noisePeak { noisePeak = peak }
        let isArmed = armed
        let thr = threshold
        let armAt = armAtHost
        let gate = impulseRatio
        os_unfair_lock_unlock(&lock)

        meterCount += 1
        if meterCount % 4 == 0 {
            let p = peak
            DispatchQueue.main.async { self.onLevel?(p) }
        }

        if envSampleRate != sr {
            envSampleRate = sr
            envCoeff = Float(1 - exp(-1.0 / (sr * Self.envTimeConstant)))
        }

        // The envelope must be advanced over EVERY buffer, armed or not, so that
        // it is already tracking the room when the detector arms. Bailing out
        // early on `!isArmed` would leave it stale at zero and make the first
        // crossing after arming look infinitely impulsive.
        var env = envelope
        var reported = false
        var rejected: Float?

        for i in 0..<n {
            let a = Swift.abs(ch[i])
            let envBefore = env
            env += (a - env) * envCoeff

            if reported || !isArmed || a < thr { continue }
            let t = base &+ Self.secToHost(Double(i) / sr)
            if t < armAt { continue }              // still inside the blanking window

            // How far this sample stands above the sound that preceded it.
            // A gunshot goes from room noise to full scale inside a millisecond,
            // so the ratio is enormous. A holster draw, a reholster and a
            // shouted "Bang!" all ramp up over tens of milliseconds, dragging
            // the envelope with them, so the ratio stays small.
            let ratio = a / Swift.max(envBefore, 1e-5)
            if gate > 0, ratio < gate {
                if rejected == nil { rejected = ratio }
                continue
            }

            os_unfair_lock_lock(&lock)
            if refractoryHost > 0 {
                // Multi-shot: stay armed but go blind for the dead time, so one
                // report per shot instead of one per threshold crossing. A shout
                // or a muzzle blast crosses the threshold many times.
                armAtHost = t &+ refractoryHost
            } else {
                armed = false
            }
            os_unfair_lock_unlock(&lock)

            DispatchQueue.main.async { self.onDetect?(t, ratio) }
            reported = true                         // at most one report per buffer
        }

        envelope = env
        if !reported, let r = rejected {
            DispatchQueue.main.async { self.onReject?(r) }
        }
    }

    // MARK: - Detector control

    func beginCalibration() {
        os_unfair_lock_lock(&lock); calibrating = true; noisePeak = 0; os_unfair_lock_unlock(&lock)
    }

    /// Ends calibration and returns the loudest peak observed (0...1).
    @discardableResult
    func endCalibration() -> Float {
        os_unfair_lock_lock(&lock)
        calibrating = false
        let p = noisePeak
        os_unfair_lock_unlock(&lock)
        return p
    }

    /// Arms the detector. Crossings before `fromHost` are ignored.
    ///
    /// `refractory` is the dead time after each report. Pass 0 for a single
    /// report (the detector disarms itself); pass a positive value to keep
    /// reporting every shot in a string with that much blindness between them.
    ///
    /// Sizing it matters: a gunshot is a 1-3 ms transient and live splits can be
    /// 0.15 s, so ~0.10 s is right for live fire. A shouted "Bang!" lasts
    /// 300-500 ms and would otherwise register as several shots, so dry practice
    /// needs ~0.30 s. There is no single value that serves both.
    ///
    /// `impulse` is the minimum ratio of a crossing to the envelope immediately
    /// before it. It separates a gunshot (near-instant attack) from a holster
    /// draw or reholster (a ramp), at the cost of also rejecting a shouted
    /// "Bang!", which ramps the same way. Pass 0 — the default — to disable it,
    /// which is what the buzzer detection wants: T0 must never be gated.
    func arm(fromHost: UInt64, threshold thr: Float,
             refractory: Double = 0, impulse: Float = 0) {
        os_unfair_lock_lock(&lock)
        armed = true
        armAtHost = fromHost
        threshold = thr
        refractoryHost = refractory > 0 ? Self.secToHost(refractory) : 0
        impulseRatio = Swift.max(0, impulse)
        os_unfair_lock_unlock(&lock)
    }

    func disarm() {
        os_unfair_lock_lock(&lock); armed = false; os_unfair_lock_unlock(&lock)
    }

    /// Moves the blanking window, in either direction, without disturbing the
    /// armed flag, the threshold or the refractory time.
    ///
    /// This is how the examiner is allowed to speak during a timed string: push
    /// the window far out, say the line, pull it back. Disarming instead would
    /// lose the refractory state, and stopping the engine would move T0's
    /// acoustic reference out from under the run.
    func setBlanking(untilHost: UInt64) {
        os_unfair_lock_lock(&lock); armAtHost = untilHost; os_unfair_lock_unlock(&lock)
    }

    var activeThreshold: Float {
        os_unfair_lock_lock(&lock); let t = threshold; os_unfair_lock_unlock(&lock); return t
    }

    // MARK: - Buzzer

    /// Schedules the buzzer `lead` seconds from now. Returns the scheduled host time.
    @discardableResult
    func scheduleBuzz(lead: Double = 0.30) -> UInt64 {
        guard let buf = buzzBuffer, isRunning else { return Self.now() }
        player.stop()
        player.reset()
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        let t = Self.now() &+ Self.secToHost(lead)
        player.play(at: AVAudioTime(hostTime: t))
        return t
    }

    var outputLatency: Double { AVAudioSession.sharedInstance().outputLatency }
    var inputLatency: Double { AVAudioSession.sharedInstance().inputLatency }

    /// True when audio is going out over Bluetooth, where latency is large and
    /// unstable enough to make either timing reference unreliable.
    var isBluetoothOutput: Bool {
        let bt: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { bt.contains($0.portType) }
    }

    private static func makeBuzz(format: AVAudioFormat,
                                 freq: Double = 950,
                                 dur: Double = 0.25) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let n = AVAudioFrameCount(sr * dur)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return nil }
        b.frameLength = n
        guard let p = b.floatChannelData?[0] else { return nil }
        let total = Int(n)
        let fade = max(1, Int(sr * 0.003))
        for i in 0..<total {
            let phase = (Double(i) * freq / sr).truncatingRemainder(dividingBy: 1.0)
            var v: Float = phase < 0.5 ? 0.95 : -0.95
            if i < fade { v *= Float(i) / Float(fade) }
            let tail = total - i
            if tail < fade { v *= Float(tail) / Float(fade) }
            p[i] = v
        }
        return b
    }
}
