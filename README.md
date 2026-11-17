# 净桌

轻量 macOS 桌面工具，当前版本 **0.6.6**。使用 Swift、AppKit 和 SwiftUI，无第三方依赖，目标系统为 macOS 13 或更新版本。

## 功能

- 自定义全局快捷键，收起所有可操作窗口；再次按下恢复最近一次收起的窗口。
- 支持顺序收起和同时收起。
- 独立快捷键切换菜单栏、程序坞的系统自动隐藏，可分别选择；鼠标触边时仍可显示。
- 可设置登录时启动、是否显示净桌自己的程序坞图标。
- 可选 ESC 关闭当前窗口：优先处理最上层可识别浮层，不关闭应用内部页签、不退出应用进程，保存提示由原应用和用户处理。
- 全屏保护：识别到当前窗口或所属窗口全屏时，跳过 ESC 关闭；退出全屏后恢复普通窗口规则。

首次使用窗口控制时，需要在“系统设置 → 隐私与安全性 → 辅助功能”中授权净桌。ESC 功能默认关闭。切换系统栏设置时，系统可能请求允许控制 System Events。

默认窗口快捷键为 `Control + Option + Command + M`，系统栏快捷键为 `Control + Option + H`，均可在设置中修改。

## 构建与测试

安装 Xcode Command Line Tools 后，在源码目录运行：

```sh
# 执行逻辑测试
zsh test.sh

# 构建当前 Mac 架构
zsh build.sh

# 构建 Apple Silicon + Intel 通用版本
JINGZHUO_UNIVERSAL=1 zsh build.sh
```

构建结果默认为 `dist/净桌.app`。`build.sh` 可接收输出目录参数，`JINGZHUO_BUILD_DIR` 可指定构建缓存目录。生成的 APP 使用临时签名，未进行 Apple Developer ID 公证；更新签名后可能需要重新添加辅助功能授权。

## ESC 行为与边界

通过辅助功能接口查询当前窗口及顶层 sheet、dialog、popover 等语义浮层，只使用窗口关闭按钮、取消按钮或系统取消动作。顶层没有可用操作时，不继续关闭下面的父窗口；不搜索页签关闭按钮，不模拟 `Command + W`。

每次按键只选择一条处理路径。前置其他进程的可识别覆盖层保留原生 ESC，例如截图取消；系统 Dock 等辅助层会排除误判。普通窗口检查失败或超时会消费本次按键并提示未关闭，不回放 ESC，避免误触应用的页签关闭功能。

识别目标、重新核对目标和实际关闭前均检查全屏状态。全屏属性查询失败时不关闭；应用未提供该可选属性时保留原有规则。因此，不公开全屏状态或浮层语义的自绘界面仍存在兼容边界。

## 验证范围

0.6.6 包含 176 项逻辑断言，覆盖最近一批窗口恢复、收起模式、系统栏选择、单次 ESC 路由、保存提示、全屏保护等规则。

历史集成测试验证了空白原生窗口全屏时保留、全屏所属浮层保留，以及退出全屏后正常关闭。自动化测试未完成实体键盘的完整全局输入链路验收；也未逐一验证所有业务应用和自绘浮层。Intel 版本已交叉编译，未实机运行。

## 源码结构

| 路径 | 用途 |
| --- | --- |
| `Sources/EscapeClose.swift` | ESC 路由、顶层关闭与全屏保护 |
| `Sources/WindowEngine.swift` | 窗口收起与最近批次恢复 |
| `Sources/SystemBars.swift` | 菜单栏、程序坞自动隐藏 |
| `Sources/Shortcut.swift` | 快捷键注册与录入 |
| `Sources/SettingsView.swift` | 设置界面 |
| `Sources/AppModel.swift` | 状态、权限和偏好设置 |
| `Sources/main.swift` | 应用生命周期与菜单 |
| `Tests/main.swift` | 逻辑回归测试 |
| `Resources/Info.plist` | 应用信息 |
| `Scripts/MakeIcon.swift` | 应用图标生成 |
