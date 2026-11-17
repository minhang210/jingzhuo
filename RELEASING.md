# 版本发布流程

每次用户确认版本范围后，完成以下步骤再交付。未通过的检查和未执行的实机验证应在 Release 说明中明确标注。

## 1. 统一源码和文档

1. 按已确认范围修改功能，保留用户已有的有效偏好设置。
2. 同步 `Resources/Info.plist` 的版本号和构建号，以及界面、关于窗口的版本信息。
3. 更新 `README.md`、`CHANGELOG.md` 和随包使用说明，使其与正式应用行为一致。
4. 检查提交范围：不包含密钥、用户偏好、诊断日志、测试应用、构建缓存和本机绝对路径。

## 2. 测试与构建

```sh
zsh test.sh
JINGZHUO_UNIVERSAL=1 zsh build.sh
codesign --verify --deep --strict 'dist/净桌.app'
lipo -archs 'dist/净桌.app/Contents/MacOS/CleanDesk'
plutil -lint 'dist/净桌.app/Contents/Info.plist'
```

记录本版实际测试结果，区分逻辑测试、集成测试和实机键盘验证。通用包应同时包含 `arm64`、`x86_64`；不得把 Intel 交叉编译成功写成 Intel 实机通过。

## 3. 制作下载包

- Mac 通用 ZIP：包含 `净桌.app` 和使用说明，解压后可直接使用。
- 源码 ZIP：包含本版源码、测试、构建脚本和文档。
- 源码 ZIP 排除 `.git/`、`.build/`、`dist/`、`.DS_Store` 和工作目录中的诊断产物。
- 解压复核应用签名、版本、双架构及二进制可执行权限，确认 ZIP 内容与待交付文件一致。
- 使用 `shasum -a 256` 计算两个 ZIP 的校验值，并提供 `SHA256SUMS.txt`。

## 4. 同步 GitHub

1. 提交经过验证的源码和文档，推送到 `main`。
2. 为相同提交创建对应版本标签，例如 `v0.7.0`，并推送标签。
3. 创建 GitHub Release，写明功能变化、安装步骤和本次实际验证范围。
4. 上传 Mac 通用 ZIP、源码 ZIP 和 `SHA256SUMS.txt`；不能只发布源码自动归档。
5. 复核 Release 关联的标签与提交正确，下载资产齐全，并核对下载文件的 SHA-256。
6. 确认 README 的最新版入口可到达正式 Release：
   `https://github.com/minhang210/jingzhuo/releases/latest`

本项目发布包使用临时签名，尚未进行 Apple Developer ID 公证。发布说明应保留这一实际状态，不能宣称已完成公证。
