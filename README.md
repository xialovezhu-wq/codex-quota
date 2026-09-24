# Codex 余量悬浮窗

一个使用 Swift、AppKit 与 SwiftUI 编写的 macOS 悬浮窗，用于并排显示 Codex 与 Claude Code 的额度（5 小时额度和每周限额）、重置时间、今天（北京时间）已用的 token 数及其按 API 标价折算的人民币价值，并提供可暂停的眼睛微休息提醒。它通过本机 Codex App Server 与 Claude Code 已保存的登录读取数据，不抓屏、不自动点击，也不导出登录凭据。

## 结构与工作方式

- `Sources/CodexQuotaCore/`：额度解码、模型、RPC 支持与休息计时规则。
- `Sources/CodexQuotaApp/`：App Server 连接、悬浮面板、窗口位置、全局快捷键与休息提示。
- `Tests/`：核心逻辑、状态生命周期及假 App Server 测试。
- `Scripts/`：打包与测试入口；`Resources/` 为应用元数据和图标原稿。

连接器以标准输入输出启动本机 `codex app-server`，完成初始化后请求 `account/rateLimits/read`。事件通知负责及时更新，60 秒轮询作为兜底；失联时退避重连。应用保存规范化额度与窗口设置，不把账户凭据写入仓库。

Claude 部分（`ClaudeUsageProvider.swift`）每 5 分钟用 Claude Code 存在钥匙串 `Claude Code-credentials` 里的登录请求 `GET https://api.anthropic.com/api/oauth/usage`，即 Claude Code `/usage` 使用的同一接口。钥匙串只经由 `/usr/bin/security` 读写，与 Claude Code 自身方式相同。访问令牌过期时应用会用刷新令牌换新，并把轮换后的令牌写回同一钥匙串项，`claude` 命令行因此保持登录。若刷新令牌也已失效，卡片提示在终端运行 `claude auth login`。

今日用量（`TokenUsage.swift`、`ModelPricing.swift`、`TokenUsageMonitor.swift`）每 10 秒增量读取本机日志：Claude Code 的 `~/.claude/projects/**/*.jsonl`（含 Cowork 的 `local-agent-mode-sessions/**/.claude/projects`）与 Codex 的 `~/.codex/sessions`、`~/.codex/archived_sessions`。只打开当天修改过的文件，每个文件首次从头读，之后只读新增的完整行；按北京时间 0 点切换到新的一天。Claude 按「消息 id + 请求 id」去重（同一回复会按内容块重复写入），Codex 按 `token_usage_record` 的 `response_id` 去重，模型取自前面最近的 `turn_context`；没有该记录的旧日志退回用 `token_count` 的累计值。

金额按两家官网的 API 标价计算（2026-09-24 核对）：Claude 区分 5 分钟 / 1 小时缓存写入与各模型的缓存读取倍率（Opus 5.5 为 0.05×、Fable 5.1 为 0.025×），并计入快速模式、美国推理与网页搜索；OpenAI 区分缓存命中与写入，提示超过 272K token 时整次请求按长上下文价计。价格表里没有的模型只计 token、不计金额，界面上金额前显示「≥」。美元兑人民币汇率每 6 小时从 open.er-api.com 获取（失败时用 Frankfurter，均失败则沿用上次成功的值）。订阅用户实际不按这个价格付费，这只是「如果走 API 值多少钱」的参考；网页或 App 里的普通对话没有本地日志，不在统计范围内。鼠标在某张卡片上停留片刻，卡片会原地换成今日明细（请求次数、缓存命中、缓存未命中及其中写入缓存的部分、输出，以及命中率和美元金额 × 汇率；未命中 = 按原价计的输入 + 写入缓存的输入）；停在「今日合计」上则两张卡片一起显示，移开即恢复。悬浮窗不会成为活动窗口，所以这里用始终生效的鼠标跟踪区域，而不是系统提示气泡；锁定（点击穿透）时不响应悬停。

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
- 菜单栏图标：点击打开与右键菜单相同的全部设置，第一项就是锁定 / 解锁；浮窗锁定时图标变成一把锁。
- `Control + Option + R`：开始或暂停微休息会话。
- 窗口较大时显示 Codex / Claude 两张卡片：大数字为当前最紧的额度，下方列出其余窗口；缩小后变为两行紧凑模式。右键菜单可打开 Claude 网页用量页面。
- 会话运行约 20 分钟后提示远眺 20 秒，随后进入下一轮；声音与系统通知属于可见提醒。

提醒只能表明软件发出了提示，无法判断实际是否休息，也不能用于医疗判断。

## 验证与限制

```sh
swift run CodexQuotaTests
zsh Scripts/test-app-lifecycle.sh
./Scripts/test-fake-server.sh
```

前两项验证核心与状态控制逻辑（含 Claude 用量解码）；调试构建下设置 `CODEX_QUOTA_QA_RENDER=<目录>` 运行应用，可离线把各状态渲染成 PNG 检查界面，设置 `CODEX_QUOTA_QA_SCAN=1` 则打印本机今日用量的统计结果与耗时；假服务器脚本会启动调试 GUI，需要 macOS 图形环境。本次公开整理仅保留原测试，并进行源码/配置检查，未重新运行这些测试或验证真实账户连接。第三方应用内部接口变化可能影响可用性。

自有源码采用 MIT 许可证。
