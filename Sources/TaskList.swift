import Foundation

struct DrillTask: Identifiable, Hashable {
    let id = UUID()
    let text: String
    /// Par time in seconds, or nil when the task list doesn't specify one.
    let par: Double?
}

struct RunResult: Identifiable, Hashable {
    let id = UUID()
    let index: Int
    let text: String
    let par: Double?
    /// nil means no shot was detected before the timeout.
    let time: Double?
    let verdict: String
    let manual: Bool
}

enum TaskList {

    /// Accepts a plain numbered list, one task per line.
    ///
    ///     1. From the holster, draw and fire two rounds. | 2.5
    ///     2. Fire one round to the head [1.5s]
    ///     3. Fire five rounds to the body        <- no par time, timed only
    ///
    /// Blank lines and lines starting with # or // are ignored. The numbering
    /// is optional; unnumbered lines are accepted as tasks too, so a list
    /// pasted from anywhere still works.
    static func parse(_ text: String) -> [DrillTask] {
        var out: [DrillTask] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { continue }

            var body = line
            if let m = line.range(of: "^\\d+\\s*[.):\\-]\\s*", options: .regularExpression) {
                body = String(line[m.upperBound...]).trimmingCharacters(in: .whitespaces)
            }

            var par: Double?
            let parPattern = "[\\[(|]\\s*(?:par\\s*[:=]?\\s*)?([0-9]+(?:\\.[0-9]+)?)\\s*(?:s|sec|secs|seconds)?\\s*[\\])]?\\s*$"
            if let r = body.range(of: parPattern, options: [.regularExpression, .caseInsensitive]) {
                let chunk = String(body[r])
                if let num = chunk.range(of: "[0-9]+(?:\\.[0-9]+)?", options: .regularExpression) {
                    par = Double(chunk[num])
                }
                body = String(body[body.startIndex..<r.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t|-–—"))
            }

            guard !body.isEmpty else { continue }
            out.append(DrillTask(text: body, par: par))
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

    /// Where an imported list is kept so it survives relaunch. Offline-safe:
    /// this is local app storage, nothing syncs.
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
    1. From the holster, draw and fire two rounds to the body. | 2.5
    2. From the ready position, fire one round to the head. | 1.5
    3. From the holster, draw and fire two to the body, one to the head. | 4.0
    4. From the ready position, fire two rounds, slide-lock reload, fire two more. | 8.0
    5. From the holster, draw strong hand only and fire two rounds. | 4.0
    6. From the ready position, fire five rounds to the body. | 5.0
    """

    static func csv(_ results: [RunResult]) -> String {
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["n,task,par_s,time_s,result,stop"]
        for r in results {
            let par = r.par.map { String(format: "%.2f", $0) } ?? ""
            let time = r.time.map { String(format: "%.3f", $0) } ?? ""
            lines.append("\(r.index),\(esc(r.text)),\(par),\(time),\(r.verdict),\(r.manual ? "manual" : "detector")")
        }
        return lines.joined(separator: "\n")
    }
}
