# EPUB / MOBI 导入兼容性对比

本目录是隔离验证工具，不参与应用打包，不修改正式导入逻辑或生产依赖。

- [兼容性评估与选型](../../docs/epub-mobi-compatibility.md)
- `recorded-results.json`：本次 27 个文件的来源、SHA-256 和逐项结果。
- `recorded-electron-node-results.json`：内置 Electron Node 与本机 Node 的交叉核对。

## 复现

开发机需要 Node、Python 3、git、Calibre，以及项目现有的 Electron 开发依赖。这是对比工具的开发环境要求，不是未来终端用户的安装要求。

在本目录运行：

```sh
npm ci --ignore-scripts --no-audit --no-fund
python run-evaluation.py
```

可显式指定开发工具路径：

```sh
python run-evaluation.py --node /path/to/node --calibre /path/to/ebook-convert --electron /path/to/electron
```

Windows 可传入带引号的 `.exe` 完整路径。程序默认查找系统 Node、Calibre 默认目录，以及 `../node_modules/electron`。首次运行下载固定版本的解析器和公开样本；请查看各步骤日志，不要跳过下载失败的样本后宣称通过。

输出为 `environment.json`、`comparison-summary.json`、`corpus/` 和 `results/`，均被 git 忽略。`recorded-*.json` 是本次已完成的历史记录，不会被重跑覆盖。原书二进制与提取后的完整正文不随本目录提交或打包。

## 口径

Calibre 使用当前导入代码相同的 TXT 参数。Lingo 0.4.6 使用 ESM 入口与 HTML 正文适配。Foliate 使用固定提交，在 Electron 隔离沙箱中运行，并附加 ZIP 路径/编码加载、DOM/CSS 正文提取及加密标志检查。

自制样本逐段对比已知正文；公开样本均匀抽取最多 40 个段落，每段取 64 个非空字符，检查存在性和顺序。这是抽查，不是全书逐字等价证明。两个 EPUB 转 MOBI6 的注音用例已在编码阶段丢失语义，只作诊断。HUFF/CDIC 两例为自制固定码字典，覆盖字面和递归短语。负例覆盖截断 ZIP、截断 MOBI 和加密标志拒绝，不涉及解密。

本次记录来自 macOS 与软件实际的 Electron 环境；Windows 本机及安装包仍须单独回归，不能将本次结果表述为 Windows 安装包已验证通过。
