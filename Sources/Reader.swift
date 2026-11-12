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

private struct ReadingSearchMatch {
    let page: Int
    let range: NSRange
}

private struct SidebarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var selected = false
    var emphasized = false
    var navigation = false
    var minimumHeight: CGFloat = 46

    func makeBody(configuration: Configuration) -> some View {
        let filled = navigation && selected
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .foregroundStyle(filled ? .white : (selected || emphasized ? accent : ink))
            .background(filled ? accent : (selected || emphasized || configuration.isPressed ? tintWash : .clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.55)
            .contentShape(Rectangle())
    }
}

struct ReaderView: View {
    private enum HistorySection: String, CaseIterable { case analyses = "长句分析", chats = "大模型对话" }
    @ObservedObject var state: ReaderState
    @ObservedObject var translation: LocalTranslation
    @ObservedObject var sentenceAnalysis: SentenceAnalysisState
    @ObservedObject var modelChat: ModelChatState
    @ViewState private var showingExport = false
    @ViewState private var noteDraft: ReadingNote?
    @ViewState private var bookInfo: Book?
    @ViewState private var bookToRemove: Book?
    @ViewState private var noteToDelete: ReadingNote?
    @ViewState private var notesBookID: UUID?
    @ViewState private var historyBookID: UUID?
    @ViewState private var pagination: ReadingPagination?
    @ViewState private var showingReadingSearch = false
    @ViewState private var readingQuery = ""
    @ViewState private var readingMatches: [ReadingSearchMatch] = []
    @ViewState private var readingMatchIndex: Int?
    @ViewState private var readingSearchCompleted = false
    @FocusState private var readingSearchFocused: Bool
    @ViewState private var notesQuery = ""
    @ViewState private var historySection = HistorySection.analyses
    @ViewState private var historyDeletion: (() -> Void)?
    @ViewState private var inspectorOverride: Bool?
    @AppStorage("definitionFontSize") private var definitionFontSize = AppTheme.defaultDefinitionSize
    @AppStorage("singleClickLookupEnabled") private var singleClickLookupEnabled = false

    var body: some View {
        GeometryReader { geometry in
            workspace(compact: geometry.size.width < 1100)
                .onChange(of: geometry.size.width < 1100) { inspectorOverride = nil }
        }
        .background(paper)
        .font(AppTheme.interfaceFont).tint(accent)
        .foregroundStyle(ink)
        .preferredColorScheme(.light)
        .frame(minWidth: 900, minHeight: 570)
        .onReceive(state.$lookup) { lookup in
            if lookup != nil && inspectorOverride == false { inspectorOverride = nil }
        }
        .onReceive(sentenceAnalysis.$source) { source in
            if source != nil && inspectorOverride == false { inspectorOverride = nil }
        }
        .onReceive(translation.$source) { source in
            if source != nil && inspectorOverride == false { inspectorOverride = nil }
        }
        .onReceive(modelChat.$isPresented) { presented in
            if presented && inspectorOverride == false { inspectorOverride = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            state.flushReadingProgress()
        }
        .onDisappear { state.flushReadingProgress() }
        .onChange(of: state.activeBook?.id) {
            readingQuery = ""
            readingMatches = []
            readingMatchIndex = nil
            readingSearchCompleted = false
        }
        .sheet(isPresented: $showingExport) {
            NotebookExportView(words: state.library.words, filteredWords: filtered, selectedWord: state.selectedSavedWord)
        }
        .sheet(item: $noteDraft) { note in
            ReadingNoteEditor(note: note, book: state.library.books.first { $0.id == note.bookID },
                              save: state.saveNote)
        }
        .sheet(item: $bookInfo) { book in
            BookInfoEditor(book: book) { state.saveBookMetadata($0, for: book.id) }
        }
        .confirmationDialog("移出书架？", isPresented: Binding(
            get: { bookToRemove != nil }, set: { if !$0 { bookToRemove = nil } }
        ), titleVisibility: .visible, presenting: bookToRemove) { book in
            Button("移出书架", role: .destructive) { state.removeFromShelf(book.id) }
        } message: { book in
            Text("将《\(book.title)》移出书架。原文件、笔记和历史记录会保留。")
        }
        .confirmationDialog("删除这条笔记？", isPresented: Binding(
            get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } }
        ), titleVisibility: .visible, presenting: noteToDelete) { note in
            Button("删除笔记", role: .destructive) { state.deleteNote(note.id) }
        }
        .alert("读解", isPresented: Binding(get: { state.failure != nil }, set: { if !$0 { state.failure = nil } })) {
            Button("好", role: .cancel) { state.failure = nil }
        } message: { Text(state.failure ?? "") }
    }

    private func workspace(compact: Bool) -> some View {
        let hasResult = state.lookup != nil || sentenceAnalysis.source != nil
            || translation.source != nil || modelChat.isPresented
        let inspectorVisible = inspectorOverride ?? (!compact || hasResult)
        return PersistedHSplitView(identifier: "sidebar", minimumWidth: 198, idealWidth: 220,
                           maximumWidth: 340, otherMinimumWidth: 660) {
            sidebar
        } trailing: {
            if state.inNotebook {
                notebook
                    .frame(minWidth: 620)
            } else if state.destination == .notes || state.destination == .history {
                readingRecords(isHistory: state.destination == .history)
            } else if state.activeBook != nil {
                PersistedHSplitView(identifier: "inspector", savedEdge: .trailing,
                                   minimumWidth: 300, idealWidth: 380, maximumWidth: 700,
                                   otherMinimumWidth: 360, trailingCollapsed: !inspectorVisible) {
                    GeometryReader { geometry in
                        reader(inspectorVisible: inspectorVisible, compactControls: geometry.size.width < 480) {
                            inspectorOverride = !inspectorVisible
                        }
                    }
                } trailing: {
                    inspector
                }
            } else {
                ContentUnavailableView {
                    Label("书架为空", systemImage: "books.vertical")
                } actions: {
                    Button("导入书籍", action: state.importBook)
                        .buttonStyle(AppActionButtonStyle(prominent: true)).disabled(state.importing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed.fill").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white).frame(width: 36, height: 36)
                    .background(accent, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                Text("读解").font(.system(size: 24, weight: .bold))
                    .help("読み解き · Yomitoki")
            }.padding(.horizontal, 8).padding(.top, 6)
            VStack(spacing: 4) {
                nav("阅读", "book", selected: state.destination == .reading) { state.destination = .reading }
                nav("生词本", "bookmark", selected: state.inNotebook, count: state.library.words.count) {
                    if state.selectedSavedWord == nil { state.selectedWord = state.library.words.first?.id }
                    state.inNotebook = true
                }
                nav("笔记本", "note.text", selected: state.destination == .notes, count: state.library.notes.count) {
                    notesBookID = notesBookID ?? state.activeBook?.id
                    state.destination = .notes
                }
                nav("历史记录", "clock", selected: state.destination == .history) {
                    historyBookID = historyBookID ?? state.activeBook?.id
                    state.destination = .history
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("书架").font(.system(size: 14, weight: .medium)).foregroundStyle(muted)
                    .padding(.horizontal, 12)
                Button(action: state.importBook) {
                    HStack(spacing: 10) {
                        if state.importing { ProgressView().controlSize(.small).frame(width: 20) }
                        else { Image(systemName: "plus").frame(width: 20) }
                        Text(state.importing ? "读取中…" : "导入书籍")
                    }.font(.system(size: 16, weight: .medium))
                }.buttonStyle(SidebarButtonStyle(emphasized: true))
                    .help("导入 PDF、EPUB 或 MOBI 文件").accessibilityLabel("导入文件").disabled(state.importing)
                if state.importing {
                    Button(action: state.cancelImport) {
                        Label("取消导入", systemImage: "xmark").font(.system(size: 16))
                    }.buttonStyle(SidebarButtonStyle())
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(state.shelfBooks) { book in
                            Button { state.openBook(book.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text").frame(width: 20).foregroundStyle(muted)
                                    Text(book.title).lineLimit(2)
                                }
                                .font(.system(size: 15, weight: book.id == state.book.id ? .medium : .regular))
                            }.buttonStyle(SidebarButtonStyle(selected: book.id == state.book.id)).help(book.title)
                                .contextMenu {
                                    Button { bookInfo = book } label: {
                                        Label("文档信息", systemImage: "info.circle")
                                    }
                                    Button(role: .destructive) { bookToRemove = book } label: {
                                        Label("移出书架", systemImage: "minus.circle")
                                    }
                                }
                        }
                    }
                }
            }
            SettingsLink {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape").frame(width: 20)
                    Text("设置")
                }.font(.system(size: 16, weight: .medium))
            }.buttonStyle(SidebarButtonStyle())
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(rail)
    }

    func nav(_ name: String, _ icon: String, selected: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                Text(name)
                Spacer(minLength: 4)
                if let count {
                    Text(count.formatted()).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(selected ? Color.white.opacity(0.88) : muted)
                }
            }
            .font(.system(size: 17, weight: .semibold))
        }.buttonStyle(SidebarButtonStyle(selected: selected, navigation: true, minimumHeight: 52))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var paginated: Bool { state.book.kind == "EPUB" }

    private var currentPagination: ReadingPagination? {
        guard paginated, pagination?.revision == state.revision else { return nil }
        return pagination
    }

    private func turnPage(forward: Bool) {
        guard !paginated || currentPagination != nil else { return }
        let section = state.book.page
        if let offset = forward ? currentPagination?.nextOffset : currentPagination?.previousOffset {
            state.turnReadingPage(section: section, offset: offset)
        } else {
            state.turnReadingPage(section: section + (forward ? 1 : -1),
                                  offset: paginated && !forward ? Int.max : 0)
        }
    }

    private func readingText(size: CGSize? = nil) -> ReadingText {
        let match = readingMatchIndex.map { readingMatches[$0] }
        let searchHighlight = showingReadingSearch && match?.page == state.book.page ? match?.range : nil
        return ReadingText(bodyText: state.book.pages[state.book.page],
                    revision: state.revision, selection: state.textSelection == nil ? state.lookup?.range : nil,
                    fontSize: state.fontSize, singleClickLookupEnabled: singleClickLookupEnabled,
                    onTap: state.choose, onSelectionChange: { range, hasLetters in
                        state.noteSelection = range
                        state.textSelection = hasLetters ? range : nil
                    },
                    onDictionaryLookup: { range in state.textSelection = range; state.defineSelection() },
                    onModelLookup: state.defineModelSelection, onTranslation: state.translateSelection,
                    selectionLevel: state.selectionLevel,
                    onSentenceAnalysis: state.analyzeSelection, onModelChat: { state.chatSelection($0) },
                    searchHighlight: searchHighlight, pageSize: size,
                    readingOffset: state.readingOffset, onPagination: { value in
                        if value.revision == state.revision { pagination = value }
                    }, onPageTurn: turnPage, onReadingProgress: state.recordReadingProgress)
    }

    private func findInBook() {
        let query = readingQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches: [ReadingSearchMatch] = []
        if !query.isEmpty {
            for (page, content) in state.book.pages.enumerated() {
                let text = content as NSString
                var start = 0
                while start < text.length {
                    let match = text.range(of: query, options: .caseInsensitive,
                                           range: NSRange(location: start, length: text.length - start))
                    guard match.location != NSNotFound, match.length > 0 else { break }
                    matches.append(ReadingSearchMatch(page: page, range: match))
                    start = NSMaxRange(match)
                }
            }
        }
        readingMatchIndex = nil
        readingMatches = matches
        readingSearchCompleted = !query.isEmpty
        if !matches.isEmpty { showReadingMatch(0) }
    }

    private func showReadingMatch(_ index: Int) {
        guard readingMatches.indices.contains(index) else { return }
        let match = readingMatches[index]
        state.turnReadingPage(section: match.page, offset: match.range.location)
        if state.book.page == match.page { readingMatchIndex = index }
    }

    private var readingSearchBar: some View {
        HStack {
            TextField("搜索当前书籍", text: $readingQuery)
                .focused($readingSearchFocused)
                .onSubmit(findInBook)
                .onChange(of: readingQuery) {
                    readingMatchIndex = nil
                    readingMatches = []
                    readingSearchCompleted = false
                }
            Button("搜索", action: findInBook)
            if let index = readingMatchIndex {
                Text("\(index + 1) / \(readingMatches.count)").monospacedDigit().foregroundStyle(muted)
            } else if readingSearchCompleted && readingMatches.isEmpty {
                Text("没有匹配").foregroundStyle(muted)
            }
            Button { showReadingMatch((readingMatchIndex ?? 0) - 1) } label: {
                Label("上一处", systemImage: "chevron.up")
            }.labelStyle(.iconOnly).disabled((readingMatchIndex ?? 0) == 0)
            Button { showReadingMatch((readingMatchIndex ?? 0) + 1) } label: {
                Label("下一处", systemImage: "chevron.down")
            }.labelStyle(.iconOnly).disabled((readingMatchIndex ?? 0) + 1 >= readingMatches.count)
            Button { showingReadingSearch = false } label: {
                Label("关闭搜索", systemImage: "xmark")
            }.labelStyle(.iconOnly)
        }.buttonStyle(AppActionButtonStyle())
            .padding(.horizontal, 16).padding(.vertical, 8).background(AppTheme.surface)
    }

    private func reader(inspectorVisible: Bool, compactControls: Bool, toggleInspector: @escaping () -> Void) -> some View {
        let inspectorLabel = inspectorVisible ? "收起右栏" : "展开右栏"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: compactControls ? 5 : 8) {
                HStack(spacing: 6) {
                    Text(state.book.kind).font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(1)
                        .fixedSize()
                    if !compactControls {
                        Text(" / ").foregroundStyle(rule)
                        Text(state.book.title).lineLimit(1).help(state.book.title)
                    }
                }.font(.system(size: 13)).foregroundStyle(muted)
                Spacer(minLength: 0)
                Button { bookInfo = state.book } label: {
                    Label("文档信息", systemImage: "info.circle")
                }.labelStyle(.iconOnly).help("文档信息")
                Button {
                    showingReadingSearch = true
                    readingSearchFocused = true
                } label: {
                    Label("搜索书籍", systemImage: "magnifyingglass")
                }.labelStyle(.iconOnly).keyboardShortcut("f").help("搜索当前书籍")
                if state.textSelection == nil || state.selectedContentLevel == .word {
                    Button(action: state.defineSelection) {
                        readerControl("词典释义", icon: "text.magnifyingglass", compact: compactControls)
                    }.tint(accent).disabled(state.textSelection == nil).help("查询选中文字的离线词典释义")
                }
                if state.canTranslateSelection {
                    Button {
                        if let range = state.textSelection { state.translateSelection(range) }
                    } label: { readerControl("本地翻译", icon: "character.bubble", compact: compactControls) }
                        .tint(accent).help("在本机翻译选中的句子或段落")
                }
                if state.canAnalyzeSelection {
                    Button {
                        if let range = state.textSelection { state.analyzeSelection(range) }
                    } label: { readerControl("长句分析", icon: "text.alignleft", compact: compactControls) }
                        .tint(accent).help("使用已配置的大模型分析句子结构与修饰层级")
                }
                Button(action: state.openChat) {
                    Label("大模型对话", systemImage: "bubble.left.and.bubble.right")
                }.labelStyle(.iconOnly).tint(accent)
                    .disabled(state.textSelection == nil && modelChat.conversations.isEmpty)
                    .help(state.textSelection == nil ? "继续上次的大模型对话" : "与大模型讨论选中文字")
                Button { startNote(book: state.book, range: state.noteSelection) } label: {
                    Label("写笔记", systemImage: "square.and.pencil")
                }.labelStyle(.iconOnly).buttonStyle(AppActionButtonStyle(prominent: true))
                    .help("写笔记，可附上所选原文")
                Menu {
                    Button("小") { state.fontSize = 22 }
                    Button("中") { state.fontSize = 26 }
                    Button("大") { state.fontSize = 30 }
                } label: { Image(systemName: "textformat.size").accessibilityLabel("字号") }
                    .menuStyle(.borderlessButton).fixedSize().help("调整字号")
                Button(action: toggleInspector) {
                    Label(inspectorLabel, systemImage: "sidebar.right")
                }.labelStyle(.iconOnly).help(inspectorLabel)
            }.buttonStyle(AppActionButtonStyle(quiet: true))
                .padding(.horizontal, compactControls ? 8 : 16).frame(minHeight: 56).background(AppTheme.surface)
            Divider().overlay(rule)
            if showingReadingSearch {
                readingSearchBar
                Divider().overlay(rule)
            }
            VStack(alignment: .leading, spacing: 0) {
                if !paginated {
                    Text(state.book.title)
                        .font(.system(size: 26, weight: .medium)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 9)
                }
                Group {
                    if paginated {
                        GeometryReader { geometry in readingText(size: geometry.size) }
                    } else {
                        readingText()
                    }
                }.padding(.leading, -8)
            }.frame(maxWidth: AppTheme.readingMeasure)
                .padding(.horizontal, compactControls ? 20 : 30)
                .padding(.top, AppTheme.readingTopInset).frame(maxWidth: .infinity)
            Divider().overlay(rule)
            HStack {
                pageButton("上一\(paginated ? "页" : state.book.unit)", "chevron.left",
                           currentPagination?.previousOffset != nil || state.book.page > 0, compact: compactControls) {
                    turnPage(forward: false)
                }
                Spacer()
                Menu {
                    ForEach(state.book.pages.indices, id: \.self) { page in
                        Button("第 \(page + 1) \(state.book.unit)") { state.showPage(page) }
                    }
                } label: {
                    Text("第 \(state.book.page + 1) / \(state.book.pages.count) \(state.book.unit)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }.menuStyle(.borderlessButton).fixedSize().help("跳到指定位置")
                if let pagination = currentPagination {
                    Text("页 \(pagination.index + 1) / \(pagination.count)")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
                }
                Spacer()
                pageButton("下一\(paginated ? "页" : state.book.unit)", "chevron.right",
                           currentPagination?.nextOffset != nil || state.book.page + 1 < state.book.pages.count, compact: compactControls) {
                    turnPage(forward: true)
                }
            }.padding(.horizontal, 16).frame(height: 54).background(AppTheme.surface)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func readerControl(_ label: String, icon: String, compact: Bool) -> some View {
        if compact {
            Label(label, systemImage: icon).labelStyle(.iconOnly)
        } else {
            Label(label, systemImage: icon).fixedSize()
        }
    }

    func pageButton(_ label: String, _ icon: String, _ enabled: Bool, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            readerControl(label, icon: icon, compact: compact)
        }.buttonStyle(AppActionButtonStyle()).help(label).disabled(!enabled)
    }

    var inspector: some View {
        Group {
            if modelChat.isPresented {
                ModelChatView(chat: modelChat, preferences: state.preferences, fontSize: definitionFontSize,
                              returnTitle: sentenceAnalysis.source != nil || translation.source != nil ? "返回阅读结果" : "返回词典")
            } else if sentenceAnalysis.source != nil {
                SentenceAnalysisView(analysis: sentenceAnalysis, fontSize: definitionFontSize,
                                     discuss: discussSource(sentenceAnalysis.source))
            } else if translation.source != nil {
                LocalTranslationResultView(translation: translation, fontSize: definitionFontSize,
                                            discuss: discussSource(translation.source))
            } else {
                dictionaryInspector
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.surface)
    }

    private func discussSource(_ source: String?) -> (() -> Void)? {
        guard let source, let range = state.textSelection,
              TranslationModel.selectedText(range, in: state.book.pages[state.book.page]) == source else { return nil }
        return { state.chatSelection(range, preservingResult: true) }
    }

    var dictionaryInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("词义与出处", systemImage: "text.magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                .padding(.horizontal, 21).frame(height: 56)
            Divider().overlay(rule)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let lookup = state.lookup {
                        occurrence(lookup.occurrence)
                        HStack {
                            if lookup.definition.source == nil {
                                Button("AI 语境释义", action: state.retryLookup)
                                    .buttonStyle(AppActionButtonStyle(prominent: true))
                                    .disabled(state.querying)
                            } else {
                                Button("重新释义", action: state.regenerateLookup)
                                    .buttonStyle(AppActionButtonStyle())
                                    .disabled(state.querying)
                            }
                            Button("追问") { state.chatSelection(lookup.range) }
                                .buttonStyle(AppActionButtonStyle())
                        }
                        if state.querying {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在查询语境释义…").font(.system(size: max(13, definitionFontSize - 3))).foregroundStyle(muted)
                                Spacer()
                                Button("停止", action: state.stopLookup).buttonStyle(AppActionButtonStyle())
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
                            Text("已读取这条原句的语境释义")
                                .font(.system(size: max(12, definitionFontSize - 4))).foregroundStyle(muted)
                        }
                        if let warning = state.cacheWarning {
                            Text(warning).font(.system(size: max(12, definitionFontSize - 4))).foregroundStyle(muted)
                        }
                        definition(lookup.definition, showMissingMeaning: !state.querying && state.lookupFailure == nil,
                                   selectedWord: lookup.occurrence.context.word)
                        let added = state.contains(lookup)
                        Button { state.save(lookup) } label: {
                            Label(added ? "已保存这条例句" : state.hasSavedExample(lookup) ? "更新这条例句" : "加入生词本", systemImage: added ? "checkmark" : "bookmark")
                                .font(.system(size: 14, weight: .semibold)).padding(11).frame(maxWidth: .infinity)
                                .foregroundStyle(added ? accent : .white)
                                .background(added ? tintWash : accent, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(added || state.querying)
                        if added {
                            Button("在生词本中查看") {
                                state.selectedWord = lookup.key
                                state.inNotebook = true
                            }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                        }
                    } else {
                        Text("在原句里学日语").font(.system(size: 25, weight: .semibold))
                        Text("选中单词，查看原句和释义。遇到难句时，选中完整句子即可翻译、分析或追问。")
                            .font(.system(size: 18)).foregroundStyle(muted).lineSpacing(6)
                        if state.book.kind == "示例", state.book.page == 0,
                           let range = state.book.pages[0].range(of: "喫茶店") {
                            Button { state.choose(NSRange(range, in: state.book.pages[0]).location) } label: {
                                Label("试查「喫茶店」", systemImage: "arrow.up.left").font(.system(size: 14, weight: .semibold))
                            }.buttonStyle(AppActionButtonStyle(prominent: true))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(21)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum DictionaryParagraph {
        case text(String)
        case heading(String)
        case sense(String, [DictionaryParagraph])
        case meaning(japanese: String, chinese: String)
        case examples([(japanese: String, chinese: String)])

        static func parse(_ text: String) -> [Self] {
            guard text.range(of: "(?m)^(?:[①-⑳㉑-㉟㊱-㊿◯]$|▲[ \t]*「|/[^\\S\n]+\\S)", options: .regularExpression) != nil else {
                return [.text(text)]
            }
            let lines = text.components(separatedBy: "\n")
            var result: [Self] = []
            var content: [Self] = []
            var label: String?
            var prose: [String] = []
            var examples: [(japanese: String, chinese: String)] = []

            func flushProse() {
                if !prose.isEmpty { content.append(.text(prose.joined(separator: "\n"))); prose.removeAll() }
            }
            func flushExamples() {
                if !examples.isEmpty { content.append(.examples(examples)); examples.removeAll() }
            }
            func finishSection() {
                flushProse()
                flushExamples()
                if let label, !content.isEmpty { result.append(.sense(label, content)) }
                else {
                    if let label, label != "释义" { result.append(.text(label)) }
                    result.append(contentsOf: content)
                }
                content.removeAll()
                label = nil
            }

            // The saved Meikyo text retains its sense numbers, slash-prefixed glosses and example markers.
            var index = 0
            while index < lines.count {
                let line = lines[index]
                let next = index + 1 < lines.count ? lines[index + 1] : ""
                let example = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    finishSection()
                } else if line.range(of: "^(?:[①-⑳㉑-㉟㊱-㊿◯]|5[1-9])$", options: .regularExpression) != nil {
                    finishSection()
                    label = line == "◯" ? "释义" : "义项 \(line)"
                } else if line.range(of: "^（[一二三四五六七八九十]+）", options: .regularExpression) != nil {
                    finishSection()
                    result.append(.heading(line))
                } else if line.hasPrefix("▲"), example.hasPrefix("「"), example.hasSuffix("」"),
                          !next.isEmpty, !next.hasPrefix("▲") {
                    flushProse()
                    examples.append((example, next))
                    index += 1
                } else if next.range(of: "^/\\s+\\S", options: .regularExpression) != nil {
                    if label == nil { finishSection(); label = "释义" }
                    flushExamples()
                    flushProse()
                    content.append(.meaning(japanese: line, chinese: next.dropFirst().trimmingCharacters(in: .whitespaces)))
                    index += 1
                } else {
                    flushExamples()
                    prose.append(line)
                }
                index += 1
            }
            finishSection()
            return result
        }
    }

    private var chineseDefinitionColor: Color { Color(red: 0.09, green: 0.32, blue: 0.27) }

    private func dictionaryLanguage(_ label: String, text: String, chinese: Bool) -> some View {
        let color = chinese ? chineseDefinitionColor : ink
        let badgeColor = chinese ? chineseDefinitionColor : accent
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12, weight: .bold))
                .foregroundStyle(badgeColor)
                .frame(width: 24)
                .padding(.vertical, 3)
                .background(badgeColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                .fixedSize()
                .accessibilityLabel(chinese ? "中文释义" : "日文释义")
            Text(text).font(.system(size: definitionFontSize, weight: chinese ? .medium : .regular))
                .foregroundStyle(color).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func dictionaryParagraph(_ paragraph: DictionaryParagraph) -> some View {
        switch paragraph {
        case .text(let text):
            Text(text).font(.system(size: definitionFontSize)).lineSpacing(5)
        case .heading(let text):
            Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
        case .meaning(let japanese, let chinese):
            VStack(alignment: .leading, spacing: 10) {
                dictionaryLanguage("日", text: japanese, chinese: false)
                dictionaryLanguage("中", text: chinese, chinese: true)
            }
        case .examples(let examples):
            VStack(alignment: .leading, spacing: 9) {
                Text("例句").font(.system(size: 12, weight: .semibold)).foregroundStyle(muted)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(examples.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(examples[index].japanese).font(.system(size: definitionFontSize))
                            Text(examples[index].chinese)
                                .font(.system(size: max(13, definitionFontSize - 3)))
                                .foregroundStyle(chineseDefinitionColor)
                        }.lineSpacing(4)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(rule).frame(width: 2) }
            }
        case .sense:
            EmptyView()
        }
    }

    private func importedDictionaryContent(_ text: String) -> some View {
        let paragraphs = DictionaryParagraph.parse(text)
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(paragraphs.indices, id: \.self) { index in
                if case .sense(let label, let content) = paragraphs[index] {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                        ForEach(content.indices, id: \.self) { dictionaryParagraph(content[$0]) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(rule) }
                } else {
                    dictionaryParagraph(paragraphs[index])
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }

    func definition(_ value: Definition, showMissingMeaning: Bool = true, selectedWord: String? = nil) -> some View {
        let value = state.dictionary.addingDictionaryEnglish(to: value)
        let displayedHead = value.source == nil ? value.head : (selectedWord ?? value.head)
        let headword = Text(displayedHead)
            .font(.system(size: definitionFontSize + 12, weight: .medium)).textSelection(.enabled)
        let moji = Button {
            Task { @MainActor in
                do { try await MOJiSearch().open(word: displayedHead) }
                catch { state.failure = error.localizedDescription }
            }
        } label: {
            Text("moji 词典").underline().font(.system(size: 13)).foregroundStyle(accent)
        }
        .buttonStyle(.link)
        .fixedSize()
        .help("优先打开 MOJi 客户端，无法打开时使用浏览器搜索")
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    headword.fixedSize(horizontal: true, vertical: false)
                    moji
                }
                VStack(alignment: .leading, spacing: 4) {
                    headword
                    moji
                }
            }
            if value.source == nil && !value.reading.isEmpty && value.reading != displayedHead {
                Text(value.reading).font(.system(size: definitionFontSize + 2)).foregroundStyle(accent).textSelection(.enabled)
            }
            modelDefinitionContent(value, reading: value.reading == displayedHead ? nil : value.reading,
                                   surface: displayedHead)
            localDefinitionContent(value)
            if let name = value.dictionaryName {
                Text("本地词典 · \(name)").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent).padding(.top, 4)
                if let text = value.dictionaryText {
                    importedDictionaryContent(text)
                }
            }
            if value.source == nil, let etymology = value.etymology {
                Text("外来语词源").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent).padding(.top, 4)
                Text(etymology).font(.system(size: definitionFontSize)).lineSpacing(6).textSelection(.enabled)
            }
            if !value.hasMeaning && showMissingMeaning {
                Text("词典中暂未找到释义。")
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

    private func startNote(book: Book, range: NSRange? = nil) {
        let text = book.pages[book.page]
        let excerpt = range.flatMap { Range($0, in: text) }.map { String(text[$0]) }
        noteDraft = ReadingNote(bookID: book.id, page: book.page, excerpt: excerpt, body: "")
    }

    private func readingRecords(isHistory: Bool) -> some View {
        let bookID = isHistory ? historyBookID : notesBookID
        let book = state.library.books.first { $0.id == bookID } ?? state.activeBook ?? state.library.books[0]
        let query = notesQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = isHistory ? [] : state.library.notes.filter { note in
            if query.isEmpty { return note.bookID == book.id }
            return note.body.localizedCaseInsensitiveContains(query)
                || note.excerpt?.localizedCaseInsensitiveContains(query) == true
        }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(isHistory ? "历史记录" : "笔记本").font(.system(size: 23, weight: .semibold))
                    Spacer()
                    if !isHistory {
                        TextField("搜索全部笔记", text: $notesQuery).frame(maxWidth: 240)
                        Button { startNote(book: book) } label: {
                            Label("新建笔记", systemImage: "plus")
                        }.buttonStyle(AppActionButtonStyle(prominent: true))
                    }
                }
                if isHistory {
                    AppOptionButtons(title: "记录类型", options: HistorySection.allCases,
                                     selection: $historySection) { $0.rawValue }
                        .frame(maxWidth: 300)
                }
            }.padding(20).background(AppTheme.surface)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(state.library.books) { item in
                            nav(item.title, "book", selected: item.id == book.id,
                                count: isHistory ? historyCount(bookID: item.id)
                                    : state.library.notes.filter { $0.bookID == item.id }.count) {
                                if isHistory {
                                    historyBookID = item.id
                                } else {
                                    notesBookID = item.id
                                    notesQuery = ""
                                }
                            }
                        }
                    }.padding(12)
                }.frame(width: 208).background(rail)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if isHistory {
                            Text(book.title).font(.title2)
                            bookHistory(book)
                        } else {
                            Text(query.isEmpty ? book.title : "搜索结果").font(.title2)
                            if notes.isEmpty {
                                Text(query.isEmpty ? "这本书还没有笔记。" : "没有匹配的笔记。").foregroundStyle(muted)
                            }
                            ForEach(notes) { note in
                                if let source = state.library.books.first(where: { $0.id == note.bookID }) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack {
                                            if !query.isEmpty { Text(source.title).foregroundStyle(muted).lineLimit(1) }
                                            Button("第 \(note.page + 1) \(source.unit)") {
                                                state.openBook(source.id, page: note.page)
                                            }.help("返回原文")
                                            Spacer()
                                            Button("编辑") { noteDraft = note }
                                            Button("删除") { noteToDelete = note }
                                        }
                                        if let excerpt = note.excerpt {
                                            Text(excerpt).font(.system(size: 22)).lineSpacing(6)
                                                .foregroundStyle(ink).textSelection(.enabled)
                                        }
                                        if note.hasBody {
                                            Text(note.body).textSelection(.enabled)
                                        }
                                    }
                                    Divider()
                                }
                            }
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .confirmationDialog("删除这条记录？", isPresented: Binding(
            get: { historyDeletion != nil }, set: { if !$0 { historyDeletion = nil } }
        ), titleVisibility: .visible, presenting: historyDeletion) { delete in
            Button("删除记录", role: .destructive, action: delete)
        }
    }

    private func historyCount(bookID: UUID) -> Int {
        switch historySection {
        case .analyses: sentenceAnalysis.history.filter { $0.bookID == bookID }.count
        case .chats: modelChat.conversations.filter { $0.context.bookID == bookID && !$0.messages.isEmpty }.count
        }
    }

    @ViewBuilder private func bookHistory(_ book: Book) -> some View {
        if historySection == .analyses {
            let entries = sentenceAnalysis.history.filter { $0.bookID == book.id }
            if let warning = sentenceAnalysis.historyWarning { Text(warning).foregroundStyle(muted) }
            if entries.isEmpty {
                historyEmptyState("这本书还没有长句分析记录。", icon: "text.alignleft",
                                  guidance: "在阅读中选中一个完整句子，点「长句分析」。分析完成后，结果会自动出现在这里。", book: book)
            }
            ForEach(entries) { entry in
                historyRow(book: book, page: entry.page, text: entry.text, subtitle: entry.serviceName,
                           actionTitle: "查看分析", open: {
                    if state.openHistorySource(bookID: book.id, page: entry.page, offset: entry.offset) {
                        sentenceAnalysis.show(entry)
                    }
                }, delete: { sentenceAnalysis.delete(entry.id) })
            }
        } else {
            let entries = modelChat.conversations.reversed().filter { $0.context.bookID == book.id && !$0.messages.isEmpty }
            if let warning = modelChat.storageWarning { Text(warning).foregroundStyle(muted) }
            if entries.isEmpty {
                historyEmptyState("这本书还没有对话记录。", icon: "bubble.left.and.bubble.right",
                                  guidance: "在阅读中选中文字，点「大模型对话」并发送问题。对话会自动出现在这里。", book: book)
            }
            ForEach(entries) { entry in
                historyRow(book: book, page: entry.context.page, text: entry.context.selectedText,
                           subtitle: entry.messages.first?.content ?? "", actionTitle: "继续对话", open: {
                    if state.openHistorySource(bookID: book.id, page: entry.context.page, offset: entry.context.offset) {
                        modelChat.show(entry.id)
                    }
                }, delete: { modelChat.delete(entry.id) })
            }
        }
    }

    private func historyEmptyState(_ title: String, icon: String, guidance: String, book: Book) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(guidance)
        } actions: {
            Button("返回阅读") { state.openBook(book.id) }
                .buttonStyle(AppActionButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity)
    }

    private func historyRow(book: Book, page: Int, text: String, subtitle: String, actionTitle: String,
                            open: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("第 \(page + 1) \(book.unit)").foregroundStyle(muted)
                Spacer()
                Button(actionTitle, action: open)
                Button("删除") { historyDeletion = delete }
            }
            Text(text).font(.system(size: 19)).lineLimit(3).textSelection(.enabled)
            Text(subtitle).foregroundStyle(muted).lineLimit(2)
            Divider()
        }
    }

    func notebookDefinition(_ word: SavedWord) -> some View {
        let meanings = state.dictionary.notebookMeanings(for: word)
        let value = word.definition
        if value.dictionaryName != nil { return definition(value, showMissingMeaning: false) }
        return definition(Definition(head: value.head, reading: value.reading, chinese: meanings.chinese,
                                     english: value.english, etymology: value.source == nil ? value.etymology : nil),
                          showMissingMeaning: false)
    }

    @ViewBuilder
    func modelDefinitionContent(_ value: Definition, reading: String? = nil, surface: String? = nil) -> some View {
        if let source = value.source, let chinese = value.chineseMeaning {
            let legacy = chinese.split(separator: "\n", maxSplits: 1).map(String.init)
            let note = value.modelNote ?? (legacy.count == 2 ? legacy[1] : "")
            let meaning = value.modelNote == nil ? (legacy.first ?? chinese)
                : (!note.isEmpty && chinese.hasSuffix("\n" + note) ? String(chinese.dropLast(note.count + 1)) : chinese)
            VStack(alignment: .leading, spacing: 10) {
                Text("大模型释义").font(.system(size: 15, weight: .bold))
                Text("中文语境释义").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                Text(meaning).font(.system(size: definitionFontSize, weight: .semibold))
                    .lineSpacing(6).textSelection(.enabled)
                if let surface, surface != value.head {
                    let kana = value.reading.isEmpty || value.reading == value.head ? "" : "（\(value.reading)）"
                    definitionDetail("基本形", text: value.head + kana)
                } else if let reading, !reading.isEmpty {
                    definitionDetail("读音", text: reading)
                }
                if !note.isEmpty { definitionDetail("补充说明", text: note) }
                if let etymology = value.etymology, !etymology.isEmpty {
                    definitionDetail("词源", text: etymology)
                }
                if !source.isEmpty {
                    Text("AI · \(source)").font(.system(size: 12)).foregroundStyle(muted)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(tintWash.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func localDefinitionContent(_ value: Definition) -> some View {
        let tags = state.dictionary.partsOfSpeech(for: value)
        let chinese = value.source == nil ? value.chineseMeaning : nil
        if !tags.isEmpty || value.english != nil || chinese != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("本地词典").font(.system(size: 15, weight: .bold))
                if let english = value.english { definitionDetail("英文释义 · JMdict", text: english, emphasized: true) }
                if !tags.isEmpty { definitionDetail("词性 · JMdict", text: tags.map(\.label).joined(separator: " · ")) }
                if let chinese { definitionDetail("内置中文释义", text: chinese, emphasized: true) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(rule) }
        }
    }

    private func definitionDetail(_ title: String, text: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
            Text(text).font(.system(size: emphasized ? definitionFontSize : max(14, definitionFontSize - 2),
                                    weight: emphasized ? .semibold : .regular)).lineSpacing(5).textSelection(.enabled)
        }
    }

    func occurrence(_ example: Occurrence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("原句").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
            sentence(example.context).font(.system(size: definitionFontSize)).lineSpacing(6).textSelection(.enabled)
            Divider().overlay(rule)
            Label(state.library.books.first { $0.id == example.bookID }?.title ?? example.filename,
                  systemImage: "doc.text").font(.system(size: 13, weight: .medium))
                .foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text(example.location).font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(rule) }
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
                }.buttonStyle(AppActionButtonStyle(prominent: true)).disabled(state.library.words.isEmpty)
            }.padding(.horizontal, 24).padding(.vertical, 18).background(AppTheme.surface)
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
                                modelDefinitionContent(word.definition)
                                ForEach(word.examples) { example in
                                    VStack(alignment: .leading, spacing: 8) {
                                        if let savedDefinition = example.definition, savedDefinition != word.definition {
                                            if savedDefinition.source == nil {
                                                definition(savedDefinition, showMissingMeaning: false)
                                            } else {
                                                modelDefinitionContent(savedDefinition)
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

private struct BookInfoEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var metadata: BookMetadata
    let book: Book
    let count: Int
    let save: (BookMetadata) -> Bool

    init(book: Book, save: @escaping (BookMetadata) -> Bool) {
        self.book = book
        self.save = save
        count = book.characterCount
        _metadata = ViewState(initialValue: book.metadata ?? BookMetadata())
    }

    private func field(_ key: WritableKeyPath<BookMetadata, String?>) -> Binding<String> {
        Binding(get: { metadata[keyPath: key] ?? "" }, set: { metadata[keyPath: key] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("文档信息").font(.title2.bold())
            Form {
                TextField("书名", text: field(\.title), prompt: Text(book.filenameTitle))
                TextField("作者", text: field(\.author), prompt: Text("未提供"))
                TextField("出版社", text: field(\.publisher), prompt: Text("未提供"))
                TextField("出版日期", text: field(\.published), prompt: Text("例如 2024-05"))
                LabeledContent("正文总字数", value: count.formatted())
                LabeledContent("文档格式", value: book.kind)
                LabeledContent("\(book.unit)数", value: book.pages.count.formatted())
                LabeledContent("源文件名") { Text(book.name).textSelection(.enabled) }
            }
            Text("字数包含文字、字母和数字。").font(.caption).foregroundStyle(muted)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    let cleaned = BookMetadata(title: metadata.title, author: metadata.author,
                                               publisher: metadata.publisher, published: metadata.published)
                    if save(cleaned) { dismiss() }
                }.buttonStyle(AppActionButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 460).background(paper).tint(accent)
    }
}

private struct ReadingNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState var note: ReadingNote
    let book: Book?
    let save: (ReadingNote) -> Bool
    @FocusState private var editing: Bool
    @ViewState private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("笔记").font(.title2)
            if let book {
                Text("\(book.title) · 第 \(note.page + 1) \(book.unit)").foregroundStyle(muted)
            }
            if let excerpt = note.excerpt {
                ScrollView {
                    Text(excerpt).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(muted).textSelection(.enabled)
                }.frame(maxHeight: 96)
            }
            Text(note.hasExcerpt ? "笔记正文（可选）" : "笔记正文").foregroundStyle(muted)
            TextEditor(text: $note.body)
                .font(.body).focused($editing).accessibilityLabel("笔记正文")
                .frame(minHeight: 160).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(rule))
            if saveFailed { Text("保存失败，请重试。").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if save(note) { dismiss() }
                    else { saveFailed = true }
                }.keyboardShortcut(.defaultAction)
                    .disabled(!note.hasBody && !note.hasExcerpt)
            }
        }.padding(24).frame(width: 480).onAppear { editing = true }
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
    private enum Tab: String, CaseIterable {
        case reading = "阅读显示", model = "大模型", translation = "本地翻译"
    }
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
            AppOptionButtons(title: "设置类别", options: Tab.allCases, selection: $tab) { $0.rawValue }
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
                Section("本地词典") {
                    Picker("释义词典", selection: Binding(get: { state.selectedDictionary }, set: state.selectDictionary)) {
                        Text("内置词典").tag(nil as UUID?)
                        ForEach(state.dictionaryCatalog.dictionaries) { info in
                            Text(info.name).tag(Optional(info.id))
                        }
                    }.disabled(state.updatingDictionaries)
                    Button("导入词典…", action: state.importDictionary).disabled(state.updatingDictionaries)
                    if state.updatingDictionaries { ProgressView().controlSize(.small) }
                    if let message = state.dictionaryMessage {
                        Text(message).font(AppTheme.captionFont).foregroundStyle(.red)
                    }
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
        .padding(24).font(AppTheme.interfaceFont).frame(width: 680, height: tab == .reading ? 510 : 680)
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
        Window("读解", id: "main") {
            ReaderView(state: state, translation: state.translation, sentenceAnalysis: state.sentenceAnalysis, modelChat: state.modelChat)
        }
            .defaultSize(width: 1180, height: 740)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("导入文件…", action: state.importBook).keyboardShortcut("o")
                }
                CommandMenu("阅读") {
                    Button("大模型释义", action: state.defineSelectedWordWithModel)
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                        .disabled(!state.canDefineModelSelection)
                }
            }
        Settings { DefinitionSettingsView(state: state, preferences: state.preferences, translation: state.translation) }
    }
}
