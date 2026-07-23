# Typeless AutoEnter

[![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos/)
[![Objective-C](https://img.shields.io/badge/language-Objective--C-blue)](https://developer.apple.com/documentation/objectivec)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**中文** | [English](README.md)

[Typeless](https://typeless.com) 或 [Wispr Flow](https://wisprflow.ai) 语音输入结束后自动按 Enter / Tab 的 macOS 菜单栏常驻工具。可在菜单中选择监听哪一个应用。

## 为什么做这个

Typeless、Wispr Flow 等语音输入工具识别完语音后通过 `Cmd+V` 粘贴文字，但很多流程还需要后续按键。这个工具检测到粘贴事件后等待 500ms，然后按当前开关自动模拟 Enter 和/或 Tab，彻底解放双手。

## Codex 场景支持

这次版本增加了面向 Codex 的 Tab 流程：

1. 在菜单栏中选择你使用的语音应用（`Typeless` 或 `Wispr Flow`）
2. 用 `Ctrl + Shift + Tab` 打开 `AutoTab`
3. 用所选应用说话输入
4. 粘贴文本后，工具会自动补发 `Tab`

在 Codex 这类把 `Tab` 作为“排队下一条命令”的界面里，新命令会排在当前执行任务后面。  
说明：队列语义由目标应用（Codex）提供，本工具负责在合适时机发送按键事件。

## 本次更新（2026-07）

### 功能新增

- 可监听 **Typeless** 或 **Wispr Flow**：在菜单栏「监听应用」中二选一，选择会跨启动持久保存

## 本次更新（2026-03）

### 功能新增

- `AutoEnter` 与 `AutoTab` 改为独立开关，可同时开启
- 新增全局快捷键 `Ctrl + Shift + \``：仅显示状态快照，不改变开关状态
- 内置中英文 UI 切换（默认中文，菜单可切英文）
- 支持启动参数/环境变量切换语言：`--lang`、`--ui-lang`、`TYPELESS_UI_LANG`
- 权限引导升级：权限不足时自动跳转辅助功能设置页

### Bug 修复

- 修复误触发 `Cmd+Tab`：发送模拟按键前清空修饰键 flags
- 修复状态快照高亮逻辑：Enter / Tab 亮暗完全独立
- 修复 HUD 图标偏左问题：单图标和双状态图标均恢复居中
- 状态栏 Tab 图标改为单符号 `⇥`，跨机器显示更稳定
- 微调状态栏 Enter/Tab 间距与基线对齐

## 工作原理

1. 每 30 秒扫描进程列表，按名称找到当前监听目标（`Typeless` 或 `Wispr Flow`）
2. 通过 `CGEvent Tap` 监听系统级键盘事件
3. 按 PID 过滤，只响应来自该应用的 `Cmd+V`
4. 等待 500ms（期间如果有新的 `Cmd+V` 则重置计时），然后按当前已开启的动作模拟 Enter 和/或 Tab

## 编译

```bash
chmod +x build.sh
./build.sh
```

需要 Xcode Command Line Tools（`xcode-select --install`）。

编译脚本会自动将程序打包为 `TypelessAutoEnter.app` bundle 并签名。`.app` bundle 能让 macOS 在重启后可靠地记住辅助功能权限。

## 使用

```bash
open TypelessAutoEnter.app
# 或直接运行二进制：
TypelessAutoEnter.app/Contents/MacOS/typeless-autoenter
```

### UI 文案（中文 / English）

默认 UI 文案是**中文**。

切换成英文 UI：

1. 打开菜单栏应用菜单
2. 点击 `界面语言：中文`
3. 菜单会变成 `UI Language: English`，界面文案随即切换为英文

切回中文 UI：

- 点击 `UI Language: English`

启动时直接用英文 UI（无需手动点菜单）：

```bash
# 方式 1：启动参数
TypelessAutoEnter.app/Contents/MacOS/typeless-autoenter --lang en

# 方式 2：环境变量
TYPELESS_UI_LANG=en open TypelessAutoEnter.app
```

支持值：`en`、`english`、`zh`、`cn`、`zh-cn`、`chinese`。

首次启动需要授予**辅助功能**权限。如果缺少权限，程序会先尝试自动打开“辅助功能”设置页，再弹窗提示并显示二进制路径。

**授权步骤：**

1. 打开 **系统设置**
2. 进入 **隐私与安全性 → 辅助功能**
3. 点击 **+** 号（可能需要先解锁）
4. 找到 `TypelessAutoEnter.app` 并添加
5. 确保旁边的开关是**打开**的
6. 重新启动程序

只需授权一次。`.app` bundle 拥有稳定的 `CFBundleIdentifier`，即使重新编译，macOS 也能记住权限。

### 系统提示与界面优化

- 增加了更清晰的功能提示（切换提示 + 状态快照提示）
- 权限不足时自动跳转“辅助功能”设置页
- 权限弹窗新增“授权后重新打开 App”的明确提示
- HUD 布局优化，双状态文本显示更稳定，仍保持毛玻璃风格
- 状态快照支持 Enter/Tab 独立高亮：开启亮、关闭暗
- 菜单栏改为符号化 Tab（`⇥`）并优化与 Enter 的间距/对齐

### 菜单栏

菜单栏会显示 `↩`、`⇥` 或 `↩  ⇥` 图标。点击打开菜单：

- 分别切换 AutoEnter / AutoTab
- 在 **监听应用** 下选择 **Typeless** 或 **Wispr Flow**（互斥，同一时间只监听一个）。选择会保存，下次启动自动恢复。

- 开启时：图标正常显示
- 关闭时：图标变灰

### 全局快捷键

`Ctrl + Shift + Enter` 切换 AutoEnter。  
`Ctrl + Shift + Tab` 切换 AutoTab。  
`Ctrl + Shift + \`` 仅显示当前 Enter/Tab 状态（不切换开关）。  
每次切换和状态查看都会在屏幕中央弹出毛玻璃 HUD。

`Ctrl + Shift + \`` 使用物理键位 `kVK_ANSI_Grave` 匹配，所以不受中英文输入法切换影响。

### 快捷键管理（禁用 / 修改）

编辑 `typeless-autoenter.m` 后重新执行 `./build.sh`。

禁用单个快捷键：

- 在 `event_callback` 里找到对应分支并注释掉
- 对应关系：`kVK_Return`（AutoEnter）、`kVK_Tab`（AutoTab）、`kVK_ANSI_Grave`（状态快照）

修改快捷键：

- 保留 `Ctrl + Shift` 修饰键判断
- 把对应分支里的键常量替换成你希望的新键值

禁用全部全局快捷键：

- 注释掉 `event_callback` 里整段“快捷键处理”逻辑
- 菜单栏点击开关仍然可用

常用常量：

| 代码 | 按键 |
|------|------|
| `kCGEventFlagMaskControl` | Ctrl |
| `kCGEventFlagMaskShift` | Shift |
| `kCGEventFlagMaskCommand` | Cmd |
| `kCGEventFlagMaskAlternate` | Option |
| `kVK_Return` | Enter |
| `kVK_Tab` | Tab |
| `kVK_ANSI_Grave` | `（反引号/波浪线键位） |

### 脚本切换

```bash
./toggle.sh
```

发送 `SIGUSR1` 信号切换开关。

## 自定义

自动按键延迟默认为 **500ms**。如需修改，编辑 `typeless-autoenter.m` 中的 `DELAY_SEC`：

```c
static const CFTimeInterval DELAY_SEC = 0.5;  // 改成你想要的延迟秒数
```

然后重新编译 `./build.sh`。

## 开机自启（launchd）

1. 编辑 `com.user.typeless-autoenter.plist`，把路径替换成你的 `.app` bundle 内二进制的实际路径：
   ```
   /path/to/TypelessAutoEnter.app/Contents/MacOS/typeless-autoenter
   ```
2. 复制到 LaunchAgents 并加载：

```bash
cp com.user.typeless-autoenter.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.typeless-autoenter.plist
```

## License

本项目基于 [MIT License](LICENSE) 开源。
