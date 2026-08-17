import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = DrillEngine()
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var showResults = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let banner = engine.banner {
                    BannerView(text: banner) { engine.banner = nil }
                }

                MagazineBar(ammo: engine.ammo)
                    .padding(.top, 6)

                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                controls
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                LevelBar(level: engine.level)
                    .frame(height: 4)
            }
            .background(Color(white: 0.06).ignoresSafeArea())
            .navigationTitle("QualDriller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showResults = true } label: {
                        Label("Results", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(engine.results.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .disabled(engine.isRunning)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(engine: engine, showImporter: $showImporter)
            }
            .sheet(isPresented: $showResults) {
                ResultsView(engine: engine)
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText, .text, .utf8PlainText]) { result in
                if case .success(let url) = result { engine.loadTasks(from: url) }
            }
        }
        .preferredColorScheme(.dark)
        .task { await engine.prepare() }
    }

    // MARK: - Stage

    private var stage: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            Text(engine.phase.uppercased())
                .font(.caption).tracking(2)
                .foregroundStyle(.secondary)

            Text(engine.commandText)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(minHeight: 90)

            Text(engine.timerText)
                .font(.system(size: 78, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tintColor)
                .contentTransition(.numericText())

            Text(engine.verdict.isEmpty ? " " : engine.verdict)
                .font(.headline).tracking(1.5)
                .foregroundStyle(engine.verdict.hasPrefix("PASS") ? .green : .red)

            SplitsRow(shots: engine.liveShots, expected: engine.expectedShots)

            // Running dry has to be unmissable. The examiner also calls it
            // aloud, but only with the mic deafened for the length of the line
            // — see DrillEngine.announceEmptyMagazine.
            if engine.isRunning && engine.ammo.roundsInCurrent == 0 {
                Label(engine.ammo.hasSpareMagazine
                        ? (engine.phase == "timing"
                             ? "EMPTY — RELOAD, THEN SHOUT"
                             : "MAGAZINE EMPTY — RELOAD")
                        : "OUT OF AMMUNITION",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.bold)).tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.red, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }

            Text(engine.hint.isEmpty ? " " : engine.hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Text(engine.transcript.isEmpty ? " " : "“\(engine.transcript)”")
                .font(.footnote.italic())
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private var tintColor: Color {
        switch engine.timerTint {
        case .neutral: return .primary
        case .running: return .orange
        case .pass:    return .green
        case .fail:    return .red
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            // The buttons are a first-class path, not a fallback. A hoarse
            // voice, a room where you can't shout, and a recogniser that
            // mishears all defeat the spoken commands.
            if engine.phase == "queued" {
                // The only phase with drill navigation or a reload. Nothing is
                // armed and nothing has been read out, so moving around the
                // list or refilling magazines here cannot corrupt a run.
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        ArrowButton(system: "chevron.left") { engine.queuedPrev() }
                            .disabled(!engine.canGoPrev)
                        BigButton(title: "START", tint: .green) { engine.answer(.start) }
                        ArrowButton(system: "chevron.right") { engine.queuedNext() }
                            .disabled(!engine.canGoNext)
                    }
                    // REFILL, not RELOAD. Refilling the magazines is not
                    // reloading the gun, and the two live in different phases
                    // so they can never be pressed interchangeably.
                    BigButton(title: "REFILL", tint: .teal) { engine.refillAll() }
                }
            } else if engine.phase == "timing" {
                HStack(spacing: 10) {
                    BigButton(title: "STOP", tint: .red) { engine.stopString() }
                    BigButton(title: "RELOAD", tint: .teal) { engine.reloadNow() }
                    BigButton(title: "DO OVER", tint: .purple) { engine.answer(.doOver) }
                }
            } else if engine.phase == "awaiting reply" || engine.phase == "paused" {
                // Yes and Repeat only. The app is already waiting here, so a
                // Pause button is redundant, and Repeat re-reads the command —
                // which is what Do Over would do at this point anyway.
                HStack(spacing: 10) {
                    BigButton(title: engine.phase == "paused" ? "CONTINUE" : "YES",
                              tint: .green) { engine.answer(.yes) }
                    BigButton(title: "REPEAT", tint: .blue) { engine.answer(.repeatCommand) }
                }
            } else if engine.phase == "result" || engine.phase == "ready for next" {
                BigButton(title: "DO OVER", tint: .purple) { engine.answer(.doOver) }
            } else {
                BigButton(title: engine.isRunning ? "RUNNING" : "START SESSION",
                          tint: .accentColor) { engine.start() }
                    .disabled(engine.isRunning || engine.tasks.isEmpty)
            }

            // Always present, in every phase — no hunting for it mid-drill.
            Button(role: .destructive) {
                engine.stopSession()
            } label: {
                Text("END SESSION")
                    .font(.subheadline.weight(.semibold)).tracking(1)
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }
}

// MARK: - Pieces

private struct BigButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline).tracking(1)
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }
}

/// Fixed-width so that Start keeps the same size and position whether or not
/// the arrows are usable — the shooter should not have to re-find it.
///
/// Explicitly filled rather than `.bordered`. A bordered button tints its fill
/// at roughly 15% opacity, and grey at 15% over this screen's near-black
/// background is invisible in daylight — which is exactly where this app is
/// used. Everything here is drawn, not inherited.
private struct ArrowButton: View {
    let system: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(isEnabled ? Color.white : Color(white: 0.35))
                .frame(width: 62, height: 56)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(white: isEnabled ? 0.26 : 0.12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color(white: isEnabled ? 0.55 : 0.20),
                                              lineWidth: 1.5)
                        }
                }
        }
        .buttonStyle(.plain)
    }
}

/// Magazines 1-3, left to right. The one in the gun is outlined; magazines
/// already swapped past are struck through, because they are never used again
/// this session even if rounds were left in them.
private struct MagazineBar: View {
    let ammo: AmmoState

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ammo.magazines) { mag in
                let isCurrent = mag.id - 1 == ammo.current && !mag.retired
                let dry = isCurrent && mag.isEmpty
                let accent: Color = dry ? .red : .teal
                HStack(spacing: 5) {
                    Text("MAG \(mag.id)")
                        .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                    Text(mag.retired ? "—" : dry ? "EMPTY" : "\(mag.rounds)")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }
                .foregroundStyle(mag.retired ? AnyShapeStyle(.tertiary)
                                 : dry ? AnyShapeStyle(Color.red)
                                 : isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .strikethrough(mag.retired)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isCurrent ? accent.opacity(dry ? 0.22 : 0.16) : Color.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(isCurrent ? accent : Color.clear, lineWidth: 1.5)
                        }
                }
            }
            Spacer(minLength: 0)
            Text("\(ammo.totalRemaining) left")
                .font(.caption).monospacedDigit()
                .foregroundStyle(ammo.totalRemaining == 0 ? .red : .secondary)
        }
        .padding(.horizontal, 14)
    }
}

/// Shot-by-shot readout: cumulative time on top, the split from the previous
/// shot underneath. Empty slots show what is still owed on the string.
private struct SplitsRow: View {
    let shots: [Double]
    let expected: ShotCount

    var body: some View {
        let pending = max(0, (expected.fixedValue ?? 0) - shots.count)
        HStack(spacing: 8) {
            ForEach(Array(shots.enumerated()), id: \.offset) { i, t in
                VStack(spacing: 1) {
                    Text(String(format: "%.2f", t))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text(i == 0 ? "1st" : String(format: "+%.2f", t - shots[i - 1]))
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(0..<pending, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 40, height: 34)
            }
            if expected.fixedValue == nil && !shots.isEmpty {
                Text(expected == .magazine ? "to empty" : "open")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 36)
        .animation(.easeOut(duration: 0.15), value: shots.count)
    }
}

private struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(.quaternary)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(level > 0.5 ? Color.red : Color.green)
                        .frame(width: geo.size.width * CGFloat(min(1, level / 0.5)))
                }
        }
    }
}

private struct BannerView: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.footnote)
            Spacer(minLength: 0)
            Button { dismiss() } label: { Image(systemName: "xmark") }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.18))
        .foregroundStyle(.yellow)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var engine: DrillEngine
    @Binding var showImporter: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Task list") {
                    Text("\(engine.tasks.count) tasks loaded")
                        .foregroundStyle(.secondary)
                    Button("Import a task list…") { dismiss(); showImporter = true }
                    Button("Reset to built-in list", role: .destructive) { engine.resetToBundled() }
                    Toggle("Shuffle order", isOn: $engine.shuffle)
                }

                Section {
                    Toggle("Random 2–4 s", isOn: $engine.useRandomDelay)
                    if !engine.useRandomDelay {
                        Stepper(String(format: "Fixed delay: %.1f s", engine.fixedDelay),
                                value: $engine.fixedDelay, in: 0.6...10, step: 0.1)
                    }
                } header: {
                    Text("Start signal")
                } footer: {
                    Text("A fixed delay trains you to anticipate the buzzer. Random is closer to a real qualifier.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text(String(format: "Sensitivity: %.1f×", engine.sensitivity))
                        Slider(value: $engine.sensitivity, in: 0.4...3, step: 0.1)
                    }
                    VStack(alignment: .leading) {
                        Text(engine.minThreshold <= 0
                             ? "Ignore quiet sounds: off"
                             : String(format: "Ignore quiet sounds: below %.2f", engine.minThreshold))
                        Slider(value: $engine.minThreshold, in: 0...0.9, step: 0.05)
                    }
                    Stepper("Shout dead time: \(Int(engine.refractoryMs)) ms",
                            value: $engine.refractoryMs, in: 100...800, step: 10)
                    Stepper("Buzzer blanking: \(Int(engine.blankingMs)) ms",
                            value: $engine.blankingMs, in: 0...1500, step: 25)
                    Stepper("Run timeout: \(Int(engine.maxRunSeconds)) s",
                            value: $engine.maxRunSeconds, in: 3...300, step: 1)
                } header: {
                    Text("Hearing your shots")
                } footer: {
                    Text("This is dry practice: every shot is you shouting. The app listens for "
                       + "how LOUD you are, never for what you said — recognising words would put "
                       + "speech recognition, which lags by up to a second, into the timing. "
                       + "Shout “bang”, shout “rack”, shout anything.\n\n"
                       + "The threshold is recalibrated to the room's noise floor before every "
                       + "buzzer, so a quiet room and a noisy one both work without touching "
                       + "anything. Sensitivity nudges that up or down.\n\n"
                       + "Ignore quiet sounds puts a hard floor under it, for when something in "
                       + "the room keeps getting counted — a holster draw, a door, a dog. Raise "
                       + "it one step at a time: too high and your own shouts stop registering.\n\n"
                       + "Shout dead time is how long the mic is ignored after each shout. One "
                       + "“bang” lasts 300–500 ms and would otherwise count as three or four "
                       + "shots, so this cannot go much below 300. It also means your splits "
                       + "measure how fast you can talk, not how fast you can shoot.\n\n"
                       + "Buzzer blanking ignores the buzzer's own sound. A shout inside that "
                       + "window can't be heard either, so keep it just long enough.")
                }

                Section {
                    ForEach(0..<3, id: \.self) { i in
                        Stepper("Magazine \(i + 1): \(engine.magCapacities.count > i ? engine.magCapacities[i] : 0) rounds",
                                value: Binding(
                                    get: { engine.magCapacities.count > i ? engine.magCapacities[i] : 0 },
                                    set: { new in
                                        var c = engine.magCapacities
                                        while c.count < 3 { c.append(0) }
                                        c[i] = min(AmmoState.maxRounds, max(0, new))
                                        engine.magCapacities = c
                                    }),
                                in: 0...AmmoState.maxRounds)
                    }
                } header: {
                    Text("Ammunition")
                } footer: {
                    Text("Every shout costs a round: a shot fires one, a rack ejects one. "
                       + "Magazines go 1 → 2 → 3 and deplete across every drill in the session.\n\n"
                       + "When the gun runs dry the examiner calls “Empty mag. Reload!” and then "
                       + "listens. An empty gun cannot fire, so the next thing it hears cannot be "
                       + "a shot — shout “reload”, or shout anything, and it counts as the "
                       + "reload. No button and no words to get right. The clock never stops, so "
                       + "the reload costs you time exactly as it does on the line.\n\n"
                       + "RELOAD, on the clock, is still there for a tactical reload — swapping "
                       + "with rounds still in the magazine, which the app can't guess at. The "
                       + "magazine you leave behind is on the ground and is not used again this "
                       + "string. REFILL, between drills, tops all three back up and returns to "
                       + "magazine 1: that's you picking them up.\n\n"
                       + "One catch: the mic is deafened while the examiner speaks, because its "
                       + "voice comes out of the same speaker and would be counted as a shout. "
                       + "A shot during the call is not heard. You're reloading, so it shouldn't "
                       + "come up.")
                }

                Section {
                    Picker("After the command", selection: $engine.readyPrompt) {
                        ForEach(DrillEngine.ReadyPrompt.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Ready prompt")
                } footer: {
                    Text("What the examiner says once the command has been read. Either way the "
                       + "drill still waits for “yes” or the Yes button before the buzzer.\n\n"
                       + "Several drills in the built-in list already end with “Standby.” in their "
                       + "own text — with this set to Standby the examiner will say it twice. "
                       + "Trim it from those lines if you switch.")
                }

                Section {
                    Toggle("Examiner speaks aloud", isOn: $engine.speakAloud)
                    Toggle("Listen for my replies", isOn: $engine.listenForVoice)
                    Toggle("Read my time back", isOn: $engine.readBackTime)
                    VStack(alignment: .leading) {
                        Text(String(format: "Pause before readback: %.1f s", engine.resultPause))
                        Slider(value: $engine.resultPause, in: 0...3, step: 0.1)
                    }
                    LabeledContent("Offline model",
                                   value: engine.voice.onDeviceAvailable ? "installed" : "missing")
                } header: {
                    Text("Voice")
                } footer: {
                    Text("The pause is the gap between your last shot and the spoken time. "
                       + "The number appears on screen immediately either way.")
                }

                Section {
                    Picker("Voice", selection: $engine.voicePreference) {
                        ForEach(Speaker.VoicePreference.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Using",
                                   value: Speaker.describe(Speaker.bestVoice(for: engine.voicePreference)))
                        .font(.caption)
                    Button("Preview voice") { engine.previewVoice() }
                } header: {
                    Text("Examiner voice")
                } footer: {
                    Text("One male and one female, both picked as the most natural English voice "
                       + "installed on this iPhone — novelty voices are excluded. The choice is "
                       + "resolved by quality at run time, so downloading a better voice under "
                       + "Settings › Accessibility › Spoken Content › Voices upgrades this "
                       + "automatically. Downloaded voices work offline.")
                }

                Section("Session log") {
                    ForEach(engine.logLines.suffix(40)) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.who)
                                .font(.caption2.monospaced())
                                .foregroundStyle(line.who == "YOU" ? .blue : .secondary)
                                .frame(width: 34, alignment: .leading)
                            Text(line.text).font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Results

private struct ResultsView: View {
    @ObservedObject var engine: DrillEngine
    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareItem?

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(engine.results) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.text).font(.subheadline)
                        HStack(spacing: 12) {
                            Text(r.total.map { String(format: "%.2f s", $0) } ?? "—")
                                .monospacedDigit().bold()
                            if let par = r.par {
                                Text(String(format: "par %.2f", par)).foregroundStyle(.secondary)
                            }
                            Text(r.verdict)
                                .foregroundStyle(r.verdict == "PASS" ? .green
                                                 : r.verdict == "—" ? .secondary : .red)
                            if r.manual { Text("manual").foregroundStyle(.tertiary) }
                        }
                        .font(.caption)
                        if r.shots.count > 1 {
                            Text("1st \(String(format: "%.2f", r.first ?? 0))   splits "
                                 + r.splits.map { String(format: "%.2f", $0) }.joined(separator: " · "))
                                .font(.caption2).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Export CSV") { exportCSV() }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $share) { item in ShareSheet(url: item.url) }
        }
    }

    private func exportCSV() {
        let csv = TaskList.csv(engine.results)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qualdriller-\(stamp).csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        share = ShareItem(url: url)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
