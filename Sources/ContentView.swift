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
            // The buttons are a first-class path, not a fallback. Gloves, wind,
            // ear pro and a noisy bay all defeat speech recognition.
            if engine.phase == "timing" {
                BigButton(title: "STOP TIMER", tint: .red) { engine.manualStop() }
            } else if engine.phase == "awaiting reply" {
                HStack(spacing: 10) {
                    BigButton(title: "YES", tint: .green) { engine.answer(.yes) }
                    BigButton(title: "NO", tint: .orange) { engine.answer(.no) }
                }
                BigButton(title: "REPEAT COMMAND", tint: .blue) { engine.answer(.repeatCommand) }
            } else if engine.phase == "standing by" {
                BigButton(title: "I'M READY", tint: .green) { engine.answer(.ready) }
            } else {
                HStack(spacing: 10) {
                    BigButton(title: engine.isRunning ? "RUNNING" : "START",
                              tint: .accentColor) { engine.start() }
                        .disabled(engine.isRunning || engine.tasks.isEmpty)
                    if engine.isRunning {
                        BigButton(title: "STOP", tint: .gray) { engine.stopSession() }
                    }
                }
            }

            if engine.isRunning && engine.phase != "idle" {
                Button("End session", role: .destructive) { engine.stopSession() }
                    .font(.footnote)
            }
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
                    Stepper("Blanking: \(Int(engine.blankingMs)) ms",
                            value: $engine.blankingMs, in: 0...1500, step: 25)
                    Stepper("Run timeout: \(Int(engine.maxRunSeconds)) s",
                            value: $engine.maxRunSeconds, in: 3...300, step: 1)
                } header: {
                    Text("Shot detection")
                } footer: {
                    Text("The threshold is recalibrated to the room's noise floor before every buzzer. "
                       + "Blanking ignores the buzzer's own sound — it also means a shot inside that "
                       + "window can't be detected, so keep it just long enough.")
                }

                Section("Voice") {
                    Toggle("Examiner speaks aloud", isOn: $engine.speakAloud)
                    Toggle("Listen for my replies", isOn: $engine.listenForVoice)
                    Toggle("Read my time back", isOn: $engine.readBackTime)
                    LabeledContent("Offline model",
                                   value: engine.voice.onDeviceAvailable ? "installed" : "missing")
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
                            Text(r.time.map { String(format: "%.2f s", $0) } ?? "—")
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
