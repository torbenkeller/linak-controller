import Foundation
import StehaufCore

/// Speicherorte der App unter `~/Library/Application Support/Stehauf`.
enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Stehauf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let config = support.appendingPathComponent("config.json")
    static let state = support.appendingPathComponent("state.json")
    static let logs: URL = {
        let dir = support.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// Schreibt das Messprotokoll als JSON Lines, eine Datei pro Tag.
final class EventLogger {
    private var handle: FileHandle?
    private var currentDay = ""
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func record(kind: String, message: String? = nil, at date: Date = Date()) -> LogRecord {
        LogRecord(t: stamp.string(from: date), kind: kind, message: message)
    }

    func write(_ record: LogRecord, at date: Date = Date()) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        let day = dayFormatter.string(from: date)
        if day != currentDay || handle == nil {
            try? handle?.close()
            currentDay = day
            let url = Paths.logs.appendingPathComponent("\(day).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: line)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
