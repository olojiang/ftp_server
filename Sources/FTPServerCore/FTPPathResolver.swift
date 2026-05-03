import Foundation

public struct ResolvedFTPPath: Equatable, Sendable {
    public let fileURL: URL
    public let ftpPath: String
}

public struct FTPPathResolver: Sendable {
    public enum PathError: Error, Equatable {
        case escapesRoot
        case invalidPath
    }

    private let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func resolve(_ rawPath: String?, currentDirectory: String) throws -> ResolvedFTPPath {
        let input = (rawPath?.isEmpty == false ? rawPath! : currentDirectory)
        let components = try normalizedComponents(for: input, currentDirectory: currentDirectory)
        let ftpPath = "/" + components.joined(separator: "/")
        let url = components.reduce(root) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL

        guard isInsideRoot(url) else {
            throw PathError.escapesRoot
        }

        return ResolvedFTPPath(fileURL: url, ftpPath: ftpPath == "/" ? "/" : ftpPath)
    }

    private func normalizedComponents(for path: String, currentDirectory: String) throws -> [String] {
        let base: [String]
        let rawComponents: [String]

        if path.hasPrefix("/") {
            base = []
            rawComponents = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        } else {
            base = currentDirectory.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            rawComponents = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }

        var result = base
        for component in rawComponents {
            switch component {
            case ".", "":
                continue
            case "..":
                guard !result.isEmpty else {
                    throw PathError.escapesRoot
                }
                result.removeLast()
            default:
                guard component != "/" else {
                    throw PathError.invalidPath
                }
                result.append(component)
            }
        }
        return result
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count >= rootComponents.count else {
            return false
        }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }
}
