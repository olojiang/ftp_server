import AppKit
import Darwin
import FTPServerCore
import Security
import SwiftUI

@main
struct LocalFTPApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 780, minHeight: 560)
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class ServerViewModel: ObservableObject {
    @Published var rootDirectory: URL {
        didSet { saveSettingsIfReady() }
    }
    @Published var portText: String {
        didSet { saveSettingsIfReady() }
    }
    @Published var username: String {
        didSet { saveSettingsIfReady() }
    }
    @Published var password: String {
        didSet { savePasswordIfReady() }
    }
    @Published var maxConcurrentTransfersText: String {
        didSet { saveSettingsIfReady() }
    }
    @Published var isRunning = false
    @Published var statusText = "未启动"
    @Published var shareAddresses: [ShareAddress] = []
    @Published var logs: [LogEntry] = []

    let logStore = LogStore()
    private let settingsStore: AppSettingsStore
    private var isLoadingSettings = true
    private var server: FTPServer?
    private var refreshTask: Task<Void, Never>?

    init(settingsStore: AppSettingsStore = .shared) {
        self.settingsStore = settingsStore
        rootDirectory = settingsStore.rootDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        portText = settingsStore.portText ?? "2121"
        username = settingsStore.username ?? NSUserName()
        password = settingsStore.password ?? ""
        maxConcurrentTransfersText = settingsStore.maxConcurrentTransfersText ?? "\(FTPServerConfiguration.defaultMaxConcurrentTransfers)"
        isLoadingSettings = false

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let entries = await logStore.entries
                self.logs = entries
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootDirectory
        if panel.runModal() == .OK, let url = panel.url {
            rootDirectory = url
        }
    }

    func start() {
        guard !isRunning else { return }
        guard let port = UInt16(portText), port > 0 else {
            Task { await logStore.append(level: .error, category: .state, message: "端口无效：\(portText)") }
            statusText = "端口无效"
            return
        }
        guard !username.isEmpty, !password.isEmpty else {
            Task { await logStore.append(level: .error, category: .auth, message: "用户名和密码不能为空") }
            statusText = "认证信息不完整"
            return
        }
        guard let maxConcurrentTransfers = Int(maxConcurrentTransfersText), maxConcurrentTransfers > 0 else {
            Task { await logStore.append(level: .error, category: .state, message: "并发传输数无效：\(maxConcurrentTransfersText)") }
            statusText = "并发数无效"
            return
        }

        let configuration = FTPServerConfiguration(
            rootDirectory: rootDirectory,
            port: port,
            username: username,
            password: password,
            maxConcurrentTransfers: maxConcurrentTransfers
        )
        let server = FTPServer(configuration: configuration, logStore: logStore)
        self.server = server
        statusText = "启动中..."

        Task {
            do {
                try server.start()
                isRunning = true
                let boundPort = try server.boundPort()
                refreshShareAddresses(port: boundPort)
                statusText = shareAddresses.isEmpty ? "运行中：端口 \(boundPort)" : "运行中：\(shareAddresses.count) 个地址"
            } catch {
                isRunning = false
                self.server = nil
                shareAddresses = []
                statusText = "启动失败"
                await logStore.append(level: .error, category: .state, message: "启动失败：\(error)")
            }
        }
    }

    func stop() {
        guard let server else { return }
        Task {
            server.stop()
            self.server = nil
            isRunning = false
            shareAddresses = []
            statusText = "已停止"
        }
    }

    func copyAddress(_ address: ShareAddress) {
        copyToPasteboard(address.url)
    }

    func copyAllAddresses() {
        copyToPasteboard(shareAddresses.map(\.url).joined(separator: "\n"))
    }

    func copyPassword() {
        copyToPasteboard(password)
    }

    func copyFullLog() {
        Task {
            let contents = await logStore.copyableContents()
            copyToPasteboard(contents)
        }
    }

    private func refreshShareAddresses(port: UInt16) {
        shareAddresses = LocalAddressProvider.shareAddresses(port: port)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func saveSettingsIfReady() {
        guard !isLoadingSettings else { return }
        settingsStore.rootDirectory = rootDirectory
        settingsStore.portText = portText
        settingsStore.username = username
        settingsStore.maxConcurrentTransfersText = maxConcurrentTransfersText
    }

    private func savePasswordIfReady() {
        guard !isLoadingSettings else { return }
        settingsStore.password = password
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ServerViewModel()
    @State private var isShowingAllAddresses = false
    @State private var isShowingPassword = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            configuration
            Divider()
            logPanel
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: viewModel.shareAddresses) { addresses in
            if addresses.count <= 1 {
                isShowingAllAddresses = false
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Local FTP Server")
                .font(.title2.weight(.semibold))
            Spacer()
            Text(viewModel.statusText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(viewModel.isRunning ? .green : .secondary)
            if viewModel.isRunning, !viewModel.shareAddresses.isEmpty {
                Button("复制地址") {
                    viewModel.copyAllAddresses()
                }
            }
            Button(viewModel.isRunning ? "关闭" : "启动") {
                viewModel.isRunning ? viewModel.stop() : viewModel.start()
            }
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(16)
    }

    private var configuration: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("共享目录")
                HStack {
                    Text(viewModel.rootDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择目录") {
                        viewModel.chooseDirectory()
                    }
                }
            }
            GridRow {
                Text("端口")
                TextField("2121", text: $viewModel.portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            GridRow {
                Text("用户名")
                TextField("用户名", text: $viewModel.username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            GridRow {
                Text("密码")
                HStack(spacing: 8) {
                    if isShowingPassword {
                        TextField("密码", text: $viewModel.password)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    } else {
                        SecureField("密码", text: $viewModel.password)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }
                    Button(isShowingPassword ? "隐藏" : "查看") {
                        isShowingPassword.toggle()
                    }
                    Button("复制") {
                        viewModel.copyPassword()
                    }
                    .disabled(viewModel.password.isEmpty)
                }
            }
            GridRow {
                Text("并发传输")
                TextField("\(FTPServerConfiguration.defaultMaxConcurrentTransfers)", text: $viewModel.maxConcurrentTransfersText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .disabled(viewModel.isRunning)
            }
            GridRow(alignment: .top) {
                Text("可分享地址")
                shareAddressPanel
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var shareAddressPanel: some View {
        if viewModel.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                let visibleAddresses = isShowingAllAddresses ? viewModel.shareAddresses : Array(viewModel.shareAddresses.prefix(1))
                ForEach(visibleAddresses) { address in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(address.url)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                            Text(address.interfaceName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("复制") {
                            viewModel.copyAddress(address)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if viewModel.shareAddresses.count > 1 {
                    HStack(spacing: 8) {
                        Button(isShowingAllAddresses ? "收起" : "展开 \(viewModel.shareAddresses.count - 1) 个") {
                            isShowingAllAddresses.toggle()
                        }
                        Button("复制全部") {
                            viewModel.copyAllAddresses()
                        }
                    }
                }
                Text(isShowingAllAddresses ? "把同一局域网或 VPN 中可达的地址发给对方。" : "默认显示首选地址；有 VPN 或多网卡时可展开查看全部。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("启动后显示")
                .foregroundStyle(.secondary)
        }
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("运行日志")
                    .font(.headline)
                Spacer()
                Button("复制完整日志") {
                    viewModel.copyFullLog()
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.logs) { entry in
                            Text(entry.formatted)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(entry.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: viewModel.logs.count) { _ in
                    if let last = viewModel.logs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }
}

@MainActor
struct AppSettingsStore {
    static let shared = AppSettingsStore()

    private let defaults = UserDefaults.standard
    private let rootDirectoryKey = "rootDirectory"
    private let portTextKey = "portText"
    private let usernameKey = "username"
    private let maxConcurrentTransfersTextKey = "maxConcurrentTransfersText"
    private let keychainService = "dev.local.localftpserver"
    private let keychainAccount = "ftp-password"

    var rootDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: rootDirectoryKey), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
        nonmutating set {
            defaults.set(newValue?.path, forKey: rootDirectoryKey)
        }
    }

    var portText: String? {
        get { defaults.string(forKey: portTextKey) }
        nonmutating set { defaults.set(newValue, forKey: portTextKey) }
    }

    var username: String? {
        get { defaults.string(forKey: usernameKey) }
        nonmutating set { defaults.set(newValue, forKey: usernameKey) }
    }

    var maxConcurrentTransfersText: String? {
        get { defaults.string(forKey: maxConcurrentTransfersTextKey) }
        nonmutating set { defaults.set(newValue, forKey: maxConcurrentTransfersTextKey) }
    }

    var password: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        nonmutating set {
            let baseQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount
            ]

            guard let newValue, !newValue.isEmpty else {
                SecItemDelete(baseQuery as CFDictionary)
                return
            }

            let data = Data(newValue.utf8)
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updateStatus == errSecItemNotFound {
                var addQuery = baseQuery
                addQuery[kSecValueData as String] = data
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(addQuery as CFDictionary, nil)
            }
        }
    }
}

struct ShareAddress: Identifiable, Equatable {
    var id: String { "\(interfaceName)-\(host)" }
    let interfaceName: String
    let host: String
    let port: UInt16

    var url: String {
        "ftp://\(host):\(port)"
    }
}

enum LocalAddressProvider {
    static func shareAddresses(port: UInt16) -> [ShareAddress] {
        var addresses: [ShareAddress] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return [ShareAddress(interfaceName: "本机", host: "127.0.0.1", port: port)]
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
            addresses.append(ShareAddress(interfaceName: String(cString: interface.ifa_name), host: host, port: port))
        }

        let uniqueAddresses = Dictionary(grouping: addresses, by: \.host)
            .compactMap { $0.value.first }
            .sorted { lhs, rhs in
                addressRank(lhs.interfaceName) == addressRank(rhs.interfaceName)
                    ? lhs.host < rhs.host
                    : addressRank(lhs.interfaceName) < addressRank(rhs.interfaceName)
            }

        return uniqueAddresses.isEmpty
            ? [ShareAddress(interfaceName: "本机", host: "127.0.0.1", port: port)]
            : uniqueAddresses
    }

    private static func addressRank(_ interfaceName: String) -> Int {
        if interfaceName.hasPrefix("en") { return 0 }
        if interfaceName.hasPrefix("bridge") { return 1 }
        if interfaceName.hasPrefix("utun") || interfaceName.hasPrefix("ppp") { return 2 }
        return 3
    }
}
