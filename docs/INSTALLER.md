# DeepSeek Harness (on ChatGPT) Windows 发布说明

## 适用范围

- 仅支持 Windows x64。
- 按当前用户安装到 `%LOCALAPPDATA%\Programs\DeepSeek Harness (on ChatGPT)`。
- 复用 Microsoft Store 版 ChatGPT/Codex 的 Node、Electron 运行时和指定 `node_modules`。
- 不携带独立 Node 运行时，且绝不修改或终止 `ChatGPT.exe`。

## 构建

基于现有的官方 DeepSeek Harness 构建结果生成安装包：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-installer.ps1
```

官方源码更新后，执行从源码到安装包的完整链路：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

仅修改了安装器源码时，可使用 `-SkipReleaseBuild`。如果系统没有 Inno Setup 6，脚本会通过 `winget` 自动安装。最终产物输出到：

```text
dist\installer\DeepSeek-Harness-on-ChatGPT-Setup-<version>-win-x64.exe
dist\portable\DeepSeek-Harness-on-ChatGPT-Portable-<version>-win-x64.zip
```

## 安装流程

1. 安装器 EXE 启动时按 Windows 惯例请求管理员权限。
2. 释放 payload 前，在安装器进程内运行内置的预检（preflight）。
3. 查找当前用户已安装的最新 `OpenAI.Codex*` 包。
4. 验证 `node.exe`、`ChatGPT.exe`、`chrome.dll`、`Invoke-CommandInDesktopPackage`、全部 `cgJunctions` 模块和全部 `cgAssetForks` 目标。
5. 释放不含任何重解析点（reparse point）的静态 payload。
6. 安装 `DeepSeek Harness (on ChatGPT).exe` GUI 启动器，并在安装器已有的管理员 token 下完成全部链接和 asset fork；PowerShell 子进程不自行请求 UAC。
7. 注册 Windows“已安装的应用”、AppUserModelID、开始菜单快捷方式和可选的桌面快捷方式。

安装器和便携版 payload 会主动排除 `dist\stage` 中的全部 junction，防止打包工具沿链接进入 WindowsApps，或重复打包 workspace package 的目标文件。

## 绿色便携版

将完整 ZIP 解压到普通可写目录，然后运行 `DeepSeek Harness (on ChatGPT).exe`。绿色版不会注册 Windows“已安装的应用”、AppUserModelID 或快捷方式。每次启动时由 GUI 启动器 EXE 以自身名义请求 UAC，再创建或校验与安装版相同的 manifest 驱动链接；PowerShell 仅作为已提权启动器的隐藏子进程，不直接弹出权限请求。

应用停止后可以移动整个解压目录。下次启动时，控制器会按新路径检查 workspace 链接并自动修复。

## 启动修复

每次启动都会通过启动器 EXE 请求 UAC，并重新执行同一套 ChatGPT 能力验证和链接校验。包版本号只作为信息记录；兼容性取决于所需路径和 API 是否实际存在。

当前选中的包全名记录在 `parasite-runtime\owl-host\.codex-package-full-name`。ChatGPT 更新或包目录发生变化后，启动流程会重新复制 `owl-stub.exe` 和 `chrome_elf.dll`，重新指向 `owl-host` 链接，修复 manifest 中的全部 junction，然后启动 DSH。任何必要条件缺失都会产生错误并终止启动。

## 卸载

生成的 Inno 卸载器按 Windows 惯例注册到当前用户。Inno 删除应用文件前会：

- 停止 DSH Node、DSH `owl-stub.exe` 和辅助进程，不触碰 `ChatGPT.exe`。
- 删除 manifest 中的全部链接，然后扫描运行目录中是否仍有重解析点。
- 删除生成的 `owl-host`、浏览器 profile 和 `.dshhome` 状态。
- 删除应用文件、快捷方式、AppUserModelID 和卸载注册表项。
