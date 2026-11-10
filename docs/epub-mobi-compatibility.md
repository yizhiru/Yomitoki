# 内置 EPUB / MOBI 导入：兼容性评估

验证日期：2026-11-09。针对本项目的正文重排阅读，选择 **Foliate 固定版本 + 自有加载及正文提取适配层** 作为后续内置方案，不直接采用最初候选的 Lingo 库。

此报告记录 2026-11-09 的隔离选型验证。2026-11-10 已按本结论接入 Windows/Electron 和 macOS 原生客户端的内置导入；两端回归结果见报告末尾。正式安装包统一以重新发布的 v0.1.0 为准。

## 环境与范围

- 主机为 macOS arm64，Node 26.8.1；另用应用的 Electron 45.2.3、内置 Node 24.22.2 交叉验证。
- Calibre 9.3.1 使用当前 `imports.cjs` 相同的 `plain`、UTF-8、无行宽上限与 Unix 换行参数。
- Lingo EPUB / MOBI 解析器均为 0.4.6，以 ESM 加载，配合 HTML 正文清理。
- Foliate 固定提交 `78914aef4466eb960965702401634c2cb348e9b1`；在无 Node 集成的隔离渲染进程内，只调用解析和 `createDocument()`，不替换阅读界面。
- [逐项数据与文件校验和](../desktop/compat-evaluation/recorded-results.json)；[复现工具](../desktop/compat-evaluation/README.md)。

共 27 个文件：24 个正常输入、3 个应拒绝的负例。正常输入中有 15 个已知正文质量用例、7 个来自两个独立项目的公开样本文件，以及 2 个旧 MOBI6 注音诊断用例。公开文件包含同一作品的不同版本，不能视作 7 部独立作品。

覆盖 EPUB2/3、与文件名顺序不同的 spine、百分号编码及中文/空格路径、外层日文文件名、非 BMP 汉字、实体、重音符号、ruby 注音、隐藏元素、脚本/样式、30 章文本；MOBI 覆盖旧版、纯 KF8、混合版、UTF-8 / Windows-1252、未压缩 / PalmDOC / HUFF-CDIC。

Windows-1252 EPUB 是刻意构造的遗留编码容错用例，此报告不是 EPUB 标准合规认证。HUFF/CDIC 两例均能被 Calibre 解码为已知正文，但只是固定码字典的字面、递归短语，不代表所有真实压缩字典。

## 结果

| 指标 | 当前 Calibre 导入 | Lingo + 适配层 | Foliate + 适配层 |
| --- | ---: | ---: | ---: |
| 正常文件有非空正文 | 24 / 24 | 23 / 24 | 24 / 24 |
| 已知正文质量用例通过 | 10 / 15 | 12 / 15 | 15 / 15 |
| 公开样本片段存在且顺序正确 | 280 / 280 | 280 / 280 | 280 / 280 |
| 应拒绝输入被拒绝 | 3 / 3 | 3 / 3 | 3 / 3 |

质量差异不等于无法打开文件：Calibre 的 5 个质量差异是 4 个注音混入正文，以及一个 `hidden` 元素进入正文。280 个公开片段是抽查，不能证明全书逐字一致。

### 关键发现

1. **注音**：有 ruby 结构的 EPUB、KF8 和混合文件，可保留正文并单独去掉 `rt/rp`。当前 Calibre 转 TXT 会把部分假名和括号混进汉字之间。这个改善依赖正文适配逻辑，不能归功于解析库开箱即用。
2. **Lingo 路径漏读**：一个带百分号编码、日文及空格章节路径的样本返回空正文而未直接报错。Foliate 配合可控 ZIP 加载器和 Calibre 都能读出正文。
3. **遗留编码**：Lingo 在 Windows-1252 XHTML 中产生 7 个替换字符。Calibre 正确；Foliate 的自有加载器按编码声明解码后正确。
4. **隐藏内容**：Calibre 当前转换混入一个 `hidden` 属性元素；Lingo 简单清理混入外部 CSS 隐藏的内容。Foliate 适配层使用 DOM/CSSOM 清理两者，尚未覆盖完整 CSS 级联、全部媒体条件或原书视觉排版。
5. **错误隔离**：Lingo 的损坏 ZIP 测试出现未捕获的异步拒绝并导致子进程退出。“拒绝负例”不等于可直接获得完整的可恢复错误处理，正式导入需要隔离、超时与中文提示。
6. **加密标志**：Foliate 原库未主动拒绝“只设置加密标志、正文仍是明文”的负例。加入显式标志检查后通过；不能表述为原库包办了 DRM 检测，也不涉及解密。

两个旧 MOBI6 注音用例中，EPUB 注音在编码时已被改为普通文字，三种方案读到的含注音正文相同，不能可靠恢复原始 ruby 语义。这两例不计入 15 项质量分数。

用软件内置 Electron Node 24.22.2 重跑全部 27 例 Lingo 适配测试，状态、正文与 Node 26 完全一致；上述问题不是本机 Node 大版本造成的。

## 选型

采用 Foliate 的解析模块，不引入整套阅读器。解析模块与 ZIP 依赖随安装包分发，复用 Electron 已有的 DOM；终端用户不需额外安装 Calibre、Node.js 或 Python。

正式接入保留本轮已验证的路径、编码、注音、隐藏内容和加密标志处理，在隔离后台进程运行，补齐输入/解压大小、文字总量、超时和取消限制，返回既有 `Book.pages`。阅读、查词、翻译和生词本可继续使用现有接口。

新实现的页/节切分可能与 Calibre 不同，已有书架不应自动重导入，也不应重写已保存生词的位置。

## 接入前验收

- 在 Windows 10/11 与实际安装包中重跑：中文路径、ASAR 模块加载、取消与进程回收。本次没有 Windows 原生执行结果。
- 补充真实复杂 HUFF/CDIC、大型日文书和常用出版来源；不能用两个简化字典证明全部压缩兼容性。
- 分别验证 EPUB 正文加密和仅字体混淆的处理；当前加密负例仅覆盖 MOBI 标志。
- 使用真实用户样本检查完整段落与原句定位。图片、复杂表格、竖排和原书版式不属于此次纯文本比较。

这些是接入验收项，不改变已发布的 Calibre 导入行为。

## 来源

- [Foliate 固定版本与接口](https://github.com/johnfactotum/foliate-js/tree/78914aef4466eb960965702401634c2cb348e9b1)
- [Lingo EPUB](https://github.com/hhk-png/lingo-reader/tree/720914c1339499761d82dc68077ab521f6dafb55/packages/epub-parser)、[MOBI/KF8](https://github.com/hhk-png/lingo-reader/tree/720914c1339499761d82dc68077ab521f6dafb55/packages/mobi-parser)、[示例](https://github.com/hhk-png/lingo-reader/tree/720914c1339499761d82dc68077ab521f6dafb55/example)
- 独立 MOBI 样本的固定版本与来源 URL 见 `recorded-results.json`，原书二进制和完整提取正文不提交。


## 2026-11-10 正式接入与 Windows 安装包回归

Windows/Electron 已内置 Foliate，正式导入不再调用 Calibre。当时 macOS 原生客户端仍通过 Calibre 转换；随后已完成下述原生客户端迁移。

已完成 [Windows 真实回归运行 42734174794](https://github.com/yizhiru/Yomitoki/actions/runs/42734174794)，测试提交为 `1b7fdb9f1771f4bd2375fd685994b3d79866408d`，运行环境为 `windows-2022` x64。工作流先确认环境没有 Calibre，再测试源码客户端、生成 NSIS 安装程序、静默安装，并对实际安装的 `Yomitoki.exe` 重跑完整界面测试。

- 核心测试：20 项通过。
- 源码界面回归：2 项通过；安装后界面回归：2 项通过。
- 两次电子书回归各覆盖 25 个文件：20 个正常输入、5 个应拒绝输入。包含 EPUB2/3、章节顺序、中文/空格路径、日文注音、UTF-8 / UTF-16LE / UTF-16BE / Windows-1252、旧 MOBI、KF8、混合版、未压缩 / PalmDOC / HUFF-CDIC、字体混淆元数据、正文加密标志、损坏文件与解压上限。
- 验证了导入后实际选词、离线释义、生词保存、重启恢复、用户取消、超时，以及隐藏解析窗口的回收。
- 原有 PDF / TXT、阅读、模型模拟请求、对话、设置和导出回归同样通过。

原始逐项测试摘要见 [Windows 回归记录](windows-ebook-regression.json)，GitHub Actions 的 `windows-test-results` 产物同时保留源码与安装后截图及样本结果。这是先前验证构建的记录，安装包来自该次成功构建；重新发布的 v0.1.0 将使用相同导入实现重新构建。

这证明当前用例集在 Windows 实际安装包中通过；不等同于所有出版来源、全部复杂 CSS / HUFF 字典或每一种 Windows 配置的保证。


已验证安装包：[Yomitoki-0.1.1-windows-x64 构建产物](https://github.com/yizhiru/Yomitoki/actions/runs/42734174794/artifacts/13725952988)。产物 ZIP 大小为 211897968 字节，GitHub 记录的 ZIP SHA-256 为 `3d25e915108deaee2ce068716d609ed1f3e5fa044019b6400023ff948baa97d2`（不是 ZIP 内 EXE 的单独校验值）。


## macOS 原生客户端接入与回归（2026-11-10）

macOS 现在复用相同固定版本的 Foliate、fflate 和正文/ZIP 适配代码，随 App 打包。通过系统 WebKit 的非持久化、不可见解析页面执行，采用仅允许 App 资源的自定义 URL scheme、受限消息桥、CSP 和 30 秒超时；不启动 Calibre、Node.js、Python 或外部浏览器。Calibre 转换代码已从 `Sources/Core.swift` 移除。书架、生词本的数据格式保持兼容，旧书不自动重新导入。

Safari 17.4 才加入 `Object.groupBy` / `Map.groupBy`（[WebKit 官方说明](https://webkit.org/blog/15063/webkit-features-in-safari-17-4/)），为保持 macOS 14.0 的部署目标，在不改动固定上游源文件的前提下提供缺失方法兼容层。测试会移除这两个方法，再验证分组、原型键、Symbol 键、对象键和 NaN，以及保留原生方法。

在 Apple Silicon / macOS 27.2（26B123）上，两轮各 25 个用例均符合预期：20 个正常文件成功导入，5 个异常文件拒绝。覆盖 EPUB 2/3、日文 ruby、章节顺序、编码路径与日文文件名、Windows-1252、UTF-16LE/BE、长书、隐藏内容、MOBI 6 / KF8 / 混合文件，以及两个受控 HUFF/CDIC 字典；损坏、DRM 和超限目录不会写入书架。并验证查词、生词保存、重启、重复导入、阅读进度、取消、超时、资源缺失、重新导入和 PDF。

测试运行在禁止读取/执行本机两处 Calibre 的系统沙箱内，PATH 不含 Homebrew。第二轮将签名测试 App 移至包含空格和日文的路径，并使用 `Bundle.main` 资源定位。该 App 使用生产导入和 ReaderState 源码，替换主程序为测试入口；最终生产二进制另做启动和签名检查。现有 12 组原生测试及 20 项 Electron 核心测试通过，包内解析器源码、许可证、哈希和翻译引擎依赖校验通过。

证据：[macOS 结构化回归结果](macos-ebook-regression.json)。重跑命令见 [macOS 文档](macos.md#内置电子书兼容性回归)。本轮没有 macOS 14 真机、Intel Mac 实测，也不代表已覆盖所有商用电子书或 DRM 文件。
