# 本地 FTP macOS 应用 PRD

## 目标

把当前脚本式 FTP/SMB 项目重构为一个纯 Swift 的 macOS 应用。应用可以选择共享目录、配置端口、用户名和密码，启动/停止 FTP 服务，并实时显示服务日志。

## 当前问题

- `ftp.js` 依赖 `jsftpd`，但 `package.json` 没有声明该依赖，当前项目不可稳定运行。
- 用户名、密码、共享目录硬编码在脚本中，存在安全和可维护性问题。
- 没有测试、没有 README、没有设计文档、没有运行日志文件。
- `node_modules` 体积大，不符合“打包尽量小”的目标。
- 当前目录不是 Git 仓库，无法直接推送或发布 Release。

## 功能范围

- SwiftPM 项目，核心 FTP 服务逻辑与 macOS UI 分层。
- macOS SwiftUI 应用：
  - 选择共享目录。
  - 设置端口、用户名、密码。
  - 启动和关闭服务。
  - 实时显示结构化日志。
  - 日志同时写入文件，便于排查。
- FTP 服务：
  - 支持认证：`USER`、`PASS`。
  - 支持目录和文件命令：`PWD`、`CWD`、`CDUP`、`LIST`、`NLST`、`RETR`、`STOR`、`DELE`、`MKD`、`RMD`、`SIZE`、`MDTM`。
  - 支持传输/会话命令：`PASV`、`PORT`、`TYPE`、`SYST`、`FEAT`、`NOOP`、`QUIT`。
  - 将所有路径限制在共享根目录内，阻止 `..` 逃逸。

## 非目标

- 不实现 FTPS/TLS。
- 不实现多用户权限系统。
- 不依赖 Node.js、Python 或外部 FTP 服务进程。

## 分层设计

- `FTPServerCore`：纯 Swift library，包含协议解析、路径沙箱、日志、服务状态、socket FTP server。
- `LocalFTPApp`：SwiftUI/AppKit 可执行程序，只负责 UI、配置输入和调用核心服务。
- `scripts/package_app.sh`：构建 `.app` 包并输出压缩包。
- `local_docs/`：中文设计、实现、使用、数据流说明。

## 验收标准

- `swift test` 全部通过。
- 能通过 SwiftPM 构建 release 可执行文件。
- 能生成 `LocalFTP.app`。
- App 启动后可以配置目录/端口/用户/密码并启动/停止 FTP 服务。
- 日志能在 UI 中实时显示，并写入 `~/Library/Logs/LocalFTPServer/local-ftp.log`。
- README 和 `local_docs` 中文文档齐全，包含 Mermaid 图。
- GitHub 仓库已推送，Release 已发布，并包含构建产物。
- `LocalFTP.app` 已复制到 `/Applications`。

## 风险与缓解

- FTP 协议边界较多：先覆盖核心命令和路径安全测试，再实现网络层。
- macOS 没有完整 Xcode，仅有 Command Line Tools：使用 SwiftPM 和手工 `.app` bundle，避免依赖 Xcode project。
- 低端口需要管理员权限：默认端口使用 `2121`。
