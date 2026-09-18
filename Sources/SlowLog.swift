import Foundation

/// Notes about whatever held the switcher up, in ~/Library/Logs/TabStash.log. Written
/// only when something is slow, so the file stays small and points at what to fix.
enum SlowLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TabStash.log")

    static func note(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}
