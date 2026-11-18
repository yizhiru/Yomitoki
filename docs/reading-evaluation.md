# 日文阅读注音评估与方案（2026-11-18）

**决策建议：优先保存书中原有振假名，纯文本自动注音值得进入 Sudachi 主引擎的跨平台原型验证。** 保留读解的查词、基本形和生词本逻辑。仅在现有引擎留白时补上 Sudachi，在文学样本上会同时增加正确注音与偏离原书的注音。以下是本地实验，产品尚未接入新的引擎。

## 基线和计分

同一段无标注原文分别输入当前 Electron 的 `readingAnnotations`（含“俺／客／注文”修复）、macOS 原生 Lexicon，以及 koe-mieru 的 `annotate`（SudachiPy 0.7.0、core 20261015、C 模式）。另测两种组合：① 在 Electron 未覆盖且无区间重叠处采用 Sudachi；② 以 Sudachi 为主，仅把「開く」「行っ＋た／て」交回现有读解规则，规则缺乏证据时留空。组合算法决策时看不到参考答案。

- 文学组取三部作品正文中有显式假名、且基底含汉字的标注，共 420 个带标段落、3,187 处。逐次比对该版原注音，包括活用、专名、旧假名及特殊用字。作者选择加注的位置往往较难，不能外推为整本书所有词的准确率。篇幅权重集中在《坊っちゃん》。[坊っちゃん](https://www.aozora.gr.jp/cards/000148/card752.html) · [注文の多い料理店](https://www.aozora.gr.jp/cards/000081/card1927.html) · [走れメロス](https://www.aozora.gr.jp/cards/000035/card1567.html)
- 现代语料取 UD Japanese GSD r2.15 测试集，输入完整句子，评分对象仅为前后不紧邻其他汉字的纯汉字名词及专名，且 UniDic 表记与基本表记均等于原词。479 句、1,455 处。采用词汇素假名作代理参考，数字后面的「月」等仍计入。UniDic 与 Sudachi 词典有渊源，且「日本」「明日」等可有多个合理读音，因此单列该组。[语料和字段说明](https://github.com/UniversalDependencies/UD_Japanese-GSD/blob/r2.15/README.md)
- 现代诊断组是评测前编写的 40 句、53 个指定读音，覆盖对话、动词活用、日期、量词和地名。其中包含既有回归场景，用于观察失败模式；规模不足以代表通用准确率。[对照句](../scripts/reading-eval/modern.txt)

计分单位是参考位置。去除注音两端与原文相同的送假名，统一平、片假名；同一参考范围内的多个读音可与未标的原文假名拼接。可还原完整读音时记为“一致”或“不同”。仍有汉字没有读音记为“缺注”（含部分缺注）；预测跨出参考边界且无法安全拆分时独立记为“跨界”。“不同”衡量与指定读音不符，包括其他合法读法。所有比例都以该组全部位置为分母。

| 样本 | 方案 | 一致 | 不同 | 缺注 | 跨界 |
|---|---|---:|---:|---:|---:|
| 文学 | Electron | 2171 | 618 | 275 | 123 |
| 文学 | Swift | 1892 | 241 | 909 | 145 |
| 文学 | Sudachi | 2427 | 536 | 52 | 172 |
| 文学 | Electron 缺处补 Sudachi | 2272 | 712 | 79 | 124 |
| 文学 | Sudachi 加动词规则 | 2427 | 536 | 52 | 172 |
| 现代名词 | Electron | 1354 | 62 | 25 | 14 |
| 现代名词 | Swift | 1002 | 22 | 431 | 0 |
| 现代名词 | Sudachi | 1412 | 29 | 1 | 13 |
| 现代名词 | Electron 缺处补 Sudachi | 1372 | 63 | 6 | 14 |
| 现代名词 | Sudachi 加动词规则 | 1412 | 29 | 1 | 13 |
| 诊断句 | Electron | 39 | 11 | 2 | 1 |
| 诊断句 | Swift | 30 | 0 | 20 | 3 |
| 诊断句 | Sudachi | 41 | 6 | 4 | 2 |
| 诊断句 | Electron 缺处补 Sudachi | 40 | 11 | 1 | 1 |
| 诊断句 | Sudachi 加动词规则 | 42 | 5 | 4 | 2 |

按书检查一致数，Electron → Sudachi 分别为《坊っちゃん》2082 → 2322（共 3042）、《注文の多い料理店》23 → 28（57）、《走れメロス》66 → 77（88）。若让每种“表记＋参考读音”在组内权重相同，文学组的一致率仍由 64.9% 升到 73.3%，现代名词由 94.1% 升到 97.4%。原生 Swift 留白更多、不同读音较少；替换它要同时考虑错标代价，不能只按一致数选方案。

## 实际差异与阅读设计

- 小说里 Sudachi 能补回「一人＝ひとり」等，也会把原书指定「わたし」的「私」读作「わたくし」。现代地名、人名和数量表达不能用统一置信度处理。诊断句里它识别了「小鳥遊＝たかなし」「舞台の上手＝かみて」，但「毎月二十日」没有完整注出「はつか」。现有系统在这个日期给出了「にじゅうにち」。文学中的「明日」保留作者写的「あした」比事后推断更有价值。
- **原书优先。** 两端共用的电子书正文抽取器跳过 rt、rp。建议在 EPUB/MOBI 导入时把可解析的 ruby 基底、读音和范围单独保存；正文保持纯文本。以章节及规范化后的 UTF-16 区间定位，分页时裁切范围，复制、检索和例句继续用原文。复合标注保留分组，无法可靠对齐时放弃该条映射。兼容旧书无标注字段，重新导入补取时保留阅读进度。青空文本的原注仅用于本实验，HTML 原注保留的端到端效果另需用实际 EPUB/MOBI 验证。
- **缺少书内注音时按句推断。** 用 Sudachi 提供初选，先保留少量已经有对照证据的局部规则。自动门打开可读「あく」，而动词「開く」在许多表达中也可读「ひらく」。上轮把孤立的「扉が開く＝ひらく」一概判错过严。规则应有适用范围，允许用户在明确语境下修正。日期、数量词另建保留集，覆盖「一日」作日期与时长、「一人」与「一人前」，验证后才加规则。
- **允许修正本次出现的词。** 优先级建议为本处手动修正、书内原注、已验证的上下文规则、引擎建议。对姓名可由用户明确选择在本书复用。默认不跨书、不把同一表记全局替换。区间需绑定章节内容版本与原文字串，重导入时重新核对。右键词条校正即可，阅读正文保持干净。
- **跨平台验证后再分发。** 建议先做可选的本地注音组件，两端共用版本化的句子输入、UTF-16 范围与读音输出。复用按句缓存，保留选词和查词现有接口。验证离线安装、系统无 Python 的 Windows x64／macOS arm64、组件缺失时回退、后台分页与取消、旧书兼容、混合 ruby/送假名跨行和选区复制。用另一批当代小说与带出处的人名、日期做盲评；比较每组错注与缺注、安装包增量、实际翻页延迟和峰值内存后再决定默认启用范围。实验中的规则组合只使诊断组增加一个命中，没有足够证据扩大规则表。

## 本地成本与复现

本机为 arm64 macOS 27.2.1，Node 26.8.1。Sudachi core 的 system.dic 为 202,236,003 字节（192.9 MiB）；当前 kuromoji 压缩词典目录约 17 MiB，两者磁盘存储形式不同。现阶段查词也使用 kuromoji，因此不能把 17 MiB 全算作可节省空间。实际发布包增量取决于运行时与压缩方式。

以文学段落拼成 80 个互不相同的 800 字页面；每次另起进程，首个页面计引擎初始化，其余 79 页测注音耗时。连续三轮，Electron 的首个页面为 205–327 ms，后三轮各自的页耗时中位数为 4.2–4.7 ms，P95 为 6.3–10.3 ms；Sudachi 首个页面为 35–416 ms，中位数 1.0–1.7 ms，P95 为 1.2–16.3 ms。未清系统文件缓存。此测量包含各自实现的词典工作，不含应用启动、跨进程传输与界面绘制。Windows 实机和两端发布包仍需单测。

读解基线 c7727f6 加当前未提交的名词读音修复；koe-mieru 4e0df1f。运行需要读解现有 Electron 依赖、已准备的 desktop/.build/resources 和能导入 koe-mieru 依赖的 Python。实验脚本校验四个公开输入的 SHA-256。以下从仓库根目录运行，替换 KOE 为对应本地路径。

```sh
D="$PWD/.build/reading-eval"
mkdir -p "$D" .build/swift-cache
KOE="/path/to/koe-mieru"
BASE=https://raw.githubusercontent.com/aozorahack/aozorabunko_text/master/cards
curl -fLsS "$BASE/000148/files/752_ruby_2438/752_ruby_2438.txt" -o "$D/botchan.txt"
curl -fLsS "$BASE/000081/files/1927_ruby_17835/1927_ruby_17835.txt" -o "$D/chumon.txt"
curl -fLsS "$BASE/000035/files/1567_ruby_4948/1567_ruby_4948.txt" -o "$D/meros.txt"
curl -fLsS https://raw.githubusercontent.com/UniversalDependencies/UD_Japanese-GSD/r2.15/ja_gsd-ud-test.conllu -o "$D/gsd.conllu"
swiftc -O -module-cache-path .build/swift-cache Sources/Core.swift Sources/EbookImport.swift Sources/PartsOfSpeech.swift scripts/reading-eval/native.swift -lsqlite3 -o .build/eval-readings
"$KOE/.venv/bin/python" scripts/reading-eval/run.py "$D" "$KOE" "$D/details.csv"
"$KOE/.venv/bin/python" scripts/reading-eval/timing.py "$D" "$KOE"
```
