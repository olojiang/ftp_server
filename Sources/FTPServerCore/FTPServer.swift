import Foundation
import Darwin
import Network

public struct FTPServerConfiguration: Equatable, Sendable {
    public static let defaultMaxConcurrentTransfers = 8

    public let rootDirectory: URL
    public let port: UInt16
    public let username: String
    public let password: String
    public let maxConcurrentTransfers: Int

    public init(
        rootDirectory: URL,
        port: UInt16,
        username: String,
        password: String,
        maxConcurrentTransfers: Int = Self.defaultMaxConcurrentTransfers
    ) {
        self.rootDirectory = rootDirectory
        self.port = port
        self.username = username
        self.password = password
        self.maxConcurrentTransfers = max(1, maxConcurrentTransfers)
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
    private let transferLimiter: TransferLimiter
    private let queue = DispatchQueue(label: "local-ftp.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var sessions: [FTPSession] = []
    private var currentPort: UInt16?

    public init(configuration: FTPServerConfiguration, logStore: LogStore) {
        self.configuration = configuration
        self.logStore = logStore
        self.transferLimiter = TransferLimiter(maxConcurrent: configuration.maxConcurrentTransfers)
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
                    await self.logStore.append(level: .info, category: .state, message: "FTP server listening on port \(listener.port?.rawValue ?? 0), root=\(self.configuration.rootDirectory.path), maxTransfers=\(self.configuration.maxConcurrentTransfers)")
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
        let session = FTPSession(connection: connection, configuration: configuration, logStore: logStore, transferLimiter: transferLimiter)
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
    private let transferLimiter: TransferLimiter
    private let queue = DispatchQueue(label: "local-ftp.session.\(UUID().uuidString)")
    private var buffer = Data()
    private var username: String?
    private var authenticated = false
    private var currentDirectory = "/"
    private var pendingRenameSource: ResolvedFTPPath?
    private var passiveDataEndpoint: PassiveDataEndpoint?
    private var activeDataEndpoint: NWEndpoint?
    private var restartOffset: UInt64 = 0
    private var interruptedTransferAwaitingAbort = false
    private let transferStateLock = NSLock()
    private var pendingTransfers: [PendingDataTransfer] = []
    private var activeTransfers: [ActiveDataTransfer] = []

    init(connection: NWConnection, configuration: FTPServerConfiguration, logStore: LogStore, transferLimiter: TransferLimiter) {
        self.connection = connection
        self.configuration = configuration
        self.logStore = logStore
        self.resolver = FTPPathResolver(root: configuration.rootDirectory)
        self.transferLimiter = transferLimiter
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
        cancelPendingTransfers()
        cancelActiveTransfers()
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
            sendMultiline("211", lines: ["UTF8", "SIZE", "MDTM", "REST STREAM", "MLST type*;size*;modify*;", "PASV", "EPSV"], end: "Features")
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
        case .epsv:
            openExtendedPassiveMode(command.argument)
        case .port:
            configureActiveMode(command.argument)
        case .list:
            sendDirectoryListing(nameOnly: false, path: command.argument)
        case .nlst:
            sendDirectoryListing(nameOnly: true, path: command.argument)
        case .mlsd:
            sendMachineDirectoryListing(command.argument)
        case .mlst:
            machineList(command.argument)
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
        case .rnfr:
            renameFrom(command.argument)
        case .rnto:
            renameTo(command.argument)
        case .size:
            size(command.argument)
        case .mdtm:
            modificationTime(command.argument)
        case .rest:
            restart(command.argument)
        case .abor:
            abortTransfer()
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
            let hostTuple = passiveModeHost().replacingOccurrences(of: ".", with: ",")
            send("227 Entering Passive Mode (\(hostTuple),\(p1),\(p2))")
            Task {
                await logStore.append(level: .info, category: .transfer, message: "passive data listener opened on \(hostTuple.replacingOccurrences(of: ",", with: ".")):\(port)")
            }
        } catch {
            send("425 Cannot open passive connection")
        }
    }

    private func passiveModeHost() -> String {
        guard let remoteAddress = remoteIPv4Address(), !remoteAddress.hasPrefix("127.") else {
            return "127.0.0.1"
        }
        return localIPv4AddressForRoute(to: remoteAddress) ?? LocalIPv4AddressProvider.preferredAddress() ?? "127.0.0.1"
    }

    private func remoteIPv4Address() -> String? {
        guard case .hostPort(let host, _) = connection.endpoint else {
            return nil
        }
        switch host {
        case .ipv4(let address):
            return "\(address)"
        case .name(let name, _):
            return name
        default:
            return nil
        }
    }

    private func openExtendedPassiveMode(_ argument: String?) {
        if argument?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "ALL" {
            send("200 EPSV ALL ok")
            return
        }
        do {
            passiveDataEndpoint?.cancel()
            let endpoint = try PassiveDataEndpoint(queue: queue)
            passiveDataEndpoint = endpoint
            guard let port = endpoint.port else {
                send("425 Cannot open passive connection")
                return
            }
            send("229 Entering Extended Passive Mode (|||\(port)|)")
            Task {
                await logStore.append(level: .info, category: .transfer, message: "extended passive data listener opened on port \(port)")
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

    private func sendMachineDirectoryListing(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            let items = try FileManager.default.contentsOfDirectory(
                at: resolved.fileURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            )
            let listing = items.map { item in
                "\(formatMachineListFacts(item)) \(item.lastPathComponent)"
            }.joined(separator: "\r\n") + "\r\n"
            sendData(Data(listing.utf8), openingReply: "150 Opening data connection for MLSD", closingReply: "226 Transfer complete")
        } catch {
            send("550 Cannot list directory")
        }
    }

    private func machineList(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            guard FileManager.default.fileExists(atPath: resolved.fileURL.path) else {
                send("550 Path not found")
                return
            }
            sendMultiline("250", lines: ["\(formatMachineListFacts(resolved.fileURL)) \(resolved.ftpPath)"], end: "Listing")
        } catch {
            send("550 Cannot list path")
        }
    }

    private func retrieve(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            let data = try Data(contentsOf: resolved.fileURL)
            let offset = restartOffset
            restartOffset = 0
            guard offset <= UInt64(data.count) else {
                send("554 Restart offset exceeds file size")
                return
            }
            let payload = offset == 0 ? data : data.subdata(in: Int(offset)..<data.count)
            sendData(payload, openingReply: "150 Opening binary mode data connection", closingReply: "226 Transfer complete")
        } catch {
            restartOffset = 0
            send("550 Cannot read file")
        }
    }

    private func restart(_ marker: String?) {
        guard let marker, let offset = UInt64(marker.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            send("501 Invalid restart marker")
            return
        }
        restartOffset = offset
        send("350 Restarting at \(offset). Send STORE or RETR to initiate transfer")
    }

    private func abortTransfer() {
        restartOffset = 0
        let didCancelPendingTransfer = cancelPendingTransfers()
        let didCancelActiveTransfer = cancelActiveTransfers()
        let didInterruptRecentTransfer = interruptedTransferAwaitingAbort
        interruptedTransferAwaitingAbort = false
        passiveDataEndpoint?.cancel()
        passiveDataEndpoint = nil
        activeDataEndpoint = nil
        if didCancelPendingTransfer || didCancelActiveTransfer || didInterruptRecentTransfer {
            send("426 Transfer aborted")
        }
        send("226 Abort successful")
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

    private func renameFrom(_ path: String?) {
        do {
            let resolved = try resolver.resolve(path, currentDirectory: currentDirectory)
            guard FileManager.default.fileExists(atPath: resolved.fileURL.path) else {
                pendingRenameSource = nil
                send("550 Path not found")
                return
            }
            pendingRenameSource = resolved
            send("350 Ready for RNTO")
        } catch {
            pendingRenameSource = nil
            send("550 Cannot rename path")
        }
    }

    private func renameTo(_ path: String?) {
        guard let source = pendingRenameSource else {
            send("503 Bad sequence of commands")
            return
        }
        pendingRenameSource = nil

        do {
            let destination = try resolver.resolve(path, currentDirectory: currentDirectory)
            try FileManager.default.moveItem(at: source.fileURL, to: destination.fileURL)
            send("250 Rename successful")
        } catch {
            send("550 Cannot rename path")
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
        let pendingTransfer = PendingDataTransfer()
        installPendingTransfer(pendingTransfer)
        transferLimiter.acquire { [weak self] permit in
            guard let self else {
                permit.release()
                return
            }
            self.queue.async { [weak self] in
                guard let self else {
                    permit.release()
                    return
                }
                guard !pendingTransfer.isCancelled else {
                    self.clearPendingTransfer(pendingTransfer)
                    permit.release()
                    return
                }
                self.send(openingReply)
                let didStart = self.withDataConnection { [weak self] dataConnection in
                    guard let self else {
                        permit.release()
                        dataConnection.cancel()
                        return
                    }
                    guard !pendingTransfer.isCancelled else {
                        self.clearPendingTransfer(pendingTransfer)
                        permit.release()
                        dataConnection.cancel()
                        return
                    }
                    self.clearPendingTransfer(pendingTransfer)
                    let transfer = ActiveDataTransfer(connection: dataConnection, permit: permit)
                    self.interruptedTransferAwaitingAbort = false
                    self.installActiveTransfer(transfer)
                    self.sendChunks(data, offset: 0, transfer: transfer, closingReply: closingReply)
                } onTimeout: { [weak self] in
                    self?.clearPendingTransfer(pendingTransfer)
                    permit.release()
                    if pendingTransfer.isCancelled == false {
                        self?.send("425 Data connection timed out")
                    }
                }
                if !didStart {
                    self.clearPendingTransfer(pendingTransfer)
                    permit.release()
                }
            }
        }
    }

    private func sendChunks(_ data: Data, offset: Int, transfer: ActiveDataTransfer, closingReply: String) {
        guard !transfer.isFinished else { return }
        guard offset < data.count else {
            if transfer.finish() {
                clearActiveTransfer(transfer)
                interruptedTransferAwaitingAbort = false
                send(closingReply)
                Task {
                    await logStore.append(level: .info, category: .transfer, message: "sent \(data.count) bytes")
                }
            }
            return
        }

        let end = min(offset + 256 * 1024, data.count)
        let chunk = data.subdata(in: offset..<end)
        transfer.connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                if error != nil {
                    if transfer.finish() {
                        self.clearActiveTransfer(transfer)
                        self.interruptedTransferAwaitingAbort = true
                    }
                    return
                }
                self.sendChunks(data, offset: end, transfer: transfer, closingReply: closingReply)
            }
        })
    }

    private func installActiveTransfer(_ transfer: ActiveDataTransfer) {
        transferStateLock.lock()
        activeTransfers.append(transfer)
        transferStateLock.unlock()
    }

    private func clearActiveTransfer(_ transfer: ActiveDataTransfer) {
        transferStateLock.lock()
        activeTransfers.removeAll { $0 === transfer }
        transferStateLock.unlock()
    }

    @discardableResult
    private func cancelActiveTransfers() -> Bool {
        transferStateLock.lock()
        let transfers = activeTransfers
        activeTransfers.removeAll()
        transferStateLock.unlock()
        return transfers.reduce(false) { didCancel, transfer in
            transfer.finish() || didCancel
        }
    }

    private func installPendingTransfer(_ transfer: PendingDataTransfer) {
        transferStateLock.lock()
        pendingTransfers.append(transfer)
        transferStateLock.unlock()
    }

    private func clearPendingTransfer(_ transfer: PendingDataTransfer) {
        transferStateLock.lock()
        pendingTransfers.removeAll { $0 === transfer }
        transferStateLock.unlock()
    }

    @discardableResult
    private func cancelPendingTransfers() -> Bool {
        transferStateLock.lock()
        let transfers = pendingTransfers
        pendingTransfers.removeAll()
        transferStateLock.unlock()
        return transfers.reduce(false) { didCancel, transfer in
            transfer.cancel() || didCancel
        }
    }

    private func receiveData(openingReply: String, closingReply: String, writer: @escaping @Sendable (Data) throws -> Void) {
        transferLimiter.acquire { [weak self] permit in
            guard let self else {
                permit.release()
                return
            }
            self.queue.async { [weak self] in
                guard let self else {
                    permit.release()
                    return
                }
                self.send(openingReply)
                let didStart = self.withDataConnection { [weak self] dataConnection in
                    guard let session = self else {
                        permit.release()
                        return
                    }
                    let accumulator = DataAccumulator()
                    let logStore = session.logStore
                    @Sendable func receiveLoop() {
                        dataConnection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, _ in
                            if let data {
                                accumulator.append(data)
                            }
                            if isComplete {
                                session.queue.async {
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
                                    permit.release()
                                    dataConnection.cancel()
                                }
                            } else {
                                receiveLoop()
                            }
                        }
                    }
                    receiveLoop()
                } onTimeout: { [weak self] in
                    permit.release()
                    self?.send("425 Data connection timed out")
                }
                if !didStart {
                    permit.release()
                }
            }
        }
    }

    private func withDataConnection(
        _ body: @escaping @Sendable (NWConnection) -> Void,
        onTimeout: @escaping @Sendable () -> Void
    ) -> Bool {
        if let endpoint = activeDataEndpoint {
            activeDataEndpoint = nil
            let dataConnection = NWConnection(to: endpoint, using: .tcp)
            dataConnection.stateUpdateHandler = { state in
                if case .ready = state {
                    body(dataConnection)
                }
            }
            dataConnection.start(queue: queue)
            return true
        }

        guard let passiveDataEndpoint else {
            send("425 Use PASV or PORT first")
            return false
        }
        let endpoint = passiveDataEndpoint
        endpoint.acquire { [weak self] connection in
            self?.queue.async { [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                body(connection)
                self.clearPassiveDataEndpoint(endpoint)
            }
        } onTimeout: { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.clearPassiveDataEndpoint(endpoint)
                onTimeout()
            }
        }
        return true
    }

    private func clearPassiveDataEndpoint(_ endpoint: PassiveDataEndpoint) {
        guard passiveDataEndpoint === endpoint else { return }
        endpoint.cancel()
        passiveDataEndpoint = nil
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

    private func formatMachineListFacts(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let type = values?.isDirectory == true ? "dir" : "file"
        let size = values?.fileSize ?? 0
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        let modified = formatter.string(from: values?.contentModificationDate ?? Date())
        return "type=\(type);size=\(size);modify=\(modified);"
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

private final class PendingDataTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return false
        }
        cancelled = true
        lock.unlock()
        return true
    }
}

private final class ActiveDataTransfer: @unchecked Sendable {
    let connection: NWConnection
    private let permit: TransferPermit
    private let lock = NSLock()
    private var finished = false

    init(connection: NWConnection, permit: TransferPermit) {
        self.connection = connection
        self.permit = permit
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func finish() -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        lock.unlock()

        connection.cancel()
        permit.release()
        return true
    }
}

private final class TransferLimiter: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let queue = DispatchQueue(label: "local-ftp.transfer-limiter", attributes: .concurrent)

    init(maxConcurrent: Int) {
        semaphore = DispatchSemaphore(value: max(1, maxConcurrent))
    }

    func acquire(_ body: @escaping @Sendable (TransferPermit) -> Void) {
        queue.async {
            self.semaphore.wait()
            body(TransferPermit(semaphore: self.semaphore))
        }
    }
}

private final class TransferPermit: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var isReleased = false

    init(semaphore: DispatchSemaphore) {
        self.semaphore = semaphore
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        semaphore.signal()
    }

    deinit {
        release()
    }
}

private func localIPv4AddressForRoute(to remoteAddress: String) -> String? {
    let fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
    guard fileDescriptor >= 0 else {
        return nil
    }
    defer { close(fileDescriptor) }

    var remote = sockaddr_in()
    remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    remote.sin_family = sa_family_t(AF_INET)
    remote.sin_port = in_port_t(9).bigEndian
    guard inet_pton(AF_INET, remoteAddress, &remote.sin_addr) == 1 else {
        return nil
    }

    let connectResult = withUnsafePointer(to: &remote) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        return nil
    }

    var local = sockaddr_in()
    var localLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &local) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            getsockname(fileDescriptor, socketAddress, &localLength)
        }
    }
    guard nameResult == 0 else {
        return nil
    }

    var address = local.sin_addr
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
        return nil
    }
    return buffer.withUnsafeBufferPointer { pointer in
        String(cString: pointer.baseAddress!)
    }
}

private enum LocalIPv4AddressProvider {
    static func preferredAddress() -> String? {
        var addresses: [(name: String, host: String)] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let host = hostname.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            guard !host.hasPrefix("169.254.") else { continue }
            addresses.append((name: String(cString: interface.ifa_name), host: host))
        }

        return addresses.sorted { lhs, rhs in
            addressRank(lhs.name) == addressRank(rhs.name)
                ? lhs.host < rhs.host
                : addressRank(lhs.name) < addressRank(rhs.name)
        }.first?.host
    }

    private static func addressRank(_ interfaceName: String) -> Int {
        if interfaceName.hasPrefix("en") { return 0 }
        if interfaceName.hasPrefix("bridge") { return 1 }
        if interfaceName.hasPrefix("utun") || interfaceName.hasPrefix("ppp") { return 2 }
        return 3
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

    func acquire(
        _ handler: @escaping @Sendable (NWConnection) -> Void,
        onTimeout: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        if let connection = pendingConnection {
            pendingConnection = nil
            lock.unlock()
            handler(connection)
            return
        }
        pendingHandler = handler
        lock.unlock()

        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.pendingHandler != nil else {
                self.lock.unlock()
                return
            }
            self.pendingHandler = nil
            self.lock.unlock()
            onTimeout()
        }
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
