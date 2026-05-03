# LocalFTPServer

LocalFTPServer 是一个纯 Swift 实现的 macOS 本地 FTP 服务应用。它提供图形界面，可以选择共享目录、配置端口、用户名和密码，并启动或关闭 FTP 服务。运行日志会实时显示在应用内，同时写入日志文件，方便排查连接、认证和文件传输问题。

## 功能

- 纯 Swift + SwiftUI + Network.framework，无 Node.js/Python 运行时依赖。
- 支持选择共享目录、设置端口、用户名和密码。
- 支持实时日志和日志文件输出。
- FTP 路径被限制在共享根目录内，阻止 `..` 逃逸。
- 支持常用 FTP 命令：
  - 认证：`USER`、`PASS`
  - 目录：`PWD`、`CWD`、`CDUP`、`LIST`、`NLST`
  - 文件：`RETR`、`STOR`、`DELE`、`SIZE`、`MDTM`
  - 目录修改：`MKD`、`RMD`
  - 传输：`PASV`、`PORT`、`TYPE`
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

- `dist/LocalFTP.app`
- `dist/LocalFTP.app.zip`

### 安装到 Applications

```bash
cp -R dist/LocalFTP.app /Applications/
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
