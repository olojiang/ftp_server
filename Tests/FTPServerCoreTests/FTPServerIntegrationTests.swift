import Foundation
import Testing
@testable import FTPServerCore

@Suite("FTP server integration", .serialized)
struct FTPServerIntegrationTests {
    @Test("accepts login and returns the current FTP directory")
    func acceptsLoginAndPwd() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logStore = LogStore(maxEntries: 100, fileURL: nil)
        let server = FTPServer(configuration: .init(rootDirectory: root, port: 0, username: "hunter", password: "secret"), logStore: logStore)

        try server.start()
        let port = try server.boundPort()
        let client = try FTPTestClient(port: port)

        try #expect(client.readLine().hasPrefix("220"))
        try client.send("USER hunter")
        try #expect(client.readLine().hasPrefix("331"))
        try client.send("PASS secret")
        try #expect(client.readLine().hasPrefix("230"))
        try client.send("PWD")
        #expect(try client.readLine() == "257 \"/\" is the current directory")
        try client.send("QUIT")
        try #expect(client.readLine().hasPrefix("221"))

        server.stop()
    }

    @Test("rejects invalid passwords")
    func rejectsInvalidPasswords() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = FTPServer(configuration: .init(rootDirectory: root, port: 0, username: "hunter", password: "secret"), logStore: LogStore(maxEntries: 100, fileURL: nil))

        try server.start()
        let port = try server.boundPort()
        let client = try FTPTestClient(port: port)

        _ = try client.readLine()
        try client.send("USER hunter")
        _ = try client.readLine()
        try client.send("PASS wrong")
        try #expect(client.readLine().hasPrefix("530"))

        server.stop()
    }

    @Test("lists files through passive mode")
    func listsFilesThroughPassiveMode() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let server = FTPServer(configuration: .init(rootDirectory: root, port: 0, username: "hunter", password: "secret"), logStore: LogStore(maxEntries: 100, fileURL: nil))

        try server.start()
        let client = try FTPTestClient(port: try server.boundPort())
        _ = try client.readLine()
        try client.send("USER hunter")
        _ = try client.readLine()
        try client.send("PASS secret")
        _ = try client.readLine()
        try client.send("PASV")
        let passiveReply = try client.readLine()
        let dataPort = try passivePort(from: passiveReply)
        let dataClient = try FTPTestClient(port: dataPort)
        try client.send("NLST")
        let opening = try client.readLine()
        #expect(opening.hasPrefix("150"))
        let listing = try dataClient.readAllUntilClose()
        let closing = try client.readLine()
        #expect(closing.hasPrefix("226"))

        #expect(listing.contains("hello.txt"))
        server.stop()
    }

    @Test("lists files through extended passive mode")
    func listsFilesThroughExtendedPassiveMode() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let server = FTPServer(configuration: .init(rootDirectory: root, port: 0, username: "hunter", password: "secret"), logStore: LogStore(maxEntries: 100, fileURL: nil))

        try server.start()
        let client = try FTPTestClient(port: try server.boundPort())
        _ = try client.readLine()
        try client.send("USER hunter")
        _ = try client.readLine()
        try client.send("PASS secret")
        _ = try client.readLine()
        try client.send("EPSV")
        let passiveReply = try client.readLine()
        let dataPort = try extendedPassivePort(from: passiveReply)
        let dataClient = try FTPTestClient(port: dataPort)
        try client.send("NLST")
        let opening = try client.readLine()
        #expect(opening.hasPrefix("150"))
        let listing = try dataClient.readAllUntilClose()
        let closing = try client.readLine()
        #expect(closing.hasPrefix("226"))

        #expect(listing.contains("hello.txt"))
        server.stop()
    }

    @Test("lists files with MLSD for modern clients")
    func listsFilesWithMachineListing() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let server = FTPServer(configuration: .init(rootDirectory: root, port: 0, username: "hunter", password: "secret"), logStore: LogStore(maxEntries: 100, fileURL: nil))

        try server.start()
        let client = try FTPTestClient(port: try server.boundPort())
        try login(client)
        try client.send("PASV")
        let passiveReply = try client.readLine()
        let dataClient = try FTPTestClient(port: try passivePort(from: passiveReply))
        try client.send("MLSD")
        #expect(try client.readLine().hasPrefix("150"))
        let listing = try dataClient.readAllUntilClose()
        #expect(try client.readLine().hasPrefix("226"))

        #expect(listing.contains("type=file;"))
        #expect(listing.contains("size=5;"))
        #expect(listing.contains(" hello.txt"))
        server.stop()
    }

    @Test("uploads and downloads files through passive mode")
    func uploadsAndDownloadsFiles() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = FTPServer(configuration: .init(rootDirectory: root, port: 0, username: "hunter", password: "secret"), logStore: LogStore(maxEntries: 100, fileURL: nil))

        try server.start()
        let client = try FTPTestClient(port: try server.boundPort())
        try login(client)
        try client.send("PASV")
        let uploadPort = try passivePort(from: client.readLine())
        let uploadDataClient = try FTPTestClient(port: uploadPort)
        try client.send("STOR upload.txt")
        #expect(try client.readLine().hasPrefix("150"))
        try uploadDataClient.write(Data("uploaded content".utf8))
        uploadDataClient.close()
        #expect(try client.readLine().hasPrefix("226"))

        try client.send("PASV")
        let downloadPort = try passivePort(from: client.readLine())
        let downloadDataClient = try FTPTestClient(port: downloadPort)
        try client.send("RETR upload.txt")
        #expect(try client.readLine().hasPrefix("150"))
        let downloaded = try downloadDataClient.readAllUntilClose()
        #expect(try client.readLine().hasPrefix("226"))

        #expect(downloaded == "uploaded content")
        server.stop()
    }

    @Test("resumes downloads from REST offsets")
    func resumesDownloadsFromRestOffsets() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "0123456789".write(to: root.appendingPathComponent("payload.bin"), atomically: true, encoding: .utf8)
        let server = FTPServer(configuration: .init(rootDirectory: root, port: 0, username: "hunter", password: "secret"), logStore: LogStore(maxEntries: 100, fileURL: nil))

        try server.start()
        let client = try FTPTestClient(port: try server.boundPort())
        try login(client)
        try client.send("REST 4")
        #expect(try client.readLine().hasPrefix("350"))
        try client.send("PASV")
        let downloadPort = try passivePort(from: client.readLine())
        let downloadDataClient = try FTPTestClient(port: downloadPort)
        try client.send("RETR payload.bin")
        #expect(try client.readLine().hasPrefix("150"))
        let downloaded = try downloadDataClient.readAllUntilClose()
        #expect(try client.readLine().hasPrefix("226"))

        #expect(downloaded == "456789")
        server.stop()
    }

    @Test("accepts ABOR without failing unknown command")
    func acceptsAbortCommand() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = FTPServer(configuration: .init(rootDirectory: root, port: 0, username: "hunter", password: "secret"), logStore: LogStore(maxEntries: 100, fileURL: nil))

        try server.start()
        let client = try FTPTestClient(port: try server.boundPort())
        try login(client)
        try client.send("ABOR")

        #expect(try client.readLine().hasPrefix("226"))
        server.stop()
    }

    @Test("aborts an active download")
    func abortsActiveDownload() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x61, count: 32 * 1024 * 1024)
        try payload.write(to: root.appendingPathComponent("payload.bin"))
        let server = FTPServer(configuration: .init(rootDirectory: root, port: 0, username: "hunter", password: "secret"), logStore: LogStore(maxEntries: 100, fileURL: nil))

        try server.start()
        let client = try FTPTestClient(port: try server.boundPort())
        try login(client)
        try client.send("PASV")
        let downloadPort = try passivePort(from: client.readLine())
        let downloadDataClient = try FTPTestClient(port: downloadPort)
        try client.send("RETR payload.bin")
        #expect(try client.readLine().hasPrefix("150"))

        try await Task.sleep(nanoseconds: 100_000_000)
        try client.send("ABOR")

        #expect(try client.readLine(timeout: 5).hasPrefix("426"))
        #expect(try client.readLine(timeout: 5).hasPrefix("226"))
        downloadDataClient.close()
        server.stop()
    }

    @Test("renames directories with RNFR and RNTO")
    func renamesDirectories() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let oldDirectory = root.appendingPathComponent("old-folder")
        let newDirectory = root.appendingPathComponent("new-folder")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let server = FTPServer(configuration: .init(rootDirectory: root, port: 0, username: "hunter", password: "secret"), logStore: LogStore(maxEntries: 100, fileURL: nil))

        try server.start()
        let client = try FTPTestClient(port: try server.boundPort())
        try login(client)
        try client.send("RNFR old-folder")
        #expect(try client.readLine().hasPrefix("350"))
        try client.send("RNTO new-folder")
        #expect(try client.readLine().hasPrefix("250"))

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: newDirectory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
        server.stop()
    }

    @Test("defaults to eight concurrent transfers and supports eight concurrent downloads")
    func supportsEightConcurrentDownloadsByDefault() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = String(repeating: "0123456789abcdef", count: 4096)
        try payload.write(to: root.appendingPathComponent("payload.bin"), atomically: true, encoding: .utf8)
        let configuration = FTPServerConfiguration(rootDirectory: root, port: 0, username: "hunter", password: "secret")
        #expect(configuration.maxConcurrentTransfers == 8)
        let server = FTPServer(configuration: configuration, logStore: LogStore(maxEntries: 100, fileURL: nil))

        try server.start()
        let port = try server.boundPort()
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let client = try FTPTestClient(port: port)
                    try login(client)
                    try client.send("PASV")
                    let dataPort = try passivePort(from: client.readLine())
                    let dataClient = try FTPTestClient(port: dataPort)
                    try client.send("RETR payload.bin")
                    guard try client.readLine().hasPrefix("150") else {
                        throw FTPTestClient.TestClientError.readTimedOut
                    }
                    let downloaded = try dataClient.readAllUntilClose(timeout: 5)
                    guard try client.readLine(timeout: 5).hasPrefix("226") else {
                        throw FTPTestClient.TestClientError.readTimedOut
                    }
                    return downloaded
                }
            }
            for try await downloaded in group {
                #expect(downloaded == payload)
            }
        }
        server.stop()
    }

    @Test("supports eight concurrent uploads by default")
    func supportsEightConcurrentUploadsByDefault() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = String(repeating: "upload", count: 2048)
        let server = FTPServer(configuration: .init(rootDirectory: root, port: 0, username: "hunter", password: "secret"), logStore: LogStore(maxEntries: 100, fileURL: nil))

        try server.start()
        let port = try server.boundPort()
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let client = try FTPTestClient(port: port)
                    try login(client)
                    try client.send("PASV")
                    let dataPort = try passivePort(from: client.readLine())
                    let dataClient = try FTPTestClient(port: dataPort)
                    try client.send("STOR upload-\(index).txt")
                    guard try client.readLine().hasPrefix("150") else {
                        throw FTPTestClient.TestClientError.readTimedOut
                    }
                    try dataClient.write(Data(payload.utf8))
                    dataClient.close()
                    guard try client.readLine(timeout: 5).hasPrefix("226") else {
                        throw FTPTestClient.TestClientError.readTimedOut
                    }
                    return index
                }
            }
            for try await index in group {
                let saved = try String(contentsOf: root.appendingPathComponent("upload-\(index).txt"), encoding: .utf8)
                #expect(saved == payload)
            }
        }
        server.stop()
    }
}

private final class FTPTestClient {
    private let input: InputStream
    private let output: OutputStream

    init(port: UInt16) throws {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, "127.0.0.1" as CFString, UInt32(port), &readStream, &writeStream)
        guard let readStream, let writeStream else {
            throw TestClientError.connectionFailed
        }
        input = readStream.takeRetainedValue()
        output = writeStream.takeRetainedValue()
        input.open()
        output.open()
    }

    func send(_ line: String) throws {
        let bytes = Array((line + "\r\n").utf8)
        let written = bytes.withUnsafeBufferPointer { pointer in
            output.write(pointer.baseAddress!, maxLength: bytes.count)
        }
        if written != bytes.count {
            throw TestClientError.writeFailed
        }
    }

    func write(_ data: Data) throws {
        let written = data.withUnsafeBytes { pointer in
            output.write(pointer.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }
        if written != data.count {
            throw TestClientError.writeFailed
        }
    }

    func close() {
        output.close()
        input.close()
    }

    func readLine(timeout: TimeInterval = 2) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while Date() < deadline {
            if input.hasBytesAvailable {
                let count = input.read(&byte, maxLength: 1)
                if count == 1 {
                    data.append(byte[0])
                    if data.count >= 2 && data.suffix(2) == Data([13, 10]) {
                        return String(decoding: data.dropLast(2), as: UTF8.self)
                    }
                }
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        throw TestClientError.readTimedOut
    }

    func readAllUntilClose(timeout: TimeInterval = 2) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            if input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count > 0 {
                    data.append(contentsOf: buffer[..<count])
                } else if count == 0 {
                    return String(decoding: data, as: UTF8.self)
                }
            } else if !data.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                if !input.hasBytesAvailable {
                    return String(decoding: data, as: UTF8.self)
                }
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        throw TestClientError.readTimedOut
    }

    enum TestClientError: Error {
        case connectionFailed
        case readTimedOut
        case writeFailed
    }
}

private func login(_ client: FTPTestClient) throws {
    _ = try client.readLine()
    try client.send("USER hunter")
    _ = try client.readLine()
    try client.send("PASS secret")
    _ = try client.readLine()
}

private func passivePort(from reply: String) throws -> UInt16 {
    guard let start = reply.firstIndex(of: "("), let end = reply.firstIndex(of: ")") else {
        throw FTPTestClient.TestClientError.readTimedOut
    }
    let values = reply[reply.index(after: start)..<end].split(separator: ",").compactMap { UInt16($0) }
    guard values.count == 6 else {
        throw FTPTestClient.TestClientError.readTimedOut
    }
    return values[4] * 256 + values[5]
}

private func extendedPassivePort(from reply: String) throws -> UInt16 {
    guard let start = reply.firstIndex(of: "("), let end = reply.firstIndex(of: ")") else {
        throw FTPTestClient.TestClientError.readTimedOut
    }
    let payload = reply[reply.index(after: start)..<end]
    let values = payload.split(separator: "|", omittingEmptySubsequences: false)
    guard values.count == 5, let port = UInt16(values[3]) else {
        throw FTPTestClient.TestClientError.readTimedOut
    }
    return port
}
