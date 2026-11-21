import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

private enum Tone {
    static let base = Color(red: 0.082, green: 0.090, blue: 0.099)
    static let panel = Color(red: 0.105, green: 0.115, blue: 0.125)
    static let field = Color(red: 0.157, green: 0.170, blue: 0.183)
    static let line = Color.white.opacity(0.10)
    static let muted = Color(white: 0.68)
    static let mint = Color(red: 0.54, green: 0.88, blue: 0.74)
    static let ink = Color(red: 0.058, green: 0.148, blue: 0.113)
    static let cursor = Color(red: 1.0, green: 0.71, blue: 0.49)
}

private func clockText(_ seconds: Double, precise: Bool = false) -> String {
    guard seconds.isFinite else { return "00:00" }
    let time = Int((max(0, seconds) * 1000).rounded())
    let whole = time / 1000
    let base = whole >= 3600
        ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
        : String(format: "%02d:%02d", whole / 60, whole % 60)
    return precise ? base + String(format: ".%03d", time % 1000) : base
}

private struct ToolButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9).frame(height: 28)
            .foregroundStyle(active ? Tone.ink : Color.primary)
            .background(active ? Tone.mint : Tone.field, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.70 : 1)
    }
}

private struct IconControl: View {
    var symbol: String
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).help(title).accessibilityLabel(title)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    var player: AVPlayer
    final class Surface: NSView {
        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            (layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { nil }
    }
    func makeNSView(context: Context) -> Surface { Surface(frame: .zero) }
    func updateNSView(_ view: Surface, context: Context) {
        if let layer = view.layer as? AVPlayerLayer, layer.player !== player {
            layer.player = player
        }
    }
    static func dismantleNSView(_ view: Surface, coordinator: ()) {
        (view.layer as? AVPlayerLayer)?.player = nil
    }
}

private final class TimelinePreferences: ObservableObject {
    @Published var fileHover = false
    @Published var zoom: CGFloat = 1
}

private enum PassthroughEligibility {
    case eligible
    case ineligible(String, keyframeSelection: Segment?)
}

private final class PassthroughCheck: ObservableObject {
    @Published var result: (segments: [Segment], eligibility: PassthroughEligibility)?
}

private struct PassthroughRequest: Equatable {
    let segments: [Segment]
    let enabled: Bool
}

struct WorkspaceView: View {
    @ObservedObject var editor: Editor
    @StateObject private var preferences = TimelinePreferences()
    @StateObject private var passthroughCheck = PassthroughCheck()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Tone.line).frame(height: 1)
            HStack(spacing: 0) {
                preview
                Rectangle().fill(Tone.line).frame(width: 1)
                settings.frame(width: 225)
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(Tone.line).frame(height: 1)
            timeline
            Rectangle().fill(Tone.line).frame(height: 1)
            statusBar
        }
        .frame(minWidth: 880, minHeight: 592)
        .background(Tone.base)
        .foregroundStyle(Color.primary)
        .tint(Tone.mint)
        .preferredColorScheme(.dark)
        .onChange(of: editor.codec, initial: true) { _, newValue in
            if newValue == .passthrough && editor.size != .original { editor.size = .original }
        }
        .onChange(of: editor.size) { _, newValue in
            if editor.codec == .passthrough && newValue != .original { editor.size = .original }
        }
        .onDrop(of: [.fileURL], isTargeted: $preferences.fileHover, perform: receiveFiles)
        .overlay {
            if preferences.fileHover {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Tone.mint, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { editor.errorMessage != nil }, set: { if !$0 { editor.clearError() } })) {
            Button("好") { editor.clearError() }
        } message: { Text(editor.errorMessage ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "timeline.selection")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Tone.mint).frame(width: 27)
            Text("剪一刀").font(.system(size: 19, weight: .semibold))
            Divider().frame(height: 20).padding(.horizontal, 3)
            Button(action: editor.chooseFiles) { Label("导入视频", systemImage: "plus") }
                .buttonStyle(ToolButtonStyle()).disabled(editor.busy)
            Menu {
                Button("打开项目…", action: editor.openProject)
                Button("存储项目…", action: editor.saveProject).disabled(editor.segments.isEmpty)
            } label: {
                Label("项目", systemImage: "folder")
            }
            .fixedSize().menuStyle(.borderlessButton).disabled(editor.busy)
            Spacer()
            HStack(spacing: 0) {
                IconControl(symbol: "arrow.uturn.backward", title: "撤销", action: editor.undo)
                    .disabled(!editor.canUndo || editor.busy)
                IconControl(symbol: "arrow.uturn.forward", title: "重做", action: editor.redo)
                    .disabled(!editor.canRedo || editor.busy)
            }
            Divider().frame(height: 20)
            Button { editor.exportMovie() } label: { Label("导出成片", systemImage: "square.and.arrow.up") }
                .buttonStyle(ToolButtonStyle(active: true))
                .disabled(editor.segments.isEmpty || editor.busy)
        }
        .padding(.horizontal, 17).frame(height: 53).background(Tone.panel)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "play.rectangle").foregroundStyle(Tone.muted)
                Text("成片预览").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let s = editor.selected {
                    Text(s.source.url.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.045))
                if editor.segments.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 31, weight: .light)).foregroundStyle(Tone.mint)
                        Text("拖入本地视频").font(.system(size: 17, weight: .medium))
                        Button("选择视频…", action: editor.chooseFiles)
                            .buttonStyle(ToolButtonStyle()).disabled(editor.busy)
                    }
                } else if editor.previewSuspended {
                    if editor.isExporting {
                        Text("导出期间暂停预览").font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            Button(action: editor.togglePlayback) {
                                Label("继续预览", systemImage: "play.fill")
                            }
                            .buttonStyle(ToolButtonStyle()).disabled(editor.busy)
                            Text("也可以移动播放头定位").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    PlayerSurface(player: editor.player)
                        .contentShape(Rectangle()).onTapGesture { if !editor.busy { editor.togglePlayback() } }
                        .accessibilityLabel("视频画面")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Tone.line) }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    PlayheadLabel(position: editor.playheadPosition)
                    Text("/").foregroundStyle(.tertiary)
                    Text(clockText(editor.duration, precise: true)).foregroundStyle(Tone.muted)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                IconControl(symbol: "backward.frame.fill", title: "上一帧", action: { editor.stepFrame(-1) })
                Button(action: editor.togglePlayback) {
                    Image(systemName: editor.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 37, height: 28)
                        .background(Tone.field, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).keyboardShortcut(.space, modifiers: [])
                .help(editor.playing ? "暂停（空格）" : "播放（空格）")
                .accessibilityLabel(editor.playing ? "暂停" : "播放")
                IconControl(symbol: "forward.frame.fill", title: "下一帧", action: { editor.stepFrame(1) })
            }
            .disabled(editor.segments.isEmpty || editor.busy)
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
    }

    private var settings: some View {
        let request = PassthroughRequest(
            segments: editor.segments,
            enabled: !editor.busy && (editor.codec == .passthrough || editor.size == .original)
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("导出设置", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                settingRow("编码") {
                    Picker("编码", selection: $editor.codec) {
                        Text("HEVC · H.265").tag(ExportCodec.hevc)
                        Text("H.264").tag(ExportCodec.h264)
                        Text("快速无损").tag(ExportCodec.passthrough)
                    }
                }
                if editor.size == .original, case .ineligible(_, let selection?) = passthroughEligibility {
                    Button {
                        editor.exportKeyframeSelection(selection)
                    } label: {
                        Label("缩短到关键帧后快速导出…", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ToolButtonStyle())
                }
                if editor.codec == .passthrough {
                    Text("符合条件时直接复制画面和所选音轨的码流。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let message = passthroughMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    if editor.size == .original, case .eligible = passthroughEligibility {
                        VStack(alignment: .leading, spacing: 5) {
                            Button { editor.exportMovie(codecOverride: .passthrough) } label: {
                                Label("快速无损导出…", systemImage: "bolt.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ToolButtonStyle())
                            Text("保留素材的编码和码率。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    settingRow("分辨率") {
                        Picker("分辨率", selection: $editor.size) {
                            Text("跟随首段").tag(ExportSize.original)
                            Text("4K · 2160p").tag(ExportSize.uhd)
                            Text("QHD · 1440p").tag(ExportSize.qhd)
                            Text("HD · 1080p").tag(ExportSize.hd)
                        }
                    }
                    if let first = editor.segments.first {
                        let dimensions = MediaEngine.canvas(for: first.source, size: editor.size)
                        let rate = first.source.fps.formatted(.number.precision(.fractionLength(0...3)))
                        Text("\(Int(dimensions.width)) × \(Int(dimensions.height)) · \(rate) fps · SDR")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Tone.muted)
                            .help("成片采用首段帧率和标准动态范围")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("目标视频码率").font(.caption).foregroundStyle(Tone.muted)
                            Spacer()
                            Text("\(editor.bitrateMbps, specifier: "%.0f") Mbps")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        Slider(value: $editor.bitrateMbps, in: 1...160, step: 1)
                            .controlSize(.small).accessibilityLabel("目标视频码率")
                        if let sourceMbps = editor.sourceVideoMbpsBelowTarget {
                            let rate = sourceMbps.formatted(.number.precision(.fractionLength(0...1)))
                            Text("源视频平均约 \(rate) Mbps。可用接近的码率试导出，比较体积和画质。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider()
                if let trial = editor.trialResult {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("试样 · \(trial.duration.formatted(.number.precision(.fractionLength(0...3)))) 秒")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: trial.bytes, countStyle: .file))
                                .monospacedDigit()
                        }
                        .font(.caption).foregroundStyle(Tone.muted)
                        HStack {
                            Text("按试样估算整片").font(.caption)
                            Spacer()
                            Text("约 " + ByteCountFormatter.string(fromByteCount: trial.estimatedMovieBytes, countStyle: .file))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                    }
                    .help("按这段试样的实际文件大小和时长折算。其他片段的运动、细节和声音都会影响整片大小。")
                } else {
                    HStack {
                        Text("按码率估算整片").font(.caption).foregroundStyle(Tone.muted)
                        Spacer()
                        Text(estimatedSize).font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                }
                Button { editor.exportMovie(sample: true) } label: {
                    Label("试导出 10 秒", systemImage: "play.square.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ToolButtonStyle())
                .disabled(editor.segments.isEmpty || editor.codec == .passthrough)
                .help("从播放头开始，导出最多 10 秒以查看画质和体积")
            }
            .padding(15)
        }
        .background(Tone.panel)
        .disabled(editor.busy)
        .task(id: request, priority: .utility) { await checkPassthrough(request) }
    }

    private var passthroughEligibility: PassthroughEligibility? {
        guard let checked = passthroughCheck.result, checked.segments == editor.segments else { return nil }
        return checked.eligibility
    }

    private var passthroughMessage: String? {
        guard !editor.segments.isEmpty else { return nil }
        switch passthroughEligibility {
        case .eligible: return "当前时间线可快速无损导出。"
        case .ineligible(let reason, _): return reason
        case nil: return editor.busy ? nil : "正在检查素材规格和剪点…"
        }
    }

    private func checkPassthrough(_ request: PassthroughRequest) async {
        guard request.enabled, !request.segments.isEmpty, passthroughCheck.result?.segments != request.segments else { return }
        let eligibility: PassthroughEligibility
        do {
            try await Task.sleep(for: .milliseconds(180))
            try await MediaEngine.checkPassthrough(request.segments)
            eligibility = .eligible
        } catch {
            guard !Task.isCancelled else { return }
            var selection: Segment?
            if request.segments.count == 1, let segment = request.segments.first {
                selection = try? await MediaEngine.inwardKeyframeSelection(segment)
            }
            eligibility = .ineligible(error.localizedDescription, keyframeSelection: selection)
        }
        guard !Task.isCancelled, !editor.busy, editor.segments == request.segments else { return }
        passthroughCheck.result = (request.segments, eligibility)
    }

    private func settingRow<C: View>(_ name: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).foregroundStyle(Tone.muted)
            Spacer()
            control().labelsHidden().fixedSize().controlSize(.small)
        }
    }

    private var estimatedSize: String {
        guard !editor.segments.isEmpty, editor.codec != .passthrough else { return "—" }
        let bits = editor.bitrateMbps + (editor.segments.contains(where: { $0.source.hasAudio }) ? 0.192 : 0)
        let bytes = editor.duration * bits * 1_000_000 / 8
        guard bytes.isFinite && bytes >= 0 && bytes < Double(Int64.max) else { return "—" }
        return "约 " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var timeline: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("时间线", systemImage: "rectangle.3.group")
                    .font(.system(size: 13, weight: .semibold))
                if !editor.segments.isEmpty {
                    Menu {
                        ForEach(Array(editor.segments.enumerated()), id: \.element.id) { index, segment in
                            Button("\(index + 1)  \(segment.source.url.lastPathComponent)") { editor.select(segment.id) }
                        }
                    } label: { Text("\(editor.segments.count) 段").font(.caption).foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                Button(action: editor.split) { Label("分割", systemImage: "scissors") }
                    .buttonStyle(ToolButtonStyle()).help("在播放头处分割")
                Menu {
                    Button("裁掉选中片段在播放头前的部分", action: editor.trimBefore)
                    Button("裁掉选中片段在播放头后的部分", action: editor.trimAfter)
                    Divider()
                    Button("删除整个选中片段", action: editor.deleteSelected)
                } label: { Label("裁剪片段", systemImage: "crop") }
                .menuStyle(.borderlessButton).fixedSize().disabled(editor.selected == nil)
                HStack(spacing: 0) {
                    IconControl(symbol: "arrow.left.to.line", title: "将选中片段前移", action: { editor.moveSelected(-1) })
                        .disabled(editor.selectedID == editor.segments.first?.id || editor.selected == nil)
                    IconControl(symbol: "arrow.right.to.line", title: "将选中片段后移", action: { editor.moveSelected(1) })
                        .disabled(editor.selectedID == editor.segments.last?.id || editor.selected == nil)
                }
                Divider().frame(height: 16)
                IconControl(symbol: "minus.magnifyingglass", title: "缩小时间线", action: { preferences.zoom = max(1, preferences.zoom / 2) })
                    .disabled(preferences.zoom <= 1)
                IconControl(symbol: "plus.magnifyingglass", title: "放大时间线", action: { preferences.zoom = min(128, preferences.zoom * 2) })
                    .disabled(preferences.zoom >= 128)
            }
            .disabled(editor.segments.isEmpty || editor.busy)
            TimelineStrip(editor: editor, zoom: preferences.zoom)
                .frame(height: 75).disabled(editor.busy)
            HStack(spacing: 8) {
                Button(action: editor.setIn) { Label("设入点", systemImage: "arrow.right.to.line") }
                    .buttonStyle(ToolButtonStyle()).help("将播放头位置设为删除区间的起点")
                Text(clockText(editor.markIn ?? 0, precise: true))
                    .opacity(editor.markIn == nil ? 0.35 : 1)
                Button(action: editor.setOut) { Label("设出点", systemImage: "arrow.left.to.line") }
                    .buttonStyle(ToolButtonStyle()).help("将播放头位置设为删除区间的终点")
                Text(clockText(editor.markOut ?? editor.duration, precise: true))
                    .opacity(editor.markOut == nil ? 0.35 : 1)
                Spacer()
                Button(action: editor.removeRange) { Label("删除区间", systemImage: "scissors") }
                    .buttonStyle(ToolButtonStyle()).disabled(!editor.canRemoveRange)
                    .help("删除入点与出点之间的内容，合拢剩余片段")
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Tone.muted)
            .disabled(editor.segments.isEmpty || editor.busy)
        }
        .padding(.horizontal, 15).padding(.vertical, 9).background(Tone.panel)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            if editor.busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(editor.segments.isEmpty ? Color.secondary : Tone.mint).frame(width: 6, height: 6)
            }
            Text(editor.status).lineLimit(1).truncationMode(.middle)
            Spacer()
            if editor.isExporting {
                ProgressView(value: min(1, max(0, editor.progress)))
                    .progressViewStyle(.linear).frame(width: 95)
                Text("\(Int(editor.progress * 100))%").monospacedDigit()
                if let remaining = editor.estimatedExportRemainingSeconds {
                    Text(remainingTimeText(remaining)).monospacedDigit()
                }
                Button("取消", action: editor.cancelExport).buttonStyle(.link)
            } else if editor.busy {
                Button("取消", action: editor.cancelImport).buttonStyle(.link)
            } else if let url = editor.lastExport {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label(editor.trialResult?.url == url ? "播放试样" : "播放导出视频", systemImage: "play.circle")
                }.buttonStyle(.link)
                Divider().frame(height: 12)
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }.buttonStyle(.link)
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 15).frame(height: 25)
    }

    private func remainingTimeText(_ seconds: Double) -> String {
        if seconds >= 57.5 {
            let minutes = (seconds / 60).rounded()
            return "约剩 \(minutes.formatted(.number.precision(.fractionLength(0)))) 分钟"
        }
        let rounded = max(5, (seconds / 5).rounded() * 5)
        return "约剩 \(rounded.formatted(.number.precision(.fractionLength(0)))) 秒"
    }

    private func receiveFiles(_ providers: [NSItemProvider]) -> Bool {
        guard !editor.busy else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL {
                            continuation.resume(returning: url)
                        } else if let data = item as? Data {
                            continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            if !urls.isEmpty { editor.importFiles(urls) }
        }
        return true
    }
}

private struct PlayheadLabel: View {
    @ObservedObject var position: PlayheadPosition

    var body: some View {
        Text(clockText(position.seconds, precise: true)).foregroundStyle(Tone.mint)
    }
}

private struct TimelineStrip: View {
    @ObservedObject var editor: Editor
    let zoom: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width * zoom)
            let duration = max(editor.duration, 0.001)
            let scaling = width / duration
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(Tone.base)
                    VStack(spacing: 0) {
                        TimeRuler(duration: editor.duration, width: width)
                            .frame(height: 23)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { event in
                                    guard !editor.segments.isEmpty, abs(event.translation.width) >= 2 else { return }
                                    editor.scrub(to: event.location.x / scaling)
                                }
                                .onEnded { event in
                                    guard !editor.segments.isEmpty else { return }
                                    editor.seek(event.location.x / scaling)
                                }
                            ).help("拖动标尺定位播放头")
                        if editor.segments.isEmpty {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                                .foregroundStyle(Tone.line).frame(height: 38).padding(.horizontal, 3)
                        } else {
                            HStack(spacing: 0) {
                                ForEach(Array(editor.segments.enumerated()), id: \.element.id) { index, segment in
                                    let length = segment.end - segment.start
                                    let segmentWidth = max(0, length * scaling)
                                    card(segment, index: index, width: segmentWidth)
                                        .onTapGesture(coordinateSpace: .local) { point in
                                            editor.select(segment.id, at: min(length, max(0, point.x / scaling)))
                                        }
                                        .draggable(segment.id.uuidString)
                                        .dropDestination(for: String.self) { values, location in
                                            guard let first = values.first, let id = UUID(uuidString: first),
                                                  id != segment.id, editor.segments.contains(where: { $0.id == id })
                                            else { return false }
                                            let next = editor.segments.dropFirst(index + 1).first?.id
                                            editor.move(id, before: location.x < segmentWidth / 2 ? segment.id : next)
                                            return true
                                        }
                                        .contextMenu {
                                            Button("选中此片段") { editor.select(segment.id) }
                                            Button("片段前移") { editor.select(segment.id); editor.moveSelected(-1) }
                                            Button("片段后移") { editor.select(segment.id); editor.moveSelected(1) }
                                            Divider()
                                            Button("删除片段") { editor.select(segment.id); editor.deleteSelected() }
                                        }
                                }
                            }
                        }
                    }
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        if let start = editor.markIn, let end = editor.markOut, end > start {
                            Rectangle().fill(Tone.cursor.opacity(0.15))
                                .frame(width: (end - start) * scaling, height: 62).offset(x: start * scaling)
                        }
                        ForEach(Array([editor.markIn, editor.markOut].enumerated()), id: \.offset) { _, marker in
                            if let marker {
                                Rectangle().fill(Tone.cursor.opacity(0.85)).frame(width: 1, height: 62)
                                    .offset(x: min(width - 1, marker * scaling))
                            }
                        }
                        if !editor.segments.isEmpty {
                            TimelinePlayhead(position: editor.playheadPosition, width: width, scaling: scaling)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .frame(width: width, height: 65)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func card(_ segment: Segment, index: Int, width: CGFloat) -> some View {
        let selected = editor.selectedID == segment.id
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(selected ? Tone.mint.opacity(0.22) : Tone.field)
            RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Tone.mint : Tone.line, lineWidth: selected ? 1.3 : 1)
            if width > 32 {
                HStack(spacing: 7) {
                    Image(systemName: "film").foregroundStyle(selected ? Tone.mint : Tone.muted)
                    if width > 62 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(segment.source.url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(clockText(segment.end - segment.start, precise: true))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(Tone.muted)
                        }
                    }
                }.padding(.horizontal, 8)
            }
        }
        .padding(.trailing, min(2, width / 4))
        .frame(width: width, height: 38)
        .clipped().contentShape(Rectangle())
        .accessibilityLabel("片段 \(index + 1)，\(segment.source.url.lastPathComponent)")
    }
}

private struct TimelinePlayhead: View {
    @ObservedObject var position: PlayheadPosition
    let width: CGFloat
    let scaling: CGFloat

    var body: some View {
        let x = min(width - 1, max(1, position.seconds * scaling))
        ZStack(alignment: .topLeading) {
            Color.clear
            Path { pin in
                pin.move(to: CGPoint(x: 0, y: 0))
                pin.addLine(to: CGPoint(x: 8, y: 0))
                pin.addLine(to: CGPoint(x: 8, y: 5))
                pin.addLine(to: CGPoint(x: 4, y: 10))
                pin.addLine(to: CGPoint(x: 0, y: 5))
                pin.closeSubpath()
            }
            .fill(Tone.cursor).frame(width: 8, height: 10).offset(x: x - 4)
            Rectangle().fill(Tone.cursor).frame(width: 1.5, height: 56).offset(x: x - 0.75, y: 7)
        }
    }
}

private struct TimeRuler: View {
    var duration: Double
    var width: CGFloat
    var body: some View {
        if duration > 0 && width > 0 {
            let target = Double(86 / width) * duration
            let intervals: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
            let interval = intervals.first(where: { $0 >= target }) ?? max(7200, ceil(target / 3600) * 3600)
            let count = max(1, Int(ceil(duration / interval)))
            let stepWidth = width * interval / duration
            LazyHStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    Canvas { context, size in
                        for tick in 0..<4 {
                            let x = CGFloat(tick) * stepWidth / 4
                            let height: CGFloat = tick == 0 ? 5 : 2
                            context.fill(Path(CGRect(x: x, y: size.height - height, width: 1, height: height)),
                                         with: .color(Tone.muted.opacity(0.45)))
                        }
                        let time = Double(index) * interval
                        let text = Text(clockText(time, precise: interval < 1))
                            .font(.system(size: 9, design: .monospaced)).foregroundColor(Tone.muted)
                        context.draw(text, at: CGPoint(x: 4, y: 3), anchor: .topLeading)
                    }
                    .frame(width: min(stepWidth, width - CGFloat(index) * stepWidth))
                }
            }.frame(width: width, alignment: .leading).clipped()
        } else {
            Color.clear.frame(width: width)
        }
    }
}
