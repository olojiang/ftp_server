import Foundation
import Testing
@testable import FTPServerCore

@Suite("FTP path resolver")
struct FTPPathResolverTests {
    @Test("maps absolute FTP paths inside the shared root")
    func mapsAbsolutePaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolver = FTPPathResolver(root: root)

        let resolved = try resolver.resolve("/docs/readme.txt", currentDirectory: "/")

        #expect(resolved.fileURL.path == root.appendingPathComponent("docs/readme.txt").standardizedFileURL.path)
        #expect(resolved.ftpPath == "/docs/readme.txt")
    }

    @Test("resolves relative paths from the current FTP directory")
    func resolvesRelativePaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolver = FTPPathResolver(root: root)

        let resolved = try resolver.resolve("image.png", currentDirectory: "/uploads")

        #expect(resolved.fileURL.path == root.appendingPathComponent("uploads/image.png").standardizedFileURL.path)
        #expect(resolved.ftpPath == "/uploads/image.png")
    }

    @Test("rejects paths escaping the shared root")
    func rejectsEscapingPaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolver = FTPPathResolver(root: root)

        #expect(throws: FTPPathResolver.PathError.escapesRoot) {
            try resolver.resolve("../../etc/passwd", currentDirectory: "/")
        }
    }
}
