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
