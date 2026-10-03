import Foundation

// =================================================================
// KiddoLog — errors on disk, not only in the UI.
//
// Until now every failure lived in `AccountWorker.lastError`, i.e. in the
// Settings window and nowhere else. Nothing was written down, so a failure
// was invisible the moment the window was closed — and diagnosing one meant
// `sample`, `lsof` and replaying POP3 by hand from the outside. That is a
// real cost: an evening of it on 2026-09-11, and again on 2026-09-12 when a
// POP3 login failure could only be described as "it says connection fail".
//
// One file, appended, bounded, plain text. No levels, no rotation policy
// beyond a size cap, nothing to configure — the point is that the reason
// exists somewhere after the fact.
// =================================================================

enum KiddoLog {
    /// ~/Library/Application Support/AxiomKiddo/kiddo.log
    static var path: String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("AxiomKiddo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kiddo.log").path
    }

    private static let cap = 256 * 1024
    private static let queue = DispatchQueue(label: "kiddo.log")

    /// Append one timestamped line. Best-effort and never throws: a logger
    /// that can break the thing it observes is worse than no logger.
    static func write(_ line: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let entry = "\(stamp) \(line)\n"
            let p = path
            let fm = FileManager.default
            guard let data = entry.data(using: .utf8) else { return }
            if let h = FileHandle(forWritingAtPath: p) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: URL(fileURLWithPath: p))
            }
            // Trim from the FRONT at a line boundary when it outgrows the cap,
            // so the newest reason is always the one that survives.
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let size = attrs[.size] as? Int, size > cap,
               let all = try? Data(contentsOf: URL(fileURLWithPath: p)) {
                let keep = all.suffix(cap / 2)
                if let nl = keep.firstIndex(of: 0x0A) {
                    try? keep[(nl + 1)...].write(to: URL(fileURLWithPath: p))
                }
            }
        }
    }
}
