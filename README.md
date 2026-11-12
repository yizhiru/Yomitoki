<img src="Resources/AppIcon.png" width="96" alt="读解应用图标">

# 读解 · Yomitoki

**日语深度阅读。** 从词义到句子结构，再到围绕原文的追问，帮助你读懂日语书籍。项目名来自「読み解き」。

[下载最新版本](https://github.com/yizhiru/Yomitoki/releases/latest) · [更新记录](CHANGELOG.md)

## 平台与安装

| 平台 | 0.1.0 安装包 | 要求 |
| --- | --- | --- |
| macOS | `Yomitoki-0.1.0-macos-arm64.zip` | Apple Silicon，macOS 14+ |
| Windows | `Yomitoki-0.1.0-windows-x64-setup.exe` | Windows 10 / 11，64 位 Intel / AMD |

macOS 解压后将「读解.app」拖入「应用程序」；Windows 运行安装向导。安装包包含离线词典和翻译引擎，**不包含模型权重**。校验文件随 Release 提供。

当前安装包尚未进行 Apple 公证或 Windows 代码签名，系统可能提示确认来源。首次打开前，请确认文件来自本仓库的 Releases。

## 能做什么

- **阅读文档**：导入 PDF、EPUB、MOBI；Windows 另支持 UTF-8 TXT。保存书架、阅读进度、字号和分栏宽度。
  EPUB 随阅读区大小自动分页，点击上一页或下一页阅读。
- **文档信息**：右键点击书架中的书，选择「文档信息」，即可查看或修改书名、作者、出版社和出版日期，也可查看正文总字数、文档格式和源文件名。阅读区顶部也有当前书籍的「文档信息」入口。
- **移出书架**：右键选择「移出书架」并确认。原文件、笔记和历史记录会保留，重新导入同一个文件可将它加回书架。
- **书内搜索**：在阅读区顶部搜索当前书籍的正文，可逐个跳转并高亮匹配位置。
- **单词释义**：离线英文与中文词义、词性、基本形归一；按需调用大模型补充语境释义与词源。
- **本地翻译**：选中日语句子或段落，使用 Hy-MT2-1.8B Q4 翻译成中文，原文留在本机。
- **长句分析**：拆解主干、修饰层级与语法难点，提供结构嵌套图。
- **选文对话**：结合所选文字及附近原文向大模型提问、继续追问，保存对话记录。
- **生词本**：按基本形收集词义和多条例句，搜索并导出 CSV / TXT。
- **笔记本**：阅读时点击顶部工具栏的「写笔记」。先选中文字再点击，可将原文附到笔记中。在侧栏的「笔记本」按书查看、编辑或删除笔记，也可跨书搜索笔记正文和引用。点击页码或节号返回原文。
- **历史记录**：在侧栏打开「历史记录」，按书查看已保存的长句分析和大模型对话。打开一条记录即可回到对应原文，查看分析或继续对话。

## 开始使用

1. **导入书籍**：PDF 需有文字层；Windows、macOS 版均内置 Foliate EPUB / MOBI 正文解析，无需额外安装 Calibre。两端都不支持 DRM 正文。
2. **选中文字**：单词显示两种释义，完整句子显示翻译与长句分析，段落显示翻译；有效选区均可打开对话。单击自动查词默认关闭，复制使用系统快捷键。
3. **配置模型（可选）**：在「设置」填写 DeepSeek 或 OpenAI 兼容接口和自己的 API key；本地翻译需手动下载或选择约 1.13 GB 的 Q4 模型，支持 HF 镜像与 ModelScope。
4. **导入词典（可选）**：在「设置 → 本地词典」导入 Yomitan v3 的 `.zip` 文件或 MDict 2.0 的 `.mdx` 文件，再用「释义词典」切换。释义、日文例句及已有中文译文按词条顺序以文本显示。

本次重新发布的 0.1.0 已包含内置电子书导入和 Windows GPU 加速，请以本次发布的安装包和校验文件为准。构建与回归说明见 [EPUB / MOBI 兼容性记录](docs/epub-mobi-compatibility.md)。

查词时，右侧会显示高亮目标词的原句，可从离线词典继续请求 AI 语境释义或追问。生词本保留原句，可以搜索例句并返回出处。

选择文字不会自动请求模型。AI 语境释义按原句缓存，同一单词在不同句子里会分别解释。分析和译文也会缓存。远程功能按你的 API 账户计费。本地翻译引擎已内置，macOS 使用 Metal，Windows 优先使用 Vulkan GPU，自动模式下失败回退 CPU。

Windows 提供「自动 / GPU / CPU」选项，使用方式与验证范围见 [Windows GPU 加速](docs/windows-gpu.md)。

详细说明：[macOS](docs/macos.md) · [Windows](docs/windows.md)。两端数据独立保存，暂不提供跨设备自动同步。

## 本地预览

- **macOS 原生版**：运行 `./scripts/dev.sh`。保存 Swift 文件后，脚本会重新编译，成功后自动重启预览 App。退出预览 App 或在终端按 Ctrl+C 可停止监听。脚本默认使用 `.build/dev/data` 保存开发书架，首次运行复用 `dist/读解.app` 中的资源，缺少时才运行完整构建。只编译可加 `--build-only`。
- **Electron 版**：运行 `npm --prefix desktop start`。首次使用需先在 `desktop` 下运行 `npm ci` 和 `npm run prepare:resources`。改动 HTML、CSS 或渲染端 JavaScript 后，可用 `⌘R`（macOS）或 `Ctrl+R`（Windows）刷新。改动主进程或 preload 后重启开发进程。

## 从源码构建

**macOS**：需要 Xcode / Command Line Tools（Swift、Python 3）。

```sh
./scripts/build.sh
./scripts/test.sh
open "dist/读解.app"
```

**Windows**：需要 Node.js 24 和 Python 3；终端用户安装已构建版本时无需这些工具。

```powershell
cd desktop
npm ci
npm run prepare:resources
npm test
npm run test:ui
npm run build:win
```

Windows 安装包输出到 `dist/windows/`。构建时校验固定版本的字典与 llama.cpp 引擎；模型权重不会随构建下载。Windows 安装与界面测试见 [GitHub Actions](.github/workflows/windows.yml)。

## 数据与署名

macOS 沿用 `~/Library/Application Support/Bunmyaku`，Windows 使用 `%APPDATA%\Yomitoki`，升级不会主动删除已有数据。API key 使用各系统的凭据存储或加密机制保存。

英文词典来自 [JMdict](https://www.edrdg.org/wiki/JMdict-EDICT_Dictionary_Project.html)，字典许可见 [Dictionary](Resources/Dictionary/SOURCES.txt)；翻译引擎来自 [llama.cpp](https://github.com/ggml-org/llama.cpp)，第三方许可随安装包提供。模型来源与许可见 [Hy-MT2](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF)。
