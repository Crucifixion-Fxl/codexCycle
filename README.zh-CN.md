# codexCycle

[English](README.md) | **简体中文**

`codexCycle` 是一款轻量的 macOS 状态栏应用，无需打开额外窗口，即可持续查看
Codex 周余量。它会自动刷新，并复用本机现有的 Codex 登录状态。

<p align="center">
  <img src="docs/images/codexcycle-status-item.png" width="100" alt="codexCycle 状态栏指示器，显示剩余 85">
</p>

## 显示内容

- 状态栏中心数字表示周余量百分比。为保证小尺寸下清晰，中心不显示 `%` 符号。
- 余量弧线使用固定的红 → 黄 → 绿渐变：`0` 为红色、`20` 为黄色、`50–100`
  为绿色。
- 点击指示器可查看周余量、重置倒计时、最后更新时间、手动刷新和语言选项。
- 首次启动默认使用英文，可即时切换为简体中文；应用会记住语言选择。

## 显示逻辑

- 只显示主 `codex` 计量桶中精确的 7 天窗口，其他窗口不会被替代使用。
- 剩余限额按 `floor(100 - usedPercent)` 计算，并限制在 `0...100`。
- 刷新失败时，有效缓存数字会继续显示，但余量环变为灰色。读数到达自身重置时间后
  立即失效；没有有效读数时显示 `—`。
- 重置时间使用相对倒计时，最多显示两个单位，不显示秒。
- 应用会在启动、每 5 分钟、Mac 唤醒、限额变化、周窗口重置和手动刷新时更新数据。

## 环境要求

- Apple Silicon Mac
- macOS 13 或更高版本
- 已安装并登录可用的 Codex Runtime：
  - 独立 Codex CLI；或
  - 当前 ChatGPT 桌面应用中的 Codex

## 安装

从 [GitHub Releases](https://github.com/Crucifixion-Fxl/codexCycle/releases/latest)
下载最新 arm64 DMG，打开后将 `codexCycle.app` 拖入 `Applications`。

公开构建目前使用 ad hoc 签名，尚未公证。首次启动时，macOS 可能要求在
**系统设置 → 隐私与安全性 → 仍要打开** 中确认。请仅安装本仓库发布的版本。

## 从源码构建

```sh
make test       # 运行测试
make install    # 构建、安装到 /Applications 并启动
```

其他命令：

```sh
make build      # Debug 构建
make release    # Release 构建
make dmg        # 生成 dist/codexCycle-<版本>-arm64.dmg
make uninstall  # 卸载应用，保留偏好设置
make purge      # 卸载应用并删除偏好设置
```

## 数据与隐私

`codexCycle` 通过本地 `codex app-server --stdio` 读取
`account/rateLimits/read`。应用不读取或保存凭据，不直接发起网络请求，不收集分析数据，
也不发送遥测；运行 Codex Runtime 前会验证可执行文件。

实现细节见[产品规格](docs/product-spec.md)、[Runtime 决策](docs/adr/0003-support-independent-and-desktop-codex-runtimes.md)
和[非沙盒决策](docs/adr/0002-run-outside-the-app-sandbox.md)。

## 排查

- **未找到 Codex Runtime：** 安装 Codex CLI，或安装并登录当前 ChatGPT 桌面应用。
- **Codex Runtime 不兼容：** 更新 Codex CLI 或 ChatGPT，然后选择**立即刷新**。
- **Codex 尚未登录：** 通过对应的 Codex 产品完成登录。
- **登录启动已禁用：** 从应用菜单打开“登录项”设置并允许 `codexCycle`。

只读诊断：

```sh
/Applications/codexCycle.app/Contents/MacOS/codexCycle --diagnose
```
