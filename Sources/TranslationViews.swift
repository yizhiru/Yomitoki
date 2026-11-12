import AppKit
import SwiftUI

struct LocalTranslationSettingsContent: View {
    @ObservedObject var translation: LocalTranslation

    var body: some View {
        Section("翻译模型") {
            Text(TranslationModel.name).font(.headline)
            Text("选中日语句子或段落后点击「本地翻译」，在本机生成中文。无需 API key，原文不会发送到远程翻译服务。")
                .font(AppTheme.captionFont).foregroundStyle(.secondary)
            Text("模型约 1.13 GB，两个下载源提供同一份模型，下载后保存在本机。")
                .font(AppTheme.captionFont).foregroundStyle(.secondary)
            Picker("下载源", selection: Binding(get: { translation.configuration.downloadMirror },
                                              set: translation.selectDownloadMirror)) {
                ForEach(TranslationMirror.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(translation.preparingModel)
            HStack {
                Button("快速测速", action: translation.testDownloadMirrors)
                    .disabled(translation.preparingModel || translation.testingMirrors)
                if translation.testingMirrors {
                    ProgressView().controlSize(.small)
                    Button("取消测速", action: translation.cancelMirrorTesting)
                }
            }
            ForEach(TranslationMirror.allCases, id: \.self) { mirror in
                HStack {
                    Text(mirror.title)
                    Spacer()
                    switch translation.mirrorSpeeds[mirror] {
                    case .testing: Text("测速中…")
                    case .measured(let speed):
                        Text(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s（短测）")
                            .monospacedDigit()
                    case .unavailable: Text("暂无法测速")
                    case nil: Text("未测速")
                    }
                }.font(AppTheme.captionFont).foregroundStyle(.secondary)
            }
            Text("主动测速会依次下载两个 4 MB 片段，每个源最多等待 8 秒。短测含连接耗时，仅供选源参考。")
                .font(AppTheme.captionFont).foregroundStyle(.secondary)
            HStack {
                Button("下载 Q4 模型") { translation.prepareModel() }
                    .disabled(translation.preparingModel || translation.testingMirrors)
                Button("选择已有模型…", action: translation.chooseModel).disabled(translation.preparingModel)
                Link("所选镜像页面", destination: translation.configuration.downloadMirror.homepage)
                Link("官方来源", destination: TranslationModel.officialHomepage)
            }
            if translation.preparingModel {
                VStack(alignment: .leading, spacing: 8) {
                    if let progress = translation.downloadProgress {
                        ProgressView(value: progress.fractionCompleted)
                            .progressViewStyle(.linear).frame(maxWidth: .infinity)
                        HStack {
                            Text(progress.byteCountDescription).monospacedDigit()
                            Spacer()
                            Text(progress.fractionCompleted, format: .percent.precision(.fractionLength(1))).monospacedDigit()
                            Button("取消", action: translation.cancelModelPreparation)
                        }.font(AppTheme.captionFont)
                    } else {
                        HStack {
                            ProgressView().controlSize(.small)
                            Button("取消", action: translation.cancelModelPreparation)
                        }
                    }
                }
            }
            if let status = translation.modelStatus { Text(status).font(AppTheme.captionFont).foregroundStyle(.secondary) }
            if !translation.configuration.modelPath.isEmpty {
                Text(translation.configuration.modelPath).font(AppTheme.captionFont).foregroundStyle(.secondary).textSelection(.enabled)
                Button("在 Finder 中显示模型") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: translation.configuration.modelPath)])
                }
            } else { Text("尚未选择模型").font(AppTheme.captionFont).foregroundStyle(.secondary) }
        }
        Section("本地引擎") {
            if TranslationEngine.isAvailable {
                Label("翻译引擎已内置", systemImage: "checkmark.circle")
                Text("下载或选择模型后即可翻译，无需安装其他软件。引擎随 App 更新。")
                    .font(AppTheme.captionFont).foregroundStyle(.secondary)
            } else {
                Text("内置翻译引擎缺失，请重新安装完整的读解 App。")
                    .font(AppTheme.captionFont).foregroundStyle(.red)
            }
            Text("首次翻译需加载模型，后续会复用。Apple Silicon Mac 建议至少 8 GB 内存；速度取决于设备和选文长度。")
                .font(AppTheme.captionFont).foregroundStyle(.secondary)
            Button("释放模型内存", action: translation.stopRuntime)
        }
        if let failure = translation.setupFailure {
            Section { Text(failure).font(AppTheme.captionFont).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}

struct LocalTranslationResultView: View {
    @ObservedObject var translation: LocalTranslation
    let fontSize: Double
    var discuss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("本地翻译", systemImage: "character.bubble").font(.system(size: 14, weight: .semibold))
                Spacer()
                if let discuss { Button("追问", action: discuss).buttonStyle(AppActionButtonStyle()) }
                Button("返回词典", action: translation.clear).font(.system(size: 13))
            }.padding(.horizontal, 21).frame(height: 52)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("日语原文").font(.system(size: 14, weight: .semibold))
                    Text(translation.source ?? "").font(.system(size: fontSize))
                        .lineSpacing(7).textSelection(.enabled)
                    Divider()
                    Text(TranslationModel.name).font(.system(size: 13)).foregroundStyle(.secondary)
                    if translation.translating {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在加载模型并翻译…").font(.system(size: 15))
                        }
                        Text("首次加载可能需要一些时间。").font(AppTheme.captionFont).foregroundStyle(.secondary)
                        Button("取消翻译") { translation.clear() }
                    }
                    if let result = translation.result {
                        Text("中文译文").font(.system(size: 14, weight: .semibold))
                        Text(result).font(.system(size: fontSize)).lineSpacing(7).textSelection(.enabled)
                        if translation.reused { Text("已读取本地缓存").font(AppTheme.captionFont).foregroundStyle(.secondary) }
                        Button("重新翻译", action: translation.retry)
                    }
                    if let failure = translation.failure {
                        Text(failure).font(.system(size: 15)).foregroundStyle(.red).textSelection(.enabled)
                        HStack {
                            Button("重试", action: translation.retry)
                            SettingsLink { Text("打开设置") }
                        }
                    }
                    if let warning = translation.cacheWarning {
                        Text(warning).font(AppTheme.captionFont).foregroundStyle(.secondary)
                    }
                    Text("机器翻译仅供阅读参考。").font(AppTheme.captionFont).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(21)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).font(AppTheme.interfaceFont)
    }
}
