import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let paper = AppTheme.background
private let rail = AppTheme.sidebar
private let ink = AppTheme.text
private let muted = AppTheme.secondary
private let accent = AppTheme.accent
private let tintWash = AppTheme.selection
private let rule = AppTheme.separator
// Select the property wrapper for command-line toolchains without SwiftUIMacros.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct ReaderView: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var translation: LocalTranslation
    @ObservedObject var sentenceAnalysis: SentenceAnalysisState
    @ObservedObject var modelChat: ModelChatState
    @ViewState private var showingExport = false
    @AppStorage("definitionFontSize") private var definitionFontSize = AppTheme.defaultDefinitionSize
    @AppStorage("singleClickLookupEnabled") private var singleClickLookupEnabled = false

    var body: some View {
        PersistedHSplitView(identifier: "sidebar", minimumWidth: 198, idealWidth: 220,
                           maximumWidth: 340, otherMinimumWidth: 660) {
            sidebar
        } trailing: {
            if state.inNotebook {
                notebook
                    .frame(minWidth: 620)
            } else {
                PersistedHSplitView(identifier: "inspector", savedEdge: .trailing,
                                   minimumWidth: 300, idealWidth: 380, maximumWidth: 700,
                                   otherMinimumWidth: 360) {
                    reader
                } trailing: {
                    inspector
                }
            }
        }
        .background(paper)
        .font(AppTheme.interfaceFont).tint(accent)
        .foregroundStyle(ink)
        .preferredColorScheme(.light)
        .frame(minWidth: 900, minHeight: 570)
        .sheet(isPresented: $showingExport) {
            NotebookExportView(words: state.library.words, filteredWords: filtered, selectedWord: state.selectedSavedWord)
        }
        .alert("读解", isPresented: Binding(get: { state.failure != nil }, set: { if !$0 { state.failure = nil } })) {
            Button("好", role: .cancel) { state.failure = nil }
        } message: { Text(state.failure ?? "") }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed").font(.system(size: 22)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("读解").font(.system(size: 22, weight: .semibold))
                        .help("読み解き · Yomitoki")
                    Text("日语深度阅读").font(.system(size: 12)).foregroundStyle(muted)
                }
            }.padding(.horizontal, 8).padding(.top, 6)
            VStack(spacing: 4) {
                nav("阅读", "book", selected: !state.inNotebook) { state.inNotebook = false }
                nav("生词本", "bookmark", selected: state.inNotebook, count: state.library.words.count) {
                    if state.selectedSavedWord == nil { state.selectedWord = state.library.words.first?.id }
                    state.inNotebook = true
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("书架").font(.system(size: 14, weight: .medium)).foregroundStyle(muted)
                    Spacer()
                    Button(action: state.importBook) {
                        HStack(spacing: 5) {
                            if state.importing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "plus") }
                            Text(state.importing ? "读取中…" : "导入")
                        }.font(.system(size: 14))
                    }.buttonStyle(.plain).foregroundStyle(accent)
                        .help("导入 PDF、EPUB 或 MOBI 文件").accessibilityLabel("导入文件").disabled(state.importing)
                }.padding(.horizontal, 8)
                if state.importing {
                    Button("取消导入", action: state.cancelImport)
                        .buttonStyle(.plain).foregroundStyle(muted)
                        .accessibilityLabel("取消导入").padding(.horizontal, 8)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(state.library.books) { book in
                            Button { state.openBook(book.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text").font(.system(size: 14)).foregroundStyle(muted)
                                    Text(book.title).lineLimit(2)
                                        .font(.system(size: 14, weight: book.id == state.book.id ? .medium : .regular))
                                    Spacer(minLength: 0)
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(book.id == state.book.id ? tintWash : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).help(book.name)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            SettingsLink {
                Label("设置", systemImage: "gearshape").font(.system(size: 14))
                    .padding(.horizontal, 8).padding(.vertical, 8)
            }.buttonStyle(.plain).foregroundStyle(muted)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(rail)
    }

    func nav(_ name: String, _ icon: String, selected: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 15)
                Text(name).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let count { Text(count.formatted()).font(.system(size: 12, design: .monospaced)).foregroundStyle(muted) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .foregroundStyle(selected ? accent : ink)
            .background(selected ? tintWash : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    var reader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Text(state.book.kind).font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(1)
                    Text(" / ").foregroundStyle(rule)
                    Text(state.book.name).lineLimit(1).help(state.book.name)
                }.font(.system(size: 13)).foregroundStyle(muted)
                Spacer()
                if state.textSelection == nil || state.selectedContentLevel == .word {
                    Button(action: state.defineSelection) {
                        Label("词典释义", systemImage: "text.magnifyingglass")
                    }.tint(accent).disabled(state.textSelection == nil).help("查询选中文字的离线词典释义")
                }
                if state.canTranslateSelection {
                    Button {
                        if let range = state.textSelection { state.translateSelection(range) }
                    } label: { Label("本地翻译", systemImage: "character.bubble") }
                        .tint(accent).help("在本机翻译选中的句子或段落")
                }
                if state.canAnalyzeSelection {
                    Button {
                        if let range = state.textSelection { state.analyzeSelection(range) }
                    } label: { Label("长句分析", systemImage: "text.alignleft") }
                        .tint(accent).help("使用已配置的大模型分析句子结构与修饰层级")
                }
                Button(action: state.openChat) {
                    Label("大模型对话", systemImage: "bubble.left.and.bubble.right")
                }.labelStyle(.iconOnly).tint(accent)
                    .disabled(state.textSelection == nil && modelChat.conversations.isEmpty)
                    .help(state.textSelection == nil ? "继续上次的大模型对话" : "与大模型讨论选中文字")
                Menu {
                    Button("小") { state.fontSize = 22 }
                    Button("中") { state.fontSize = 26 }
                    Button("大") { state.fontSize = 30 }
                } label: { Image(systemName: "textformat.size").accessibilityLabel("字号") }
                    .menuStyle(.borderlessButton).fixedSize().help("调整字号")
            }.padding(.horizontal, 24).frame(height: 52)
            Divider().overlay(rule)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.book.title)
                    .font(.system(size: 26, weight: .medium)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 9)
                Text(singleClickLookupEnabled ? "单击查词，选文后可翻译、分析或对话"
                     : "选中文字后，可查词、翻译或与大模型对话")
                    .font(.system(size: 14)).foregroundStyle(muted)
                Spacer().frame(height: 10)
                ReadingText(bodyText: state.book.pages[state.book.page],
                            revision: state.revision, selection: state.textSelection == nil ? state.lookup?.range : nil, fontSize: state.fontSize,
                            singleClickLookupEnabled: singleClickLookupEnabled,
                            onTap: state.choose, onSelectionChange: { state.textSelection = $0 },
                            onDictionaryLookup: { range in state.textSelection = range; state.defineSelection() },
                            onModelLookup: state.defineModelSelection,
                            onTranslation: state.translateSelection,
                            selectionLevel: state.selectionLevel,
                            onSentenceAnalysis: state.analyzeSelection, onModelChat: state.chatSelection)
                    .padding(.leading, -8)
            }.padding(.horizontal, 32).padding(.top, 24).frame(maxWidth: 780).frame(maxWidth: .infinity)
            Divider().overlay(rule)
            HStack {
                pageButton("上一\(state.book.unit)", "chevron.left", state.book.page > 0) { state.showPage(state.book.page - 1) }
                Spacer()
                Menu {
                    ForEach(state.book.pages.indices, id: \.self) { page in
                        Button("第 \(page + 1) \(state.book.unit)") { state.showPage(page) }
                    }
                } label: {
                    Text("第 \(state.book.page + 1) / \(state.book.pages.count) \(state.book.unit)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }.menuStyle(.borderlessButton).fixedSize().help("跳到指定位置")
                Spacer()
                pageButton("下一\(state.book.unit)", "chevron.right", state.book.page + 1 < state.book.pages.count) { state.showPage(state.book.page + 1) }
            }.padding(.horizontal, 22).frame(height: 49)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func pageButton(_ label: String, _ icon: String, _ enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? accent : muted.opacity(0.5)).padding(7).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled)
    }

    var inspector: some View {
        Group {
            if modelChat.isPresented {
                ModelChatView(chat: modelChat, preferences: state.preferences, fontSize: definitionFontSize)
            } else if sentenceAnalysis.source != nil {
                SentenceAnalysisView(analysis: sentenceAnalysis, fontSize: definitionFontSize)
            } else if translation.source != nil {
                LocalTranslationResultView(translation: translation, fontSize: definitionFontSize)
            } else {
                dictionaryInspector
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(paper)
    }

    var dictionaryInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("词义与出处", systemImage: "text.magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                .padding(.horizontal, 21).frame(height: 52)
            Divider().overlay(rule)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let lookup = state.lookup {
                        definition(lookup.definition, showMissingMeaning: !state.querying && state.lookupFailure == nil)
                        if state.querying {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在查询语境释义…").font(.system(size: max(13, definitionFontSize - 3))).foregroundStyle(muted)
                            }
                        }
                        if let failure = state.lookupFailure {
                            Text(failure).font(.system(size: max(14, definitionFontSize - 2))).foregroundStyle(.red).textSelection(.enabled)
                            HStack(spacing: 14) {
                                Button("重试", action: state.retryLookup)
                                SettingsLink { Text("设置") }
                            }.font(.system(size: 14)).tint(accent)
                        }
                        if state.reusedDefinition {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("已复用已有词条释义，词义及活用说明可能与当前原句不同。")
                                    .font(.system(size: max(12, definitionFontSize - 4))).foregroundStyle(muted)
                                Button("按当前原句重新释义", action: state.regenerateLookup)
                                    .font(.system(size: 14)).tint(accent)
                            }
                        }
                        if let warning = state.cacheWarning {
                            Text(warning).font(.system(size: max(12, definitionFontSize - 4))).foregroundStyle(muted)
                        }
                        occurrence(lookup.occurrence)
                        let added = state.contains(lookup)
                        Button { state.save(lookup) } label: {
                            Label(added ? "已保存这条例句" : state.hasSavedExample(lookup) ? "更新这条例句" : "加入生词本", systemImage: added ? "checkmark" : "bookmark")
                                .font(.system(size: 14, weight: .semibold)).padding(11).frame(maxWidth: .infinity)
                                .foregroundStyle(added ? accent : .white)
                                .background(added ? tintWash : accent, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(added || state.querying || state.lookupFailure != nil)
                        if added {
                            Button("在生词本中查看") {
                                state.selectedWord = lookup.key
                                state.inNotebook = true
                            }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                        }
                    } else {
                        Text("选词开始阅读").font(.system(size: 26, weight: .medium))
                        Text("选中文字后点击「词典释义」查看离线释义，或选择「大模型释义」查询语境词义。")
                            .font(.system(size: 18)).foregroundStyle(muted).lineSpacing(6)
                        if singleClickLookupEnabled, state.book.kind == "示例", state.book.page == 0,
                           let range = state.book.pages[0].range(of: "喫茶店") {
                            Button { state.choose(NSRange(range, in: state.book.pages[0]).location) } label: {
                                Label("试查「喫茶店」", systemImage: "arrow.up.left").font(.system(size: 14, weight: .semibold))
                            }.buttonStyle(.plain).foregroundStyle(accent)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(21)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func definition(_ value: Definition, showMissingMeaning: Bool = true) -> some View {
        let value = state.dictionary.addingDictionaryEnglish(to: value)
        return VStack(alignment: .leading, spacing: 12) {
            Text(value.head).font(.system(size: definitionFontSize + 12, weight: .medium)).textSelection(.enabled)
            if !value.reading.isEmpty { Text(value.reading).font(.system(size: definitionFontSize + 2)).foregroundStyle(accent).textSelection(.enabled) }
            partOfSpeech(value)
            if let en = value.english {
                Text("英文释义").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent).padding(.top, 4)
                Text(en).font(.system(size: definitionFontSize)).lineSpacing(6).textSelection(.enabled)
            }
            if let zh = value.chineseMeaning {
                Text(value.source == nil ? "中文释义" : "中文语境释义")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(accent).padding(.top, 4)
                if let source = value.source {
                    Text("AI · \(source)").font(.system(size: 14, weight: .medium)).foregroundStyle(muted)
                }
                Text(zh).font(.system(size: definitionFontSize)).lineSpacing(6).textSelection(.enabled)
            }
            Button {
                Task { @MainActor in
                    do { try await MOJiSearch().open(word: value.head) }
                    catch { state.failure = error.localizedDescription }
                }
            } label: {
                Label("在 MOJi 中查询", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered).tint(accent).font(.system(size: 14, weight: .medium))
            .help("优先打开 MOJi 客户端，无法打开时使用浏览器搜索")
            if let etymology = value.etymology {
                Text("外来语词源").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent).padding(.top, 4)
                Text(etymology).font(.system(size: definitionFontSize)).lineSpacing(6).textSelection(.enabled)
            }
            if !value.hasMeaning && showMissingMeaning {
                Text("词典中暂未找到释义，可通过选词后的「大模型释义」查询。仍可保存原句。")
                    .font(.system(size: definitionFontSize)).foregroundStyle(muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func partOfSpeech(_ value: Definition, compact: Bool = false) -> some View {
        let tags = state.dictionary.partsOfSpeech(for: value)
        if !tags.isEmpty {
            Text(tags.map(\.label).joined(separator: " · "))
                .font(.system(size: compact ? 13 : 14)).foregroundStyle(accent)
                .fixedSize(horizontal: false, vertical: true)
                .help("本地 JMdict 词性标记：" + tags.map(\.code).joined(separator: ", "))
        }
    }

    func notebookDefinition(_ word: SavedWord) -> some View {
        let meanings = state.dictionary.notebookMeanings(for: word)
        let value = word.definition
        return definition(Definition(head: value.head, reading: value.reading, chinese: meanings.chinese,
                                     english: value.english, etymology: value.source == nil ? value.etymology : nil),
                          showMissingMeaning: false)
    }

    @ViewBuilder
    func notebookModelMeaning(_ value: Definition) -> some View {
        if value.source != nil, let chinese = value.chineseMeaning {
            VStack(alignment: .leading, spacing: 8) {
                Text("大模型释义").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                if let source = value.source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("AI · \(source)").font(.system(size: 14, weight: .medium)).foregroundStyle(muted)
                }
                Text(chinese).font(.system(size: definitionFontSize)).lineSpacing(6).textSelection(.enabled)
                if let etymology = value.etymology, !etymology.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("外来语词源").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                    Text(etymology).font(.system(size: definitionFontSize)).lineSpacing(6).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func occurrence(_ example: Occurrence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("原句").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
            sentence(example.context).font(.system(size: definitionFontSize)).lineSpacing(6).textSelection(.enabled)
            Divider().overlay(rule)
            Label(example.filename, systemImage: "doc.text").font(.system(size: 13, weight: .medium))
                .foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text(example.location).font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    func sentence(_ context: SentenceContext) -> Text {
        Text(context.before) + Text(context.word).bold().foregroundColor(accent) + Text(context.after)
    }

    var filtered: [SavedWord] {
        let q = state.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return state.library.words }
        return state.library.words.filter { entry in
            let meanings = state.dictionary.notebookMeanings(for: entry)
            let text = [entry.definition.head, entry.definition.reading, meanings.chinese ?? "",
                        entry.definition.english ?? "", entry.definition.etymology ?? ""]
                + meanings.modelDefinitions.map { $0.chineseMeaning ?? "" }
            return text.contains { $0.localizedCaseInsensitiveContains(q) }
            || entry.examples.contains { example in
                [example.filename, example.context.sentence, example.definition?.chinese ?? "", example.definition?.etymology ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(q) }
            }
        }
    }

    var notebook: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("生词本").font(.system(size: 28, weight: .semibold))
                    Text("\(state.library.words.count) 个词 · \(state.library.words.reduce(0) { $0 + $1.examples.count }) 条语境").font(.system(size: 14)).foregroundStyle(muted)
                }
                Spacer()
                Button { showingExport = true } label: {
                    Label("导出生词", systemImage: "square.and.arrow.up")
                }.tint(accent).disabled(state.library.words.isEmpty)
            }.padding(.horizontal, 30).padding(.vertical, 23)
            Divider().overlay(rule)
            if state.library.words.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "bookmark").font(.system(size: 27)).foregroundStyle(accent)
                    Text("还没有收藏的词").font(.system(size: 22))
                    Text("在阅读时查词并加入生词本，就能在这里重温原句。").font(.system(size: 14)).foregroundStyle(muted)
                    Button("返回阅读") { state.inNotebook = false }.tint(accent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PersistedHSplitView(identifier: "notebookList", minimumWidth: 200, idealWidth: 250,
                                   maximumWidth: 420, otherMinimumWidth: 320) {
                    VStack(spacing: 9) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(muted)
                            TextField("搜索词语、原句或文件", text: $state.search).textFieldStyle(.plain)
                        }.padding(10).background(paper, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(rule, lineWidth: 0.5))
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(filtered) { word in
                                    let meanings = state.dictionary.notebookMeanings(for: word)
                                    Button { state.selectedWord = word.id } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(word.definition.head).font(.system(size: 18, weight: .medium))
                                            Text("\(word.definition.reading)  ·  \(word.examples.count) 条语境").font(.system(size: 12)).foregroundStyle(muted)
                                            partOfSpeech(word.definition, compact: true)
                                            if let chinese = meanings.chinese {
                                                Text("中文 · \(chinese)").font(.system(size: 14)).foregroundStyle(muted)
                                                    .lineLimit(2).help(chinese)
                                            }
                                            ForEach(Array(meanings.modelDefinitions.enumerated()), id: \.offset) { _, value in
                                                if let chinese = value.chineseMeaning {
                                                    Text("大模型 · \(chinese)").font(.system(size: 14)).foregroundStyle(accent)
                                                        .lineLimit(2).help(chinese)
                                                }
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                            .background(word.id == state.selectedWord ? tintWash : .clear, in: RoundedRectangle(cornerRadius: 7))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                                if filtered.isEmpty { Text("没有匹配的词语").font(.system(size: 14)).foregroundStyle(muted).padding(8) }
                            }
                        }
                    }.padding(13)
                        .frame(maxHeight: .infinity).background(rail.opacity(0.55))
                } trailing: {
                    ScrollView {
                        if let word = state.selectedSavedWord, filtered.contains(where: { $0.id == word.id }) {
                            VStack(alignment: .leading, spacing: 17) {
                                notebookDefinition(word)
                                notebookModelMeaning(word.definition)
                                ForEach(word.examples) { example in
                                    VStack(alignment: .leading, spacing: 8) {
                                        if let savedDefinition = example.definition, savedDefinition != word.definition {
                                            if savedDefinition.source == nil {
                                                definition(savedDefinition, showMissingMeaning: false)
                                            } else {
                                                notebookModelMeaning(savedDefinition)
                                            }
                                        }
                                        occurrence(example)
                                        HStack {
                                            Button { state.show(word, at: example) } label: {
                                                Label("返回原文", systemImage: "arrow.up.left")
                                            }.buttonStyle(.plain).foregroundStyle(accent)
                                            Spacer()
                                            if word.examples.count > 1 {
                                                Button(role: .destructive) { state.remove(example, from: word) } label: {
                                                    Label("移除此语境", systemImage: "trash")
                                                }.buttonStyle(.plain).foregroundStyle(muted).help("仅移除这条原句，保留单词")
                                            }
                                        }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 4)
                                    }
                                }
                            }.padding(24)
                        } else {
                            Text("选择一个词查看原句与出处。").font(.system(size: 14)).foregroundStyle(muted)
                                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let word = state.selectedSavedWord, filtered.contains(where: { $0.id == word.id }) {
                            VStack(spacing: 0) {
                                HStack {
                                    Text("词条详情").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                                    Spacer()
                                    Button(role: .destructive) { state.remove(word) } label: {
                                        Label("删除单词", systemImage: "trash")
                                    }
                                    .buttonStyle(.borderless).font(.system(size: 14))
                                    .help("从生词本删除「\(word.definition.head)」及其全部语境")
                                }.padding(.horizontal, 24).padding(.vertical, 12)
                                Divider().overlay(rule)
                            }.background(paper)
                        }
                    }
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NotebookExportView: View {
    let words: [SavedWord]
    let filteredWords: [SavedWord]
    let selectedWord: SavedWord?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var format = NotebookExportFormat.csv
    @ViewState private var scope = Scope.all
    @ViewState private var fields = Set(NotebookExportField.allCases)
    @ViewState private var failure: String?

    private enum Scope { case all, filtered, selected }

    private var selectedWords: [SavedWord] {
        switch scope {
        case .all: return words
        case .filtered: return filteredWords
        case .selected: return selectedWord.map { [$0] } ?? []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导出生词").font(.system(size: 26, weight: .medium))
            Form {
                Picker("格式", selection: $format) {
                    ForEach(NotebookExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Picker("范围", selection: $scope) {
                    Text("全部生词（\(words.count) 个）").tag(Scope.all)
                    Text("当前搜索结果（\(filteredWords.count) 个）").tag(Scope.filtered)
                    Text("当前选中的词（\(selectedWord == nil ? 0 : 1) 个）").tag(Scope.selected)
                }
                Section("导出内容") {
                    Text("单词始终导出，其他信息可按需勾选。")
                        .font(AppTheme.captionFont).foregroundStyle(muted)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 12) {
                        ForEach(NotebookExportField.allCases, id: \.self) { field in
                            Toggle(field.title, isOn: Binding(get: { fields.contains(field) }, set: { included in
                                if included { fields.insert(field) } else { fields.remove(field) }
                            })).toggleStyle(.checkbox)
                        }
                    }.padding(.vertical, 5)
                }
            }.formStyle(.grouped)
            Text("包含原句、原文词形、文件名或位置时，每条例句单独导出。仅导出词义时，相同内容会合并。")
                .font(AppTheme.captionFont).foregroundStyle(muted)
            if let failure { Text(failure).font(.system(size: 14)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("将导出 \(selectedWords.count) 个词").font(.system(size: 14)).foregroundStyle(muted)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导出…", action: export).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(accent).disabled(selectedWords.isEmpty)
            }
        }
        .padding(24).font(AppTheme.interfaceFont).frame(width: 580, height: 560).background(paper).foregroundStyle(ink).preferredColorScheme(.light)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "导出生词"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "读解生词本.\(format.rawValue)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = NotebookExporter.data(words: selectedWords, fields: fields, format: format)
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch { failure = "导出失败。\(error.localizedDescription)" }
    }
}

struct DefinitionSettingsView: View {
    private enum Tab { case reading, model, translation }
    @ObservedObject var state: ReaderState
    @ObservedObject var preferences: DefinitionPreferences
    @ObservedObject var translation: LocalTranslation
    @ViewState private var draft = DefinitionSettings()
    @ViewState private var keys: [ModelProvider: String] = [:]
    @ViewState private var loadedKeys: Set<ModelProvider> = []
    @ViewState private var loadingKeys: Set<ModelProvider> = []
    @ViewState private var tab = Tab.reading
    @ViewState private var message: String?
    @ViewState private var saved = false
    @AppStorage("definitionFontSize") private var definitionFontSize = AppTheme.defaultDefinitionSize
    @AppStorage("singleClickLookupEnabled") private var singleClickLookupEnabled = false

    private var apiKey: Binding<String> {
        Binding(get: { keys[draft.provider] ?? "" }, set: { keys[draft.provider] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.system(size: 26, weight: .medium))
            Picker("设置类别", selection: $tab) {
                Text("阅读显示").tag(Tab.reading)
                Text("大模型").tag(Tab.model)
                Text("本地翻译").tag(Tab.translation)
            }.pickerStyle(.segmented)
            Form {
                if tab == .reading {
                Section("阅读显示") {
                    Toggle("单击自动查词", isOn: $singleClickLookupEnabled)
                    Text("关闭后，选中文字并点击「词典释义」或「大模型释义」才会查询。按 ⌘C 复制。")
                        .font(AppTheme.captionFont).foregroundStyle(muted)
                    HStack(spacing: 12) {
                        Text("释义字号")
                        Slider(value: $definitionFontSize, in: 14...30, step: 1)
                            .accessibilityLabel("释义字号")
                        Text("\(Int(definitionFontSize))")
                            .monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                    Text("即时生效并自动保存，释义、读音及原句随之调整。生词本详情同步使用此字号。")
                        .font(AppTheme.captionFont).foregroundStyle(muted)
                }
                } else if tab == .translation {
                    LocalTranslationSettingsContent(translation: translation)
                } else {
                Section("大模型") {
                    Text("普通查词使用离线词典。「大模型释义」「长句分析」「大模型对话」共用以下配置，仅在主动查询或发送问题时请求。")
                        .font(AppTheme.captionFont).foregroundStyle(muted)
                    Picker("服务商", selection: $draft.provider) {
                        ForEach(ModelProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if draft.provider == .deepseek {
                        LabeledContent("API URL", value: "https://api.deepseek.com")
                        TextField("模型名称", text: $draft.deepseekModel, prompt: Text("deepseek-flash"))
                    } else {
                        TextField("API URL", text: $draft.customURL, prompt: Text("https://api.example.com/v1"))
                        Text("可填写服务商提供的 Base URL 或完整的 /chat/completions 地址。")
                            .font(AppTheme.captionFont).foregroundStyle(muted)
                        TextField("模型名称", text: $draft.customModel, prompt: Text("填写服务商的模型 ID"))
                    }
                    SecureField("API key", text: apiKey, prompt: Text("输入你的 API key"))
                        .disabled(!loadedKeys.contains(draft.provider))
                    Text("API key 保存在 macOS 钥匙串中。释义发送词语及原句，长句分析发送所选句段，对话发送选文、附近原文与本次对话记录，费用由你的 API 账户承担。")
                        .font(AppTheme.captionFont).foregroundStyle(muted)
                }
                }
            }.formStyle(.grouped)
            if tab == .model, let message {
                Text(message).font(.system(size: 14)).foregroundStyle(.red).textSelection(.enabled)
            }
            if tab == .model { HStack {
                if saved { Label("设置已保存", systemImage: "checkmark").font(.system(size: 14)).foregroundStyle(accent) }
                Spacer()
                Button("保存模型设置") {
                    do {
                        try state.saveSettings(draft, apiKey: apiKey.wrappedValue)
                        draft = preferences.settings
                        message = nil
                        saved = true
                    } catch {
                        message = error.localizedDescription
                        saved = false
                    }
                }.keyboardShortcut("s").buttonStyle(.borderedProminent).tint(accent)
                    .disabled(draft.source == .model && !loadedKeys.contains(draft.provider))
            } }
        }
        .padding(24).font(AppTheme.interfaceFont).frame(width: 680, height: tab == .reading ? 400 : 680)
        .background(paper).foregroundStyle(ink).preferredColorScheme(.light)
        .onAppear {
            draft = preferences.settings
            draft.source = .model
            message = preferences.loadFailure
            loadKey()
        }
        .onChange(of: draft) { _, _ in
            saved = false
            loadKey()
        }
        .onChange(of: keys) { _, _ in saved = false }
        .onChange(of: tab) { _, _ in loadKey() }
    }

    private func loadKey() {
        guard tab == .model, !loadedKeys.contains(draft.provider), !loadingKeys.contains(draft.provider) else { return }
        let provider = draft.provider
        loadingKeys.insert(provider)
        Task { @MainActor in
            do {
                let key = try await Task.detached { try APIKeyStore.read(provider) }.value
                keys[provider] = key
                loadedKeys.insert(provider)
                message = nil
            } catch { message = error.localizedDescription }
            loadingKeys.remove(provider)
        }
    }
}

@main struct YomitokiApp: App {
    @StateObject private var state = ReaderState()

    init() {
        // Use the bundled artwork directly for the running app's Dock icon.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        Window("读解 · 日语深度阅读", id: "main") {
            ReaderView(state: state, translation: state.translation, sentenceAnalysis: state.sentenceAnalysis, modelChat: state.modelChat)
        }
            .defaultSize(width: 1180, height: 740)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("导入文件…", action: state.importBook).keyboardShortcut("o")
                }
            }
        Settings { DefinitionSettingsView(state: state, preferences: state.preferences, translation: state.translation) }
    }
}
