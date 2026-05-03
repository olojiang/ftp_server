import AppKit
import FTPServerCore
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
    @Published var rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    @Published var portText: String = "2121"
    @Published var username: String = NSUserName()
    @Published var password: String = ""
    @Published var isRunning = false
    @Published var statusText = "未启动"
    @Published var logs: [LogEntry] = []

    let logStore = LogStore()
    private var server: FTPServer?
    private var refreshTask: Task<Void, Never>?

    init() {
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

        let configuration = FTPServerConfiguration(rootDirectory: rootDirectory, port: port, username: username, password: password)
        let server = FTPServer(configuration: configuration, logStore: logStore)
        self.server = server
        statusText = "启动中..."

        Task {
            do {
                try server.start()
                isRunning = true
                let boundPort = try server.boundPort()
                statusText = "运行中：127.0.0.1:\(boundPort)"
            } catch {
                isRunning = false
                self.server = nil
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
            statusText = "已停止"
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ServerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            configuration
            Divider()
            logPanel
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Local FTP Server")
                .font(.title2.weight(.semibold))
            Spacer()
            Text(viewModel.statusText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(viewModel.isRunning ? .green : .secondary)
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
                SecureField("密码", text: $viewModel.password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
        }
        .padding(16)
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("运行日志")
                .font(.headline)
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
