# codexCycle

`codexCycle` 是一个仅驻留在 macOS 状态栏的个人工具，用圆环和中心整数显示 Codex 主账户的周余量。它没有 Dock 图标、主窗口、通知、遥测或独立登录流程。

状态栏圆环每 5 分钟自动刷新，也会在启动、Mac 唤醒、Codex 限额变化和手动刷新时更新。点击圆环可查看周余量、相对重置倒计时和最后更新时间。

## 环境要求

- Apple Silicon Mac，macOS 13 或更高版本
- Xcode 26.3 或兼容的 Swift 6 工具链
- 已在本机安装并登录可用的 Codex Runtime：独立 Codex CLI 或当前 ChatGPT
  Desktop 中的 Codex

应用优先使用通过 `PATH`、常见包管理器位置和 Spotlight 找到的兼容独立
Codex CLI；没有兼容 CLI 时，改用当前 `ChatGPT.app` 内置的 Codex
Runtime，最后尽力尝试合并前的旧版 `Codex.app`。Desktop Runtime 只有在 App
Bundle ID、OpenAI Team ID 及 App/Runtime 两层代码签名均验证通过时才会执行。

应用通过所选 Runtime 的本地 `codex app-server --stdio` 读取
`account/rateLimits/read`，不读取或保存登录凭据，也不直接发起网络请求。

## 构建与安装

```sh
make test
make install
```

`make install` 会生成 arm64 Release 版本，以本地 ad hoc 签名安装到 `/Applications/codexCycle.app` 并启动。首次启动会尝试注册“登录时打开”；如果系统中已禁用，可从状态栏菜单打开“登录项”设置。

其他命令：

```sh
make build      # Debug 构建
make release    # Release 构建
make dmg        # 生成 dist/codexCycle-<版本>-arm64.dmg
make uninstall  # 卸载，保留偏好设置
make purge      # 卸载并删除偏好设置
make clean      # 删除仓库内构建产物
```

## 下载安装

从 GitHub Releases 下载 `codexCycle-<版本>-arm64.dmg`，打开后将
`codexCycle.app` 拖入 `Applications`。

当前公开构建使用 ad hoc 签名，尚未使用 Apple Developer ID 签名和公证。macOS
可能在首次启动时阻止应用；请在“系统设置 → 隐私与安全性”中确认应用来源后选择
“仍要打开”。不要使用来源不明的重新打包版本。

## 显示规则

- 只使用 `limitId = codex` 且 `windowDurationMins = 10080` 的周窗口。
- 周余量为 `floor(100 - usedPercent)`，限制在 `0...100`。
- 状态栏中心只显示整数；菜单中的周余量带 `%`。
- 重置时间只显示最多两个单位的相对倒计时，不显示绝对时间和秒。
- 旧缓存或刷新失败时保留数字并将圆环变灰；缓存跨过重置时间后立即作废。

完整行为约定见 [产品规格](docs/product-spec.md)，数据源与非沙盒决策见
[ADR 0003](docs/adr/0003-support-independent-and-desktop-codex-runtimes.md) 和
[ADR 0002](docs/adr/0002-run-outside-the-app-sandbox.md)。

## 排查

- 显示“未找到 Codex Runtime”：安装 Codex CLI，或安装并登录当前 ChatGPT
  Desktop。
- 显示“Codex Runtime 不兼容”：升级独立 Codex CLI 或 ChatGPT Desktop 后选择
  “立即刷新”。
- 显示“Codex 尚未登录”：通过对应的 Codex CLI 或 ChatGPT Desktop 完成登录；
  本应用不会打开终端或登录页面。
- 登录启动被禁用：从菜单打开“登录项”设置并允许 `codexCycle`。

也可以运行只读诊断，复用应用自身的扫描与读取链路：

```sh
/Applications/codexCycle.app/Contents/MacOS/codexCycle --diagnose
```

它只输出登录启动状态、选中的 Runtime 路径和版本、周余量与重置时间戳，不输出凭据或原始协议内容。

应用只向 macOS 统一日志写入不含凭据和完整协议数据的诊断信息。
