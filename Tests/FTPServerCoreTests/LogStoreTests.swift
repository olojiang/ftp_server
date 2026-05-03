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
}
