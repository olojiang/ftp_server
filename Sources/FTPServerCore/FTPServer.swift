import Foundation
import Network

public struct FTPServerConfiguration: Equatable, Sendable {
    public let rootDirectory: URL
    public let port: UInt16
    public let username: String
    public let password: String

    public init(rootDirectory: URL, port: UInt16, username: String, password: String) {
        self.rootDirectory = rootDirectory
        self.port = port
        self.username = username
        self.password = password
    }
}

public final class FTPServer: @unchecked Sendable {
    public enum ServerError: Error {
        case alreadyRunning
        case notRunning
        case failedToBind
    }

    private let configuration: FTPServerConfiguration
    private let logStore: LogStore
    private let queue = DispatchQueue(label: "local-ftp.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var sessions: [FTPSession] = []
    private var currentPort: UInt16?

    public init(configuration: FTPServerConfiguration, logStore: LogStore) {
        self.configuration = configuration
        self.logStore = logStore
    }

    public func start() throws {
        lock.lock()
        if listener != nil {
            lock.unlock()
            throw ServerError.alreadyRunning
        }
        lock.unlock()

        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: configuration.port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let startup = StartupSignal()

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.currentPort = listener.port?.rawValue
                self.lock.unlock()
                Task {
                    await self.logStore.append(level: .info, category: .state, message: "FTP server listening on port \(listener.port?.rawValue ?? 0), root=\(self.configuration.rootDirectory.path)")
                }
                startup.signal()
            case .failed(let error):
                Task {
                    await self.logStore.append(level: .error, category: .error, message: "FTP listener failed: \(error)")
                }
                startup.signal(error)
            default:
                break
            }
        }

        lock.lock()
        self.listener = listener
        lock.unlock()
        listener.start(queue: queue)

        if startup.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw ServerError.failedToBind
        }
        if let startupError = startup.error {
            throw startupError
        }
    }

    public func stop() {
        lock.lock()
        let listener = listener
        let sessions = sessions
        self.listener = nil
        self.sessions.removeAll()
        self.currentPort = nil
        lock.unlock()

        listener?.cancel()
        sessions.forEach { $0.close() }
        Task {
            await logStore.append(level: .info, category: .state, message: "FTP server stopped")
        }
    }

    public func boundPort() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        guard let currentPort else {
            throw ServerError.notRunning
        }
        return currentPort
    }

    private func accept(_ connection: NWConnection) {
        let session = FTPSession(connection: connection, configuration: configuration, logStore: logStore)
        lock.lock()
        sessions.append(session)
        lock.unlock()
        session.start()
    }
}

private final class FTPSession: @unchecked Sendable {
    private let connection: NWConnection
    private let configuration: FTPServerConfiguration
    private let logStore: LogStore
    private let resolver: FTPPathResolver
    private let queue = DispatchQueue(label: "local-ftp.session.\(UUID().uuidString)")
    private var buffer = Data()
    private var username: String?
    private var authenticated = false
    private var currentDirectory = "/"
    private var passiveDataEndpoint: PassiveDataEndpoint?
    private var activeDataEndpoint: NWEndpoint?

    init(connection: NWConnection, configuration: FTPServerConfiguration, logStore: LogStore) {
        self.connection = connection
        self.configuration = configuration
        self.logStore = logStore
        self.resolver = FTPPathResolver(root: configuration.rootDirectory)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send("220 LocalFTPServer ready")
                self.receive()
            case .failed(let error):
                Task {
                    await self.logStore.append(level: .error, category: .error, message: "control connection failed: \(error)")
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        passiveDataEndpoint?.cancel()
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func processBuffer() {
        while let range = buffer.range(of: Data([13, 10])) {
            let lineData = buffer[..<range.lowerBound]
            buffer.removeSubrange(..<range.upperBound)
            let line = String(decoding: lineData, as: UTF8.self)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        Task {
            await logStore.append(level: .debug, category: .command, message: "client -> \(redacted(line))")
        }

        let command: FTPCommand
        do {
            command = try FTPCommandParser.parse(line)
        } catch {
            send("500 Empty command")
            return
        }

        switch command.verb {
        case .user:
            username = command.argument
            send("331 Password required")
        case .pass:
            if username == configuration.username && command.argument == configuration.password {
                authenticated = true
                Task {
                    await logStore.append(level: .info, category: .auth, message: "user \(configuration.username) authenticated")
                }
                send("230 Login successful")
            } else {
                authenticated = false
                Task {
                    await logStore.append(level: .warning, category: .auth, message: "failed login for user \(username ?? "<none>")")
                }
                send("530 Login incorrect")
            }
        case .quit:
            send("221 Goodbye")
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.close()
            }
        case .syst:
            send("215 UNIX Type: L8")
        case .feat:
            sendMultiline("211", lines: ["UTF8", "SIZE", "MDTM", "PASV"], end: "Features")
        case .noop:
            send("200 NOOP ok")
        case .type:
            send("200 Type set to \(command.argument ?? "I")")
        default:
            guard authenticated else {
                send("530 Please login with USER and PASS")
                return
            }
            handleAuthenticated(command)
        }
    }

    private func handleAuthenticated(_ command: FTPCommand) {
        switch command.verb {
        case .pwd:
            send("257 \"\(currentDirectory)\" is the current directory")
        case .cwd:
            changeDirectory(command.argument)
        case .cdup:
            changeDirectory("..")
        case .pasv:
            openPassiveMode()
        case .port:
            configureActiveMode(command.argument)
        case .list:
            sendDirectoryListing(nameOnly: false, path: command.argument)
        case .nlst:
            sendDirectoryListing(nameOnly: true, path: command.argument)
        case .retr:
            retrieve(command.argument)
        case .stor:
            store(command.argument)
        case .dele:
            delete(command.argument)
        case .mkd:
            makeDirectory(command.argument)
        case .rmd:
            removeDirectory(command.argument)
        case .size:
            size(command.argument)
        case .mdtm:
            modificationTime(command.argument)
        case .unknown(let verb):
            send("502 Command \(verb) not implemented")
        default:
            send("502 Command not implemented")
        }
    }

    private func changeDirectory(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                send("550 Directory not found")
                return
            }
            currentDirectory = resolved.ftpPath
            send("250 Directory changed to \(currentDirectory)")
        } catch {
            send("550 Invalid directory")
        }
    }

    private func openPassiveMode() {
        do {
            passiveDataEndpoint?.cancel()
            let endpoint = try PassiveDataEndpoint(queue: queue)
            passiveDataEndpoint = endpoint
            guard let port = endpoint.port else {
                send("425 Cannot open passive connection")
                return
            }
            let p1 = port / 256
            let p2 = port % 256
            send("227 Entering Passive Mode (127,0,0,1,\(p1),\(p2))")
            Task {
                await logStore.append(level: .info, category: .transfer, message: "passive data listener opened on port \(port)")
            }
        } catch {
            send("425 Cannot open passive connection")
        }
    }

    private func configureActiveMode(_ argument: String?) {
        guard let argument else {
            send("501 Missing PORT argument")
            return
        }
        let values = argument.split(separator: ",").compactMap { UInt8($0) }
        guard values.count == 6 else {
            send("501 Invalid PORT argument")
            return
        }
        let host = "\(values[0]).\(values[1]).\(values[2]).\(values[3])"
        let port = UInt16(values[4]) * 256 + UInt16(values[5])
        activeDataEndpoint = .hostPort(host: .ipv4(IPv4Address(host)!), port: NWEndpoint.Port(rawValue: port)!)
        send("200 PORT command successful")
    }

    private func sendDirectoryListing(nameOnly: Bool, path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            let items = try FileManager.default.contentsOfDirectory(at: resolved.fileURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let listing = items.map { item in
                nameOnly ? item.lastPathComponent : formatListItem(item)
            }.joined(separator: "\r\n") + "\r\n"
            sendData(Data(listing.utf8), openingReply: "150 Opening data connection", closingReply: "226 Transfer complete")
        } catch {
            send("550 Cannot list directory")
        }
    }

    private func retrieve(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            let data = try Data(contentsOf: resolved.fileURL)
            sendData(data, openingReply: "150 Opening binary mode data connection", closingReply: "226 Transfer complete")
        } catch {
            send("550 Cannot read file")
        }
    }

    private func store(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            receiveData(openingReply: "150 Ok to send data", closingReply: "226 Transfer complete") { data in
                try data.write(to: resolved.fileURL)
            }
        } catch {
            send("550 Cannot write file")
        }
    }

    private func delete(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            try FileManager.default.removeItem(at: resolved.fileURL)
            send("250 File deleted")
        } catch {
            send("550 Cannot delete file")
        }
    }

    private func makeDirectory(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            try FileManager.default.createDirectory(at: resolved.fileURL, withIntermediateDirectories: true)
            send("257 \"\(resolved.ftpPath)\" created")
        } catch {
            send("550 Cannot create directory")
        }
    }

    private func removeDirectory(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            try FileManager.default.removeItem(at: resolved.fileURL)
            send("250 Directory removed")
        } catch {
            send("550 Cannot remove directory")
        }
    }

    private func size(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.fileURL.path)
            let fileSize = attributes[.size] as? UInt64 ?? 0
            send("213 \(fileSize)")
        } catch {
            send("550 Cannot get file size")
        }
    }

    private func modificationTime(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.fileURL.path)
            guard let date = attributes[.modificationDate] as? Date else {
                send("550 Cannot get modification time")
                return
            }
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMddHHmmss"
            send("213 \(formatter.string(from: date))")
        } catch {
            send("550 Cannot get modification time")
        }
    }

    private func sendData(_ data: Data, openingReply: String, closingReply: String) {
        send(openingReply)
        withDataConnection { dataConnection in
            dataConnection.send(content: data, completion: .contentProcessed { [weak self] _ in
                dataConnection.cancel()
                self?.send(closingReply)
                Task {
                    await self?.logStore.append(level: .info, category: .transfer, message: "sent \(data.count) bytes")
                }
            })
        }
    }

    private func receiveData(openingReply: String, closingReply: String, writer: @escaping @Sendable (Data) throws -> Void) {
        send(openingReply)
        withDataConnection { [weak self] dataConnection in
            guard let session = self else { return }
            let accumulator = DataAccumulator()
            let logStore = session.logStore
            @Sendable func receiveLoop() {
                dataConnection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, _ in
                    if let data {
                        accumulator.append(data)
                    }
                    if isComplete {
                        let received = accumulator.data()
                        do {
                            try writer(received)
                            session.send(closingReply)
                            let byteCount = received.count
                            Task {
                                await logStore.append(level: .info, category: .transfer, message: "received \(byteCount) bytes")
                            }
                        } catch {
                            session.send("550 Cannot save uploaded data")
                        }
                        dataConnection.cancel()
                    } else {
                        receiveLoop()
                    }
                }
            }
            receiveLoop()
        }
    }

    private func withDataConnection(_ body: @escaping @Sendable (NWConnection) -> Void) {
        if let endpoint = activeDataEndpoint {
            activeDataEndpoint = nil
            let dataConnection = NWConnection(to: endpoint, using: .tcp)
            dataConnection.stateUpdateHandler = { state in
                if case .ready = state {
                    body(dataConnection)
                }
            }
            dataConnection.start(queue: queue)
            return
        }

        guard let passiveDataEndpoint else {
            send("425 Use PASV or PORT first")
            return
        }
        passiveDataEndpoint.acquire { [weak self] connection in
            body(connection)
            self?.passiveDataEndpoint?.cancel()
            self?.passiveDataEndpoint = nil
        }
    }

    private func send(_ line: String) {
        let data = Data((line + "\r\n").utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                Task {
                    await self?.logStore.append(level: .error, category: .error, message: "send failed: \(error)")
                }
            }
        })
        Task {
            await logStore.append(level: .debug, category: .command, message: "server -> \(line)")
        }
    }

    private func sendMultiline(_ code: String, lines: [String], end: String) {
        send("\(code)-\(end)")
        for line in lines {
            send(" \(line)")
        }
        send("\(code) End")
    }

    private func formatListItem(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDirectory = values?.isDirectory == true
        let size = values?.fileSize ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH:mm"
        let date = formatter.string(from: values?.contentModificationDate ?? Date())
        let permissions = isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
        return "\(permissions) 1 owner group \(size) \(date) \(url.lastPathComponent)"
    }

    private func redacted(_ line: String) -> String {
        if line.uppercased().hasPrefix("PASS") {
            return "PASS ******"
        }
        return line
    }
}

private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class PassiveDataEndpoint: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pendingConnection: NWConnection?
    private var pendingHandler: (@Sendable (NWConnection) -> Void)?

    var port: UInt16? {
        listener.port?.rawValue
    }

    init(queue: DispatchQueue) throws {
        self.queue = DispatchQueue(label: "local-ftp.passive.\(UUID().uuidString)")
        listener = try NWListener(using: .tcp, on: 0)
        let startup = StartupSignal()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                startup.signal()
            case .failed(let error):
                startup.signal(error)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                if case .ready = state {
                    self.deliver(connection)
                }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: self.queue)
        if startup.wait(timeout: .now() + 5) == .timedOut {
            throw FTPServer.ServerError.failedToBind
        }
        if let error = startup.error {
            throw error
        }
    }

    func acquire(_ handler: @escaping @Sendable (NWConnection) -> Void) {
        lock.lock()
        if let connection = pendingConnection {
            pendingConnection = nil
            lock.unlock()
            handler(connection)
            return
        }
        pendingHandler = handler
        lock.unlock()
    }

    func cancel() {
        listener.cancel()
        lock.lock()
        let connection = pendingConnection
        pendingConnection = nil
        pendingHandler = nil
        lock.unlock()
        connection?.cancel()
    }

    private func deliver(_ connection: NWConnection) {
        lock.lock()
        if let handler = pendingHandler {
            pendingHandler = nil
            lock.unlock()
            handler(connection)
            return
        }
        pendingConnection = connection
        lock.unlock()
    }
}

private final class StartupSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didSignal = false
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func signal(_ error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !didSignal else { return }
        didSignal = true
        storedError = error
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }
}
