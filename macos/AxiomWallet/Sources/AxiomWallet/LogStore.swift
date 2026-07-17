import Foundation
import Combine

// =================================================================
// LogStore — the demo wallet's "black box recorder".
//
// A Finder-launched .app sends stdout/stderr to /dev/null, so the Rust
// SDK's diagnostics (CoreID/DMAP "WrongCore", FLOCK contention, redeem
// rejections, fund-loss traces, panics) are normally invisible — which
// is exactly what made the recent debugging painful. LogStore tees the
// process's stdout+stderr into:
//   1. a persistent on-disk file (~/Library/Application Support/Axiom/
//      logs/axiomwallet.log) that survives the session, AND
//   2. an in-memory, timestamped ring buffer the Activity view can
//      interleave with send/receive history (toggle).
//
// It still echoes to the ORIGINAL stderr, so a terminal-launched build
// keeps printing live (Finder launch = /dev/null, harmless).
// =================================================================

final class LogStore: ObservableObject {
    static let shared = LogStore()

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
        /// Heuristic severity for colouring — covers the strings the SDK
        /// and Core actually emit on failure.
        var isError: Bool {
            let l = text.lowercased()
            return l.contains("error") || l.contains("fail") || l.contains("reject")
                || l.contains("wrongcore") || l.contains("panic")
                || l.contains("denied") || l.contains("mismatch") || text.contains("E_")
        }
    }

    /// Timestamped ring buffer (most-recent-capped). Published for the UI.
    @Published private(set) var entries: [Entry] = []

    /// The persistent log file. Surfaced so the UI can "reveal in Finder".
    let logFileURL: URL

    private let maxEntries = 5000
    private var started = false
    private var fileHandle: FileHandle?
    private var savedStderr: Int32 = -1
    /// RETAINED for the process lifetime. Without this the pipe's read end
    /// deallocates when start() returns, and the next write to the redirected
    /// stdout/stderr crashes the app at launch.
    private var capturePipe: Pipe?

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Axiom/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logFileURL = dir.appendingPathComponent("axiomwallet.log")
    }

    /// Begin capturing. Call ONCE, as early as possible at launch (before
    /// sdkSetup) so the Core-ELF / setup diagnostics are caught too.
    func start() {
        guard !started else { return }
        started = true
        signal(SIGPIPE, SIG_IGN)   // never die on a broken-pipe write

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
        fileHandle?.write(Data("\n==== AxiomWallet session \(Self.stamp(Date())) ====\n".utf8))

        // Keep the original stderr so a terminal-launched build still echoes.
        savedStderr = dup(STDERR_FILENO)

        // One pipe captures BOTH stdout (Swift print) and stderr (Rust
        // eprintln / NSLog). A background reader fans each chunk out to the
        // original stderr (echo), the file, and the ring buffer.
        let pipe = Pipe()
        capturePipe = pipe   // RETAIN — the actual fix (see property note above)
        let wfd = pipe.fileHandleForWriting.fileDescriptor
        dup2(wfd, STDOUT_FILENO)
        dup2(wfd, STDERR_FILENO)

        let saved = savedStderr
        let fh = fileHandle
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // echo to the original stderr (no-op under Finder → /dev/null)
            data.withUnsafeBytes { raw in
                if let base = raw.baseAddress { _ = write(saved, base, data.count) }
            }
            fh?.write(data)
            guard let self = self,
                  let chunk = String(data: data, encoding: .utf8) else { return }
            let now = Date()
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async {
                self.entries.append(contentsOf: lines.map { Entry(time: now, text: $0) })
                if self.entries.count > self.maxEntries {
                    self.entries.removeFirst(self.entries.count - self.maxEntries)
                }
            }
        }
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
