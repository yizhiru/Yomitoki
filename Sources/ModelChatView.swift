import SwiftUI

struct ModelChatView: View {
    @ObservedObject var chat: ModelChatState
    @ObservedObject var preferences: DefinitionPreferences
    let fontSize: Double
    var returnTitle = "返回词典"
    @FocusState private var composing: Bool
    private let accent = AppTheme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("大模型对话", systemImage: "bubble.left.and.bubble.right").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Menu {
                    ForEach(chat.conversations.reversed()) { conversation in
                        Button { chat.show(conversation.id) } label: {
                            Text(String(conversation.context.selectedText.prefix(18)).replacingOccurrences(of: "\n", with: " ")
                                 + " · " + String(conversation.context.filename.prefix(14)) + " · " + conversation.context.location)
                            if conversation.id == chat.activeID { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    Button("清空当前对话", role: .destructive, action: chat.clearCurrent)
                } label: { Image(systemName: "clock.arrow.circlepath").accessibilityLabel("对话记录") }
                    .menuStyle(.borderlessButton).fixedSize().help("切换对话记录或清空当前对话")
                Button(returnTitle, action: chat.dismiss).buttonStyle(AppActionButtonStyle())
            }.padding(.horizontal, 18).frame(height: 52)
            Divider()
            if let conversation = chat.current {
                context(conversation.context).padding(16)
                Divider()
                transcript(conversation)
                Divider()
                composer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).font(AppTheme.interfaceFont).tint(accent)
        .onAppear { composing = true }
        .onChange(of: chat.activeID) { _, _ in composing = true }
    }

    private func context(_ context: ModelChatContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("讨论选文").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
            DisclosureGroup {
                ScrollView {
                    Text(context.selectedText).font(.system(size: 15)).lineSpacing(5)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }.frame(maxHeight: 150)
            } label: {
                Text(context.selectedText).font(.system(size: 14)).lineLimit(2)
            }
            Text("\(context.filename) · \(context.location)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func transcript(_ conversation: ModelChatConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if conversation.messages.isEmpty {
                        Text("可以询问词义、语法、翻译，或围绕选文自由追问。")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                        ForEach(["解释这段文字", "这里的语法怎么理解？", "翻译成自然的中文"], id: \.self) { suggestion in
                            Button(suggestion) { chat.draft = suggestion; composing = true }
                                .buttonStyle(AppActionButtonStyle())
                        }
                    }
                    ForEach(conversation.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message.role == .user ? "你" : "AI · \(message.serviceName ?? "大模型")")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            Text(message.role == .assistant
                                 ? ((try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.content))
                                 : AttributedString(message.content))
                                .font(.system(size: fontSize)).lineSpacing(6).textSelection(.enabled)
                            if message.truncated {
                                Text("回复达到长度上限，可继续追问「请继续」。").font(AppTheme.captionFont).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(message.role == .user ? AppTheme.surface : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                    if chat.sending {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在回复…").font(.system(size: 14))
                            Spacer()
                            Button("停止", action: chat.stop).font(.system(size: 14))
                        }
                    }
                    if let failure = chat.failure {
                        Text(failure).font(.system(size: 14)).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if chat.waitingForReply && !chat.sending {
                        HStack {
                            Button("重试") { chat.retry(settings: preferences.settings) }
                            Button("修改问题") { chat.editQuestion(); composing = true }
                            SettingsLink { Text("模型设置") }
                        }.font(.system(size: 14))
                    }
                    if let warning = chat.storageWarning {
                        Text(warning).font(AppTheme.captionFont).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: chat.sending) { _, _ in
                withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
        }.id(conversation.id)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("针对选文提问，或继续追问…", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(2...6)
                .padding(10).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .focused($composing).disabled(chat.sending || chat.waitingForReply)
            HStack {
                Text("⌘↩ 发送").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("\(chat.draft.count)/\(ModelChatAPI.maximumQuestion)").font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(chat.draft.count > ModelChatAPI.maximumQuestion ? .red : .secondary)
                Button("发送") { chat.send(settings: preferences.settings) }
                    .buttonStyle(AppActionButtonStyle(prominent: true)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!chat.canSend || chat.draft.count > ModelChatAPI.maximumQuestion)
            }
            HStack(alignment: .top) {
                Text("\(preferences.settings.serviceName) · \(preferences.settings.model)\n发送选文、附近原文及对话，按 API 账户计费。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                SettingsLink { Image(systemName: "gearshape").accessibilityLabel("大模型设置") }
                    .buttonStyle(.plain).help("配置对话所用的模型和 API key")
            }
        }.padding(14)
    }
}
