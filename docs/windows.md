# Windows 使用与构建

Windows 客户端位于 `desktop/`，采用 Electron，macOS 继续使用原有 SwiftUI 原生客户端。两者共用词典数据、图标、模型和长句分析提示词，分别保存本机数据。

## 安装与阅读

1. 从 [Releases](https://github.com/yizhiru/Yomitoki/releases) 下载 Windows x64 的 `setup.exe`，按向导安装。
2. 点击「导入」，选择 PDF、EPUB、MOBI 或 UTF-8 TXT。扫描 PDF 需先做 OCR；EPUB / MOBI 使用随软件内置的 Foliate 模块提取正文，不需要安装 calibre、Node.js 或 Python。
3. 默认关闭单击自动查词。手动选中单词后查询释义，选中完整句子后可本地翻译或长句分析，段落选区只提供本地翻译；所有有效选区均可打开大模型对话。使用 Ctrl+C 复制，Ctrl+Enter 发送对话问题。

查词使用随附离线词典；通过 kuromoji 的日语形态分析识别基本形，例如「微笑んだ」归一为「微笑む」。英文释义先于中文释义显示。单词及原句可保存、搜索和导出为 CSV / TXT。正文字号、释义字号、阅读位置、分栏宽度与对话记录自动保存。

## 内置电子书导入

支持 EPUB2/3、旧 MOBI、纯 KF8 及混合 MOBI；按阅读顺序提取文字，去掉可识别的 ruby 注音、脚本与隐藏内容。旧 MOBI 中若注音已变成普通文字，会保留原样，不凭猜测删字。阅读仍采用正文重排，不保留图片、竖排或完整原书版式。

导入在隔离后台进程中进行，可点击「取消导入」，超时或损坏会显示错误，不会写入不完整书架。仅字体混淆的 EPUB 可以提取未加密的正文；不支持 DRM 或加密正文。上限为输入文件 300 MB、ZIP 解压内容 128 MB、单条目 32 MB、最多 10000 个条目及 1000 万字符。较大书籍需先拆分。

原有通过 Calibre 导入的书籍、生词和原句位置保持原样，不自动重导入。同一本书重新导入后的页/节可能与旧版不同。macOS 原生客户端也已内置 Foliate，使用同一套固定版本解析模块。

## 模型设置

- 大模型释义、长句分析和对话共用「设置 → 大模型」中的服务商、URL、模型与 API key。支持 DeepSeek 或 OpenAI Chat Completions 兼容接口。API key 使用 Windows 系统加密保存，不写入导出文件。
- 本地翻译已内置固定版本 llama.cpp Vulkan GPU 与 CPU 引擎，无需 Homebrew、Python 或手动选择引擎。点击「下载 Q4 模型」从 HF 镜像或 ModelScope 下载约 1.13 GB 的 Hy-MT2 权重，也可选择已有 GGUF 文件。大小与 SHA-256 校验通过后启用。
- 本地翻译仅在主动点击时运行，不联网发送选文。本次重新发布的 0.1.0 可选择自动、GPU 或 CPU 模式，自动模式优先 GPU，失败时回退 CPU；具体使用与验证范围见 [GPU 加速说明](windows-gpu.md)。可在设置中释放模型内存。
- 释义、分析和翻译均有本机缓存，重新查询可跳过缓存。切换阅读位置或停止查询会取消旧请求，过期响应不覆盖当前结果。

## 数据

默认目录为 `%APPDATA%\Yomitoki`；`library.json` 保存书架、进度、生词、设置、缓存及对话，模型下载到 `models`。API key 是绑定当前 Windows 用户的加密数据，换机需重新配置。macOS 与 Windows 的数据目录和存储格式独立，目前不提供自动跨设备同步。

## 开发与测试

需要 Node.js 24、Python 3，以及联网下载固定资源；终端位于仓库的 `desktop` 目录：

```powershell
npm ci
npm run prepare:resources
npm test
npm run test:ui
npm start
npm run build:win
```

生成的安装包位于 `dist/windows/`。Python 仅用于构建词典与准备资源，终端用户无需安装。模型权重不会下载到构建目录或包含在安装包中。

GitHub Actions 的 [Windows build and tests](../.github/workflows/windows.yml) 在 Windows 环境运行核心测试、界面流程与安装包构建，再静默安装生成的程序，复测阅读、PDF / TXT / EPUB / MOBI 导入（含 25 个编码、路径、压缩与错误用例）、释义缓存、生词导出、长句分析、对话、设置保存及内置引擎启动。模型 API 使用本机模拟服务，测试不消耗真实 API 额度，也不评估真实翻译质量。

Electron 集成遵循[隔离与 IPC 原则](https://www.electronjs.org/docs/latest/tutorial/security)，系统凭据加密使用 [safeStorage](https://www.electronjs.org/docs/latest/api/safe-storage)。


内置 EPUB / MOBI 的安装包回归已在 [Windows 运行 42734174794](https://github.com/yizhiru/Yomitoki/actions/runs/42734174794) 通过，源码客户端与实际安装后的程序分别验证了 25 个电子书用例，以及导入后查词、生词保存、取消/超时和重启恢复。逐项证据见 [回归记录](windows-ebook-regression.json)。该记录对应先前的验证构建；正式安装包统一以重新发布的 v0.1.0 为准。
