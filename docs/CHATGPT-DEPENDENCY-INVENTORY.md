# DeepSeek Harness (on ChatGPT) Dependency Inventory

本文描述寄生桌面版在 Windows x64 上如何复用本机 Microsoft Store 的 ChatGPT/Codex 包，以及 DSH 自身仍需携带的依赖。

相关脚本：
- `build.ps1` — clone 官方源码并执行完整发布链路
- `scripts/build-official.ps1` — 官方源码完整构建 + 最小闭包
- `scripts/build-release.ps1` — 从已构建官方树生成 `dist/stage`
- `scripts/apply-cg-forks.ps1` — 从管理员终端调用 stage 控制器，补 npm junction + rg / node-pty 链接；脚本自身不请求 UAC
- `src/installer/*.cs` — 编译进主 EXE 的 controller；探测包、重建链接、同步 host、启动/停止业务进程
- 机器可读清单：`dist/stage/dsh-runtime/meta/release-manifest.json`

---

## 1. ChatGPT / Codex 包基线（本机实测样例）

| 字段 | 值 |
|------|-----|
| PackageFullName | `OpenAI.Codex_26.818.3698.0_x64__2p2nqsd0c76g0` |
| Version | `26.818.3698.0` |
| 安装根 | `%ProgramFiles%\\WindowsApps\\OpenAI.Codex_*` |
| 探测方式 | 读取当前用户 AppModel Repository，取最高 `OpenAI.Codex*` 版本并逐项验证运行接口 |

启动器**不写死版本号**；换包后自动重挂链接。上表是文档编写时的样例，也写入 manifest 的 `chatgptPackageExample`。

必须布局：

```
app/
  ChatGPT.exe
  chrome.dll
  resources/
    cua_node/bin/node.exe
    cua_node/bin/node_modules/    # npm 复用池
    rg.exe                          # ripgrep 资产 fork
    app.asar.unpacked/node_modules/node-pty/build/
```

---

## 2. 从 ChatGPT 复用的 npm 包（junction）

挂到 DSH 的 `node_modules`，**不打进安装包**。目标：`app/resources/cua_node/bin/node_modules`。

| DSH 路径 | fromCg | 样例版本 | 用途 |
|---------|--------|----------|------|
| `node_modules/@img (整 scope)` | `@img` | colour 1.1.0 / sharp-win32-x64 0.35.3 | sharp 原生 |
| `node_modules/@napi-rs/canvas` | `@napi-rs/canvas` | 0.1.91 | canvas |
| `node_modules/@napi-rs/canvas-win32-x64-msvc` | `@napi-rs/canvas-win32-x64-msvc` | 0.1.91 | canvas native |
| `node_modules/@oai (整 scope)` | `@oai` | sky 0.6.11 | Computer Use |
| `node_modules/@statsig (整 scope)` | `@statsig` | 3.33.3 | 遥测 |
| `node_modules/sharp` | `sharp` | 0.35.3 | 图片 |
| `node_modules/playwright` | `playwright` | 1.57.0 | 浏览器自动化 |
| `node_modules/playwright-core` | `playwright-core` | 1.57.0 | playwright 核心 |
| `node_modules/pdfjs-dist` | `pdfjs-dist` | 5.4.624 | PDF |
| `node_modules/tesseract.js` | `tesseract.js` | 7.0.0 | OCR |
| `node_modules/tesseract.js-core` | `tesseract.js-core` | 7.0.0 | OCR wasm |
| `node_modules/bmp-js` | `bmp-js` | 0.1.0 | 图像依赖 |
| `node_modules/jpeg-js` | `jpeg-js` | 0.4.4 | 图像依赖 |
| `node_modules/pngjs` | `pngjs` | 7.0.0 | 图像依赖 |
| `node_modules/pixelmatch` | `pixelmatch` | 7.1.0 | 图像 diff |
| `node_modules/semver` | `semver` | 7.8.5 | 版本比较 |
| `node_modules/detect-libc` | `detect-libc` | 2.1.2 | native 辅助 |
| `node_modules/node-fetch` | `node-fetch` | 2.7.0 | fetch |
| `node_modules/idb-keyval` | `idb-keyval` | 6.2.4 | KV |
| `node_modules/is-url` | `is-url` | 1.2.4 | URL |
| `node_modules/opencollective-postinstall` | `opencollective-postinstall` | 2.0.3 | 安装钩子残留 |
| `node_modules/node-readable-to-web-readable-stream` | `node-readable-to-web-readable-stream` | 0.4.2 | stream |
| `node_modules/regenerator-runtime` | `regenerator-runtime` | 0.13.11 | runtime 辅助 |
| `node_modules/tr46` | `tr46` | 0.0.3 | URL 依赖 |
| `node_modules/webidl-conversions` | `webidl-conversions` | 3.0.1 | URL 依赖 |
| `node_modules/whatwg-url` | `whatwg-url` | 5.0.0 | URL |
| `node_modules/zlibjs` | `zlibjs` | 0.3.1 | 压缩辅助 |
| `node_modules/wasm-feature-detect` | `wasm-feature-detect` | 1.8.0 | wasm 探测 |

完整列表以 `release-manifest.json` 的 `cgJunctions` 为准（当前 27 项，含整 scope 与单包）。

启动时：`Ensure-CgJunctionsFromManifest` → `Repair-CgJunctions`（含 `@scope/pkg` 嵌套 retarget）。

---

## 3. 从 ChatGPT 复用的非 npm 资产

| DSH 路径 | 包内路径 | 类型 | 说明 |
|---------|----------|------|------|
| `node_modules/@vscode/ripgrep-win32-x64/bin/rg.exe` | `app/resources/rg.exe` | symlink | `@vscode/ripgrep` 解析到此二进制 |
| `node_modules/node-pty/build` | `app/resources/app.asar.unpacked/node_modules/node-pty/build` | junction | Electron ABI native build；JS、package.json 与 CUA Node ABI prebuild 仍私有 |
| `parasite-runtime/owl-host/*`（除 `resources`） | `app/*` | symlink/junction + stub 复制 | `owl-stub.exe` 来自 `ChatGPT.exe`；`chrome_elf.dll` 复制 |
| Node 解释器 | `app/resources/cua_node/bin/node.exe` | 包身份进程 | `Invoke-CommandInDesktopPackage` |

链接策略：
- **目录 → Junction**（通常不需要管理员）
- **文件 → SymbolicLink only**（需要 UAC 或开发者模式；**无 hardlink/copy 回退**）
- stub / `chrome_elf` 仍 **Copy**（包执行保护 + 改名需要）
- owl-host 会清掉当前包里已不存在的孤儿本地目录（如旧版 `Dictionaries/`）

发布入口：产物根目录的 `DeepSeek Harness (on ChatGPT).exe`。`scripts/apply-cg-forks.ps1` 仅供构建机开发调试，不进入发布包。

---

## 4. DSH 自身需要补齐（打进安装包）

### 4.1 产品代码

| 路径 | 内容 |
|------|------|
| `apps/cli/lib` + `config` | CLI 入口与 profile |
| `apps/web/dist` | 已构建 Web UI（内含 shiki/katex/react 打包结果） |
| `packages/**`（lib 等） | host/client 运行库 |
| `vendor/**` | cordis 等 |
| `.dshhome` 种子 | settings + profiles/web |
| `parasite-runtime/` | 控制器 + Electron 覆盖层 `owl-host/resources` |

`node_modules/@deepseek-ai/*` 在 stage 内为 workspace junction，指回 `packages` / `vendor` / `apps`。

Windows 极简 preset 不再需要 packager overlay：官方 `0.1.1-rc.2` 起极简模式在 win32 使用官方持久 pwsh（`@deepseek-ai/dsh-tool-pwsh-persistent` + `@deepseek-ai/dsh-terminal-bash`，`shellDialect: pwsh`），Bash 行在 win32 禁用。pwsh 解析按 PowerShell 7 → PATH `pwsh.exe` → Windows 自带 PowerShell 5.1 回退，无需预装 pwsh 7。

PTY 分为两个 ABI 路径。运行在 ChatGPT CUA Node 下的官方持久 pwsh 使用随包私有 `node-pty\prebuilds\win32-x64\conpty.node` 与 `conpty_console_list.node`；Electron 内置终端使用从当前 ChatGPT `app.asar.unpacked` fork 的 `node-pty\build` junction，并设置 `useConptyDll: false` 以直接使用 Windows 系统 ConPTY，不复制私有 `conpty.dll`。Windows 进程表 inspection 由随包 `koffi`/`@koromix/koffi-win32-x64` 承担。

### 4.2 私有 npm（ChatGPT 池没有）

官方 `0.1.1-rc.2` 当前实测：**281** 个私有包，私有 `node_modules` 约 **24.99 MiB**（不含 junction 目标）。

机器可读完整名单：`release-manifest.json` → `privatePackages`。分类摘要：

#### PTY / native shell (8)

`@emnapi/runtime`, `@koromix/koffi-win32-x64`, `koffi`, `node-addon-api`, `node-addon-native-custom-loader`, `node-addon-require-builtin`, `node-addon-require-builtin-win32-x64-msvc`, `node-pty`

#### Search (ripgrep shell) (7)

`@vscode/ripgrep`, `@vscode/ripgrep-win32-x64`, `oniguruma-parser`, `oniguruma-to-es`, `regex`, `regex-recursion`, `regex-utilities`

#### HTTP / Web host (51)

`@hono/node-server`, `accepts`, `body-parser`, `bytes`, `content-disposition`, `content-type`, `cookie`, `cookie-signature`, `cors`, `depd`, `encodeurl`, `escape-html`, `etag`, `eventsource`, `eventsource-parser`, `express`, …(+35)

#### Schema / validation (8)

`@standard-schema/spec`, `ajv`, `ajv-formats`, `jose`, `json-schema-traverse`, `json-schema-typed`, `zod`, `zod-to-json-schema`

#### MCP (1)

`@modelcontextprotocol/sdk`

#### Markdown / AST pipeline (77)

`@joplin/turndown-plugin-gfm`, `@mixmark-io/domino`, `@types/hast`, `@types/mdast`, `@types/unist`, `anser`, `ccount`, `character-entities`, `character-entities-html4`, `character-entities-legacy`, `clsx`, `comma-separated-tokens`, `decode-named-character-reference`, `devlop`, `diff`, `escape-string-regexp`, …(+61)

#### Config / util (49)

`@babel/code-frame`, `@babel/helper-validator-identifier`, `@types/debug`, `@types/ms`, `@ungap/structured-clone`, `argparse`, `call-bind-apply-helpers`, `call-bound`, `chokidar`, `commander`, `cross-spawn`, `debug`, `dunder-proto`, `es-define-property`, `es-errors`, `es-object-atoms`, …(+33)

#### Other private (3)

`dequal`, `ee-first`, `ms`

体量靠前（私有文件，约）：`@mistralai/mistralai` 1.90MB、`zod` 1.58MB、`protobufjs` 1.15MB、`pi-ai` 1.09MB、Koffi native 1.00MB、`@smithy/core` 1.00MB、`@modelcontextprotocol/sdk` 0.99MB、`hono` 0.93MB、`@anthropic-ai/sdk` 0.83MB、`@google/genai` 0.83MB。

### 4.3 不打进 runtime node_modules 的浏览器依赖

仅 `packages/client/ui-primitives` 使用，已打入 `apps/web/dist`，由 `build-release.ps1` 的 browser-drop 删除：

- `shiki` 与全部 `@shikijs/*`（含 langs/themes）
- `katex`
- `react` / `react-dom` / `scheduler` / `csstype` / `@types/react*`
- `@tanstack/react-virtual` / `virtual-core`
- 相关：`loose-envify` / `js-tokens` / `use-sync-external-store`

**注意**：不要手工修改产物；全部剪枝规则写入 `scripts/build-release.ps1` 和 `config/release-blacklist.json`，每次从官方构建树重建。

---

## 5. 启动挂载顺序

1. 探测 `OpenAI.Codex*` 包（最高版本 + cua_node + chrome.dll）
2. `Ensure-CgJunctionsFromManifest`（npm junctions）
3. `Repair-CgJunctions`（修正旧 WindowsApps 路径，含 `@scope/*`）
4. 精简私有 `node-pty`：仅保留 `prebuilds\win32-x64` 下两枚 CUA Node ABI `.node` 文件，删除其他架构、PDB、随附 ConPTY DLL/OpenConsole、源码和构建输入；随后由 `Ensure-CgAssetForks` 挂载 rg 与 Electron `node-pty/build`
5. 同步 owl-host：版本标记 / stub 尺寸不匹配或存在孤儿本地项 → 全量 sync；否则 light repair
6. 包身份启动 node + owl-stub

---

## 6. 维护

1. 上游 DSH 升级：运行 `build.ps1 -Ref <ref>`，由脚本更新 `.work/deepseek-harness`。
2. ChatGPT 升级：一般无需重打业务包；启动自动换链接。若 `cua_node` 去掉某包，manifest 会 WARN。
3. 仅补链接：从管理员终端运行 `scripts/apply-cg-forks.ps1`。
4. 禁用资源管理器递归删除含 WindowsApps junction 的 `node_modules`。
5. 细节以 `release-manifest.json` 为准；本文是人类可读摘要。

---

## 7. 链接实现要点（实现层）

| 能力 | 实现 |
|------|------|
| npm 复用 | `cgJunctions[]` → Junction 到 `cua_node\\bin\\node_modules\\…` |
| 资产 fork | `cgAssetForks[]` → 文件 SymbolicLink / 目录 Junction |
| owl-host | 目录 Junction、文件 SymbolicLink；`owl-stub.exe`+`chrome_elf.dll` Copy |
| 权限 | 主 EXE 仅为 junction/symlink 创建请求 UAC，业务进程仍以普通用户启动；运行链不执行 PS1 |
| 版本漂移 | `.codex-package-full-name` + stub 尺寸；孤儿本地项强制 resync |
