# 本地 FTP macOS 应用测试规格

## TDD 顺序

1. RED：先写命令解析、路径沙箱、内存日志、FTP 会话集成测试。
2. GREEN：实现最小核心逻辑让测试通过。
3. REFACTOR：补齐分层、日志细节、文档、打包脚本。
4. VERIFY：运行 `swift test`、`swift build -c release`、打包脚本、GitHub 发布。

## 单元测试

- `FTPCommandParserTests`
  - 解析大小写混合命令。
  - 保留参数中的空格。
  - 拒绝空命令。
- `FTPPathResolverTests`
  - 将 FTP 绝对路径映射到共享根目录。
  - 将相对路径基于当前目录解析。
  - 阻止 `..` 逃逸共享根。
- `LogStoreTests`
  - 记录状态、命令、错误日志。
  - 限制内存日志数量。

## 集成测试

- `FTPServerIntegrationTests`
  - 启动临时端口服务。
  - 客户端完成 `USER/PASS/PWD/QUIT`。
  - 验证错误密码被拒绝。

## 验证命令

```bash
swift test
swift build -c release
./scripts/package_app.sh
```
