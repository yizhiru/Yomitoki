import SwiftUI

struct SentenceAnalysisView: View {
    @ObservedObject var analysis: SentenceAnalysisState
    let fontSize: Double
    var discuss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("长句分析", systemImage: "text.alignleft").font(.system(size: 14, weight: .semibold))
                Spacer()
                if let discuss { Button("追问", action: discuss).buttonStyle(AppActionButtonStyle()) }
                Button("返回词典", action: analysis.clear).font(.system(size: 13))
            }.padding(.horizontal, 21).frame(height: 52)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("日语原文", text: analysis.source ?? "")
                    Divider()
                    Text("AI · \(analysis.serviceName)").font(.system(size: 13)).foregroundStyle(.secondary)
                    if analysis.analyzing {
                        HStack { ProgressView().controlSize(.small); Text("正在分析句子结构…").font(.system(size: 15)) }
                        Button("取消分析", action: analysis.clear)
                    }
                    if let result = analysis.result {
                        section("中文译文", text: result.translation)
                        section("主干结构", text: result.mainStructure)
                        if !result.modifiers.isEmpty { items("修饰层级", values: result.modifiers) }
                        VStack(alignment: .leading, spacing: 10) {
                            heading("结构嵌套图解")
                            Text("可横向滚动查看完整图解").font(AppTheme.captionFont).foregroundStyle(.secondary)
                            ScrollView(.horizontal) {
                                Text(result.diagram)
                                    .font(.system(size: max(13, fontSize - 3), design: .monospaced))
                                    .lineSpacing(4).textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: true).padding(12)
                            }.background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                        if !result.grammarPoints.isEmpty { items("语法难点", values: result.grammarPoints) }
                        if !result.notes.isEmpty { section("补充说明", text: result.notes) }
                        if analysis.reused { Text("已读取本地分析缓存").font(AppTheme.captionFont).foregroundStyle(.secondary) }
                        if analysis.canRetry { Button("重新分析", action: analysis.retry) }
                    }
                    if let failure = analysis.failure {
                        Text(failure).font(.system(size: 15)).foregroundStyle(.red).textSelection(.enabled)
                        HStack { Button("重试", action: analysis.retry); SettingsLink { Text("大模型设置") } }
                    }
                    if let warning = analysis.cacheWarning { Text(warning).font(AppTheme.captionFont).foregroundStyle(.secondary) }
                    if let warning = analysis.historyWarning { Text(warning).font(AppTheme.captionFont).foregroundStyle(.secondary) }
                    Text("使用「设置 → 大模型」中的 API 服务，按服务商规则计费。AI 分析可能存在错误。")
                        .font(AppTheme.captionFont).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(21)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).font(AppTheme.interfaceFont)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .semibold))
    }
    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(title)
            Text(text).font(.system(size: fontSize)).lineSpacing(7).textSelection(.enabled)
        }
    }
    private func items(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(title)
            ForEach(Array(values.enumerated()), id: \.offset) { item in
                Text("\(item.offset + 1). \(item.element)").font(.system(size: fontSize)).lineSpacing(7).textSelection(.enabled)
            }
        }
    }
}
