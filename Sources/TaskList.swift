import Foundation

/// What ends a timed string.
enum ShotCount: Hashable {
    /// An exact number of shots.
    case fixed(Int)
    /// "mag" — until the magazine in the gun runs dry.
    case magazine
    /// "*" — until Stop, "do over", the run timeout, or all ammunition is gone.
    case openEnded

    var fixedValue: Int? { if case .fixed(let n) = self { return n }; return nil }

    var label: String {
        switch self {
        case .fixed(let n):  return n == 1 ? "1 shot" : "\(n) shots"
        case .magazine:      return "until magazine empty"
        case .openEnded:     return "open"
        }
    }

    var csvValue: String {
        switch self {
        case .fixed(let n): return String(n)
        case .magazine:     return "mag"
        case .openEnded:    return "open"
        }
    }
}

struct DrillTask: Identifiable, Hashable {
    let id = UUID()
    let text: String
    /// Par time in seconds, or nil when the task list doesn't specify one.
    let par: Double?
    let shots: ShotCount

    var shotsLabel: String { shots.label }
}

struct RunResult: Identifiable, Hashable {
    let id = UUID()
    let index: Int
    let text: String
    let par: Double?
    let expected: ShotCount
    /// Cumulative seconds from the buzzer, one entry per detected shot.
    let shots: [Double]
    /// Cumulative seconds at which a magazine change was called, if any.
    let reloads: [Double]
    let verdict: String
    let manual: Bool

    var total: Double? { shots.last }
    var first: Double? { shots.first }
    /// Gaps between consecutive shots.
    var splits: [Double] {
        guard shots.count > 1 else { return [] }
        return zip(shots.dropFirst(), shots).map { $0 - $1 }
    }
}

enum TaskList {

    /// Format, one task per line:
    ///
    ///     <text> | <par seconds> | <shots>
    ///
    ///   * `par` may be a number, or `-` / empty for "time it but don't score it".
    ///   * `shots` may be a positive integer, `mag` (until the magazine in the
    ///     gun runs dry), or `*` (open ended). Omitted = 1.
    ///
    /// Leading numbering is optional. Blank lines and lines starting with # or //
    /// are ignored.
    ///
    /// Shot counts are NEVER inferred from the text. Real command scripts are
    /// full of decoy numbers — "7 yards", "you have six seconds", "15 yards" —
    /// and several drills ("fire until empty", "finish all your magazines")
    /// have no knowable count at all. Guessing here would silently mis-time
    /// runs, so the count is explicit or it is open ended.
    static func parse(_ text: String) -> [DrillTask] {
        var out: [DrillTask] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { continue }

            let fields = line.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            var body = fields[0]
            if let m = body.range(of: "^\\d+\\s*[.):\\-]\\s*", options: .regularExpression) {
                body = String(body[m.upperBound...]).trimmingCharacters(in: .whitespaces)
            }

            var par: Double? = fields.count > 1 ? Double(fields[1]) : nil
            var shots: ShotCount = .fixed(1)

            if fields.count > 2 {
                let s = fields[2].lowercased()
                if ["*", "any", "open"].contains(s) {
                    shots = .openEnded
                } else if ["mag", "magazine", "empty", "until empty"].contains(s) {
                    shots = .magazine
                } else if let n = Int(s), n > 0 {
                    shots = .fixed(n)
                }
            }

            // Backwards compatibility with the old inline forms: "... [2.5s]",
            // "... (par 2.5)". Only consulted when no pipe fields were given.
            if par == nil, fields.count == 1 {
                let pattern = "[\\[(]\\s*(?:par\\s*[:=]?\\s*)?([0-9]+(?:\\.[0-9]+)?)"
                            + "\\s*(?:s|sec|secs|seconds)?\\s*[\\])]\\s*$"
                if let r = body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    let chunk = String(body[r])
                    if let num = chunk.range(of: "[0-9]+(?:\\.[0-9]+)?", options: .regularExpression) {
                        par = Double(chunk[num])
                    }
                    body = String(body[body.startIndex..<r.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                }
            }

            guard !body.isEmpty else { continue }
            out.append(DrillTask(text: body, par: par, shots: shots))
        }
        return out
    }

    static func bundled() -> [DrillTask] {
        if let url = Bundle.main.url(forResource: "tasks", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let parsed = parse(text)
            if !parsed.isEmpty { return parsed }
        }
        return parse(fallback)
    }

    /// Where an imported list is kept so it survives relaunch. Local app
    /// storage — nothing syncs, nothing needs a network.
    static var savedURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tasks.txt")
    }

    static func loadSaved() -> [DrillTask]? {
        guard let text = try? String(contentsOf: savedURL, encoding: .utf8) else { return nil }
        let parsed = parse(text)
        return parsed.isEmpty ? nil : parsed
    }

    static func save(_ text: String) throws {
        try text.write(to: savedURL, atomically: true, encoding: .utf8)
    }

    static let fallback = """
    1. From the low ready position, fire one round to the center of mass. | 3.0 | 1
    2. From the holster, fire one round to the center of mass. | 4.0 | 1
    3. From the holster, two to the chest, one to the head. | 6.0 | 3
    4. From the ready position, fire until empty. | 8.0 | *
    """

    static func csv(_ results: [RunResult]) -> String {
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func f(_ d: Double?) -> String { d.map { String(format: "%.3f", $0) } ?? "" }

        var lines = ["n,task,par_s,shots_expected,shots_detected,first_s,total_s,"
                   + "splits_s,reloads_s,result,stop"]
        for r in results {
            let splits = r.splits.map { String(format: "%.3f", $0) }.joined(separator: ";")
            let reloads = r.reloads.map { String(format: "%.3f", $0) }.joined(separator: ";")
            lines.append([
                String(r.index), esc(r.text), f(r.par), r.expected.csvValue, String(r.shots.count),
                f(r.first), f(r.total), esc(splits), esc(reloads),
                r.verdict, r.manual ? "manual" : "detector"
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
