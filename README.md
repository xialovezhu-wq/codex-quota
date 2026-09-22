# Codex 余量悬浮窗

一个使用 Swift、AppKit 与 SwiftUI 编写的 macOS 悬浮窗，用于只读显示 Codex 账户额度、重置时间，并提供可暂停的眼睛微休息提醒。它通过本机 Codex App Server 通信，不抓屏、不自动点击，也不导出登录凭据。

## 结构与工作方式

- `Sources/CodexQuotaCore/`：额度解码、模型、RPC 支持与休息计时规则。
- `Sources/CodexQuotaApp/`：App Server 连接、悬浮面板、窗口位置、全局快捷键与休息提示。
- `Tests/`：核心逻辑、状态生命周期及假 App Server 测试。
- `Scripts/`：打包与测试入口；`Resources/` 为应用元数据和图标原稿。

连接器以标准输入输出启动本机 `codex app-server`，完成初始化后请求 `account/rateLimits/read`。事件通知负责及时更新，60 秒轮询作为兜底；失联时退避重连。应用保存规范化额度与窗口设置，不把账户凭据写入仓库。

## 构建和运行

需要 macOS 13+、Swift 6 工具链以及能够提供 App Server 的本机 Codex/ChatGPT 安装，并先在自己的应用中完成登录。可执行文件发现逻辑位于 `CodexAppServerProvider.swift`，应用升级可能改变其位置或协议，需要按实际安装调整。

```sh
swift build
swift run CodexQuotaApp
./Scripts/package-app.sh ./dist
```

打包脚本输出 `.app`，使用本机可用签名身份或临时签名；仓库不包含编译好的应用、签名身份、缓存或账户资料。图标是项目资源，随源码保留。Bundle ID 仍为原项目标识；自行分发时可修改 `Resources/Info.plist`。

## 使用

- `Control + Option + Q`：锁定或解锁浮窗；锁定时鼠标点击穿透。
- `Control + Option + R`：开始或暂停微休息会话。
- 会话运行约 20 分钟后提示远眺 20 秒，随后进入下一轮；声音与系统通知属于可见提醒。

提醒只能表明软件发出了提示，无法判断实际是否休息，也不能用于医疗判断。

## 验证与限制

```sh
swift run CodexQuotaTests
zsh Scripts/test-app-lifecycle.sh
./Scripts/test-fake-server.sh
```

前两项验证核心与状态控制逻辑；假服务器脚本会启动调试 GUI，需要 macOS 图形环境。本次公开整理仅保留原测试，并进行源码/配置检查，未重新运行这些测试或验证真实账户连接。第三方应用内部接口变化可能影响可用性。

自有源码采用 MIT 许可证。
