# Windows x64 最小闭包

## 目标

不修改 `.work/deepseek-harness` 中的官方已跟踪源码、`package.json` 或 lockfile，生成只包含 Windows x64 运行必需内容的 DeepSeek Harness (on ChatGPT)。官方仓库由根目录 `build.ps1` 在构建机器上 clone，不进入本仓库。保留 ACP 与 pi-ai；删除其他模型子代理、OTel、E2B、Typert generator、构建工具和测试栈。

## 自动流程

`scripts/build-official.ps1`：

1. 使用代理执行官方 `pnpm install`
2. 在系统临时目录准备构建所需的 `unrun` junction
3. 执行官方 `pnpm run build`
4. 执行生产依赖 hoist，供闭包收集
5. 调用 `scripts/build-release.ps1`
6. 自动清除临时 helper，不在 `release` 留日志或构建工具

`scripts/build-release.ps1`：

1. 收集官方已构建的 `apps`、`packages`、`vendor`、`native`
2. 根据 `config/release-blacklist.json` 删除禁用功能
3. 从本机 ChatGPT/Codex 记录可复用 npm junction 与原生资产 fork
4. 补齐 pnpm 中未 hoist 的运行依赖
5. 删除浏览器重复 npm、构建/DOM 测试依赖
6. 按 import 图删除不可达私有包
7. 删除私有包内声明、source map、`tsbuildinfo`、测试文件、文档和预编译 native 的构建源码
8. 保留 workspace package exports 与相对 imports，删除不可达的 `lib/types/*.js` 编译副本
9. 删除 Node ESM 下不会命中的 Google/OpenAI SDK 镜像 bundle
10. 自动 import Anthropic、Bedrock、Google、Mistral、OpenAI provider；失败则不产出成功 release

## 当前体积

官方 DSH `0.1.0-rc.7`、ChatGPT/Codex `26.814.5167.0` 本机实测：

| 项目 | 体积 |
|---|---:|
| 完整 release 本体 | 38.98 MB |
| `dsh-runtime` | 37.45 MB |
| 私有 `node_modules` | 24.49 MB |
| npm 文件级规则额外删除 | 5.92 MB |
| workspace 编译副本删除 | 7.37 MB |
| 私有 npm 包数 | 266 |

体积不含 junction 目标与首次运行生成的 `owl-ud-dsh`。机器可读数据见 `dist/stage/dsh-runtime/meta/release-manifest.json`。

## 命令

```powershell
# clone 官方源码 + 官方构建 + 最小闭包 + 安装器/便携包
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1

# 仅重新生成闭包
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 -Source .\.work\deepseek-harness -SkipZip
```

`dist` 只保存生成的 stage、安装器和便携包；构建脚本位于 `scripts`，官方 clone 位于 `.work`，临时 helper 位于系统临时目录。
