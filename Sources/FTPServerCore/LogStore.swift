import Foundation

public enum LogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public enum LogCategory: String, Sendable {
    case state = "state"
    case command = "command"
    case transfer = "transfer"
    case auth = "auth"
    case error = "error"
}

public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String

    public var formatted: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(formatter.string(from: timestamp)) [\(level.rawValue)] [\(category.rawValue)] \(message)"
    }
}

public actor LogStore {
    private let maxEntries: Int
    private let fileURL: URL?
    private var storage: [LogEntry] = []

    public init(maxEntries: Int = 1_000, fileURL: URL? = LogStore.defaultLogFileURL()) {
        self.maxEntries = maxEntries
        self.fileURL = fileURL
    }

    public var entries: [LogEntry] {
        storage
    }

    public func copyableContents() -> String {
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let contents = String(data: data, encoding: .utf8),
           !contents.isEmpty {
            return contents
        }

        return storage.map(\.formatted).joined(separator: "\n")
    }

    public func append(level: LogLevel, category: LogCategory, message: String) {
        let entry = LogEntry(id: UUID(), timestamp: Date(), level: level, category: category, message: message)
        storage.append(entry)
        if storage.count > maxEntries {
            storage.removeFirst(storage.count - maxEntries)
        }
        writeToFile(entry)
    }

    public static func defaultLogFileURL() -> URL? {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        return logs
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("LocalFTPServer", isDirectory: true)
            .appendingPathComponent("local-ftp.log")
    }

    private func writeToFile(_ entry: LogEntry) {
        guard let fileURL else {
            return
        }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let line = entry.formatted + "\n"
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: fileURL)
            }
        } catch {
            // Logging must not crash the FTP service.
        }
    }
}
