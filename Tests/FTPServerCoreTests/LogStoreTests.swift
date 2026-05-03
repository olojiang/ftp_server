import Foundation
import Testing
@testable import FTPServerCore

@Suite("Log store")
struct LogStoreTests {
    @Test("records structured log lines")
    func recordsStructuredLogs() async {
        let store = LogStore(maxEntries: 10, fileURL: nil)

        await store.append(level: .info, category: .state, message: "server started")
        let entries = await store.entries

        #expect(entries.count == 1)
        #expect(entries[0].level == .info)
        #expect(entries[0].category == .state)
        #expect(entries[0].message == "server started")
    }

    @Test("keeps only the configured number of in-memory entries")
    func limitsInMemoryEntries() async {
        let store = LogStore(maxEntries: 2, fileURL: nil)

        await store.append(level: .debug, category: .command, message: "one")
        await store.append(level: .debug, category: .command, message: "two")
        await store.append(level: .debug, category: .command, message: "three")
        let entries = await store.entries

        #expect(entries.map(\.message) == ["two", "three"])
    }

    @Test("copies full log file even when memory is truncated")
    func copiesFullLogFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-ftp-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = LogStore(maxEntries: 1, fileURL: fileURL)

        await store.append(level: .info, category: .state, message: "one")
        await store.append(level: .info, category: .state, message: "two")
        let entries = await store.entries
        let contents = await store.copyableContents()

        #expect(entries.map(\.message) == ["two"])
        #expect(contents.contains("[state] one"))
        #expect(contents.contains("[state] two"))
    }

    @Test("clears in-memory and file logs")
    func clearsMemoryAndFileLogs() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-ftp-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = LogStore(maxEntries: 10, fileURL: fileURL)

        await store.append(level: .info, category: .state, message: "old")
        await store.clear()
        let entries = await store.entries
        let contents = await store.copyableContents()

        #expect(entries.isEmpty)
        #expect(contents.isEmpty)
    }
}
