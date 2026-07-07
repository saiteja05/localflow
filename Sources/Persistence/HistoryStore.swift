import Foundation
import Observation

@Observable
public final class HistoryStore {
    public private(set) var entries: [HistoryEntry]
    public var isEnabled = true
    public var retentionLimit = 100 {
        didSet { trimAndRewrite() }
    }
    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "history.jsonl")
        let decoder = JSONDecoder()
        let raw = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        entries = raw.split(separator: "\n").compactMap {
            try? decoder.decode(HistoryEntry.self, from: Data($0.utf8))
        }
    }

    public func add(_ entry: HistoryEntry) {
        guard isEnabled else { return }
        entries.append(entry)
        if entries.count > retentionLimit {
            trimAndRewrite()
        } else if let line = try? JSONEncoder().encode(entry),
                  let handle = appendHandle() {
            handle.write(line)
            handle.write(Data("\n".utf8))
            try? handle.close()
        }
    }

    public func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func appendHandle() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    private func trimAndRewrite() {
        if entries.count > retentionLimit { entries.removeFirst(entries.count - retentionLimit) }
        let encoder = JSONEncoder()
        let lines = entries.compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
