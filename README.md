# codexCycle

`codexCycle` 是一个仅驻留在 macOS 状态栏的个人工具，用圆环和中心整数显示 Codex 主账户的周余量。它没有 Dock 图标、主窗口、通知、遥测或独立登录流程。

状态栏圆环每 5 分钟自动刷新，也会在启动、Mac 唤醒、Codex 限额变化和手动刷新时更新。点击圆环可查看周余量、相对重置倒计时和最后更新时间。

## 环境要求

- Apple Silicon Mac，macOS 13 或更高版本
- Xcode 26.3 或兼容的 Swift 6 工具链
- 已在本机安装并登录可用的 Codex CLI

应用会扫描 `PATH`、常见包管理器位置和 Spotlight，验证候选可执行文件后选择最新兼容版本。它通过本地 `codex app-server --stdio` 读取 `account/rateLimits/read`，不读取或保存登录凭据，也不直接发起网络请求。

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
make uninstall  # 卸载，保留偏好设置
make purge      # 卸载并删除偏好设置
make clean      # 删除仓库内构建产物
```

## 显示规则

- 只使用 `limitId = codex` 且 `windowDurationMins = 10080` 的周窗口。
- 周余量为 `floor(100 - usedPercent)`，限制在 `0...100`。
- 状态栏中心只显示整数；菜单中的周余量带 `%`。
- 重置时间只显示最多两个单位的相对倒计时，不显示绝对时间和秒。
- 旧缓存或刷新失败时保留数字并将圆环变灰；缓存跨过重置时间后立即作废。

完整行为约定见 [产品规格](docs/product-spec.md)，数据源与非沙盒决策见 [ADR 0001](docs/adr/0001-use-codex-app-server-for-rate-limits.md) 和 [ADR 0002](docs/adr/0002-run-outside-the-app-sandbox.md)。

## 排查

- 显示“未找到 Codex CLI”：确认终端中 `codex --version` 可运行。
- 显示“Codex CLI 不兼容”：升级 Codex CLI 后选择“立即刷新”。
- 显示“Codex 尚未登录”：在终端完成 Codex 登录；本应用不会打开登录页面。
- 登录启动被禁用：从菜单打开“登录项”设置并允许 `codexCycle`。

也可以运行只读诊断，复用应用自身的扫描与读取链路：

```sh
/Applications/codexCycle.app/Contents/MacOS/codexCycle --diagnose
```

它只输出登录启动状态、选中的 CLI 路径和版本、周余量与重置时间戳，不输出凭据或原始协议内容。

应用只向 macOS 统一日志写入不含凭据和完整协议数据的诊断信息。
