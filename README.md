# 净桌

轻量 macOS 菜单栏工具，当前版本 **0.7.0**。使用 Swift、AppKit 和 SwiftUI，无第三方依赖，目标系统为 macOS 13 或更新版本。

[下载最新版](https://github.com/minhang210/jingzhuo/releases/latest) · [更新记录](CHANGELOG.md)

## 功能

- 自定义全局快捷键，收起所有可操作窗口；再次按下恢复最近一次收起的窗口。
- 支持顺序收起和同时收起。
- 手动展开上一批中的任一窗口，或新打开普通应用窗口后，结束上一轮恢复状态；下次快捷键开始新一轮收起。
- 独立快捷键切换菜单栏、程序坞的系统自动隐藏，可分别选择；鼠标触边时仍可显示。
- 可设置登录时启动。净桌固定在菜单栏显示，不显示自己的程序坞图标。

默认窗口快捷键为 `Control + Option + Command + M`，系统栏快捷键为 `Control + Option + H`，均可在设置中修改。更新保留已有快捷键、收起模式和登录启动偏好。

## 安装

从 Releases 下载 Mac 通用 ZIP，退出旧版净桌，解压后将“净桌.app”放到固定位置打开。首次控制窗口需要在“系统设置 → 隐私与安全性 → 辅助功能”中授权净桌。更新签名后可能需要重新添加授权。

发布包包含 Apple Silicon（arm64）和 Intel（x86_64）架构，使用临时签名，未进行 Apple Developer ID 公证；Intel 版本未实机运行。切换系统栏设置时，系统可能请求允许控制 System Events。

## 收起与恢复规则

收起完成后，净桌只记录最近一批窗口。不设置固定过期时间；只要没有重新打开窗口，再按快捷键就恢复这一批。

手动展开其中任一窗口，或新打开普通应用窗口，会清除整批恢复记录，不改变其他窗口的当前状态。下次按快捷键重新收起。仅激活应用、切换焦点、点击菜单栏或打开净桌设置，不会清除记录。已经关闭的窗口、退出的应用会从记录中移除；查询失败不作为手动展开的证据。

后台检查窗口变化，每次执行快捷键前再次核对实际状态。只恢复这轮由净桌收起的窗口，不恢复原先就已最小化的窗口。

## ESC 功能状态

0.7.0 暂时隐藏并停用 ESC 关闭功能，正式应用不创建全局 ESC 监听，旧版开启偏好也不再启用它。ESC 由各应用自身处理。

`Sources/EscapeClose.swift` 保留用于后续兼容性开发，不作为本版可用功能。部分应用的内部页签、图片预览和自绘弹窗缺少统一的系统语义，当前不承诺通用关闭顺序。

## 构建与测试

安装 Xcode Command Line Tools 后，在源码目录运行：

```sh
# 执行逻辑回归测试
zsh test.sh

# 构建当前 Mac 架构
zsh build.sh

# 构建 Apple Silicon + Intel 通用版本
JINGZHUO_UNIVERSAL=1 zsh build.sh
```

构建结果默认为 `dist/净桌.app`。`build.sh` 可接收输出目录参数，`JINGZHUO_BUILD_DIR` 可指定构建缓存目录。测试输出中的断言数量与通过结果，以当前源码实际执行为准；每版实际验证范围记录在对应 Release 中。

## 0.7.0 验证范围

218 项逻辑断言通过，包含手动展开、新窗口、关闭或退出、查询失败、延迟恢复和关键状态未知时保留记录等回归检查；也包含保留但停用的 ESC 代码测试。

正式版已完成 Apple Silicon + Intel 通用构建、签名检查和界面检查。实机窗口操作因本次辅助功能重授权及界面自动化受限未完成，不能视为完整全局快捷键验收；Intel 未实机运行。辅助功能未提供普通窗口语义的 APP，其新开窗口检测存在兼容边界。

## 源码结构

| 路径 | 用途 |
| --- | --- |
| `Sources/WindowEngine.swift` | 窗口收起、最近批次恢复与状态检查 |
| `Sources/SystemBars.swift` | 菜单栏、程序坞自动隐藏 |
| `Sources/Shortcut.swift` | 快捷键注册与录入 |
| `Sources/SettingsView.swift` | 设置界面 |
| `Sources/AppModel.swift` | 状态、权限和偏好设置 |
| `Sources/main.swift` | 应用生命周期与菜单 |
| `Sources/EscapeClose.swift` | 保留的 ESC 实验实现，本版停用 |
| `Tests/main.swift` | 逻辑回归测试 |
| `Resources/Info.plist` | 应用信息 |
| `Scripts/MakeIcon.swift` | 应用图标生成 |

后续版本按 [发布流程](RELEASING.md) 同步源码、说明和可下载应用包。
