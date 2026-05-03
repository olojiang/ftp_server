# FTP Server 纪

FTP Server 纪 是一个纯 Swift 实现的 macOS 本地 FTP 服务应用。它提供图形界面，可以选择共享目录、配置端口、用户名和密码，并启动或关闭 FTP 服务。运行日志会实时显示在应用内，同时写入日志文件，方便排查连接、认证和文件传输问题。

## 功能

- 纯 Swift + SwiftUI + Network.framework，无 Node.js/Python 运行时依赖。
- 支持选择共享目录、设置端口、用户名和密码。
- 默认支持 8 路并发上传/下载，可在界面中调整并发传输数。
- 启动后自动列出可分享的局域网/VPN FTP 地址，并支持一键复制单个地址或全部地址。
- 支持实时日志和日志文件输出。
- FTP 路径被限制在共享根目录内，阻止 `..` 逃逸。
- 支持常用 FTP 命令：
  - 认证：`USER`、`PASS`
  - 目录：`PWD`、`CWD`、`CDUP`、`LIST`、`NLST`、`MLSD`、`MLST`
  - 文件：`RETR`、`STOR`、`DELE`、`SIZE`、`MDTM`
  - 目录修改：`MKD`、`RMD`、`RNFR`、`RNTO`
  - 传输：`PASV`、`EPSV`、`PORT`、`TYPE`
  - 会话：`SYST`、`FEAT`、`NOOP`、`QUIT`

## 使用方法

### 运行测试

```bash
swift test
```

### 本地运行

```bash
swift run LocalFTP
```

### 打包 macOS App

```bash
./scripts/package_app.sh
```

打包结果：

- `dist/FTP Server 纪.app`
- `dist/FTP Server 纪.app.zip`

### 安装到 Applications

```bash
cp -R "dist/FTP Server 纪.app" /Applications/
```

### 连接示例

假设应用中配置：

- 共享目录：`~/Downloads`
- 端口：`2121`
- 用户名：`localuser`
- 密码：你在应用中输入的密码

可以用命令行连接：

```bash
ftp 127.0.0.1 2121
```

或使用支持 FTP 的客户端连接：

```text
ftp://127.0.0.1:2121
```

启动后，应用会在“可分享地址”中列出当前机器的非回环 IPv4 地址，例如：

```text
ftp://192.168.1.23:2121
ftp://10.8.0.5:2121
```

如果同时连接了 Wi-Fi、有线网络或 VPN，列表里可能出现多个地址。复制与对方处在同一局域网或同一 VPN 内的那个地址即可。

## 其他协议

当前内置服务实现的是 FTP。其他协议可以支持，但工程量和依赖边界不同：

- WebDAV：最适合下一步内置实现，基于 HTTP，可以继续用 Swift/Network 或系统 HTTP 能力实现。
- SFTP：不是 FTP 的加密版，而是 SSH 文件传输协议；需要引入 SSH 服务端实现或调用系统 `sshd`，安全边界更复杂。
- SMB3：通常应交给 macOS 系统“文件共享”服务处理；应用内自实现 SMB3 服务端复杂且维护成本高。

因此，短期建议是继续完善 FTP/EPSV 和增加 WebDAV；SFTP/SMB3 更适合做成“启动/配置系统服务”或引入专门服务端组件。

## 日志位置

应用内会实时显示日志，同时写入：

```text
~/Library/Logs/LocalFTPServer/local-ftp.log
```

日志包含服务状态、认证结果、客户端命令、服务端响应和传输字节数。密码命令会被脱敏为 `PASS ******`。

## 文档

详细中文文档在 `local_docs/`：

- `local_docs/架构设计.md`
- `local_docs/使用与排查.md`
- `local_docs/核心实现说明.md`
- `local_docs/核心数据流.md`

## 安全说明

FTP 是明文协议，不加密用户名、密码和文件内容。建议只在可信局域网或本机环境使用。需要公网或不可信网络传输时，应使用 SFTP/FTPS 或 VPN。
