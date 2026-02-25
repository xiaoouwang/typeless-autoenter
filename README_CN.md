# Typeless AutoEnter

[![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos/)
[![Objective-C](https://img.shields.io/badge/language-Objective--C-blue)](https://developer.apple.com/documentation/objectivec)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**中文** | [English](README.md)

[Typeless](https://typeless.com) 语音输入结束后自动按 Enter，macOS 菜单栏常驻工具。

## 为什么做这个

Typeless 识别完语音后通过 `Cmd+V` 粘贴文字，但你还得手动按一下回车才能发送。这个工具检测到粘贴事件后等待 500ms，然后自动模拟一次 Enter，彻底解放双手。

## 工作原理

1. 每 30 秒扫描进程列表，按名称找到 Typeless
2. 通过 `CGEvent Tap` 监听系统级键盘事件
3. 按 PID 过滤，只响应来自 Typeless 的 `Cmd+V`
4. 等待 500ms（期间如果有新的 `Cmd+V` 则重置计时），然后模拟 Enter

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

首次启动需要授予**辅助功能**权限。如果缺少权限，程序会弹窗提示并显示二进制路径。

**授权步骤：**

1. 打开 **系统设置**
2. 进入 **隐私与安全性 → 辅助功能**
3. 点击 **+** 号（可能需要先解锁）
4. 找到 `TypelessAutoEnter.app` 并添加
5. 确保旁边的开关是**打开**的
6. 重新启动程序

只需授权一次。`.app` bundle 拥有稳定的 `CFBundleIdentifier`，即使重新编译，macOS 也能记住权限。

### 菜单栏

菜单栏会出现一个 `↩` 图标。点击打开菜单，可以切换开关。

- 开启时：图标正常显示
- 关闭时：图标变灰

### 全局快捷键

`Ctrl + Shift + Enter` 切换开关。屏幕中央会弹出毛玻璃 HUD 确认当前状态。

如需修改快捷键，编辑 `typeless-autoenter.m` 第 127-131 行，然后重新编译。修饰键对照：

| 代码 | 按键 |
|------|------|
| `kCGEventFlagMaskControl` | Ctrl |
| `kCGEventFlagMaskShift` | Shift |
| `kCGEventFlagMaskCommand` | Cmd |
| `kCGEventFlagMaskAlternate` | Option |

### 脚本切换

```bash
./toggle.sh
```

发送 `SIGUSR1` 信号切换开关。

## 自定义

自动按 Enter 的延迟默认为 **500ms**。如需修改，编辑 `typeless-autoenter.m` 第 27 行：

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
