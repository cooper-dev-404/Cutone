import SwiftUI
import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers

private enum Tone {
    static let base = Color(red: 0.074, green: 0.060, blue: 0.080)
    static let panel = Color(red: 0.116, green: 0.087, blue: 0.119)
    static let field = Color(red: 0.174, green: 0.135, blue: 0.175)
    static let line = Color(red: 0.91, green: 0.78, blue: 0.83).opacity(0.16)
    static let text = Color(red: 0.97, green: 0.93, blue: 0.88)
    static let muted = Color(red: 0.74, green: 0.66, blue: 0.71)
    static let gold = Color(red: 0.96, green: 0.82, blue: 0.57)
    static let ink = Color(red: 0.15, green: 0.10, blue: 0.11)
    static let cursor = Color(red: 1.0, green: 0.55, blue: 0.48)
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
    @Environment(\.isEnabled) private var isEnabled
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: active ? .semibold : .medium))
            .padding(.horizontal, 10).frame(height: 28)
            .foregroundStyle(active ? Tone.ink : Tone.text)
            .background(active ? Tone.gold : Tone.field, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(active ? .clear : Tone.line) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.74 : 1) : 0.44)
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

private struct DarkroomGrain: View {
    private static let tile: CGImage? = {
        let side = 96
        var seed: UInt32 = 1
        let pixels = (0..<(side * side)).map { _ -> UInt8 in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    var body: some View {
        if let tile = Self.tile {
            Image(decorative: tile, scale: 1)
                .resizable(resizingMode: .tile)
                .blendMode(.softLight)
                .opacity(0.20)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct ProjectionCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length: CGFloat = 10
        var path = Path()
        for (x, dx) in [(rect.minX, length), (rect.maxX, -length)] {
            for (y, dy) in [(rect.minY, length), (rect.maxY, -length)] {
                path.move(to: CGPoint(x: x, y: y + dy))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + dx, y: y))
            }
        }
        return path
    }
}

enum TimelineTool {
    case selection, razor
}

struct TimelineZoomAnchor {
    let time: Double
    let x: CGFloat
}

@MainActor
final class TimelineControls: ObservableObject {
    static let step = 0.05
    @Published private(set) var level = 0.0
    private(set) var zoomAnchor: TimelineZoomAnchor?
    @Published var tool: TimelineTool = .selection

    func setLevel(_ proposedLevel: Double, anchoredAt anchor: TimelineZoomAnchor? = nil) {
        let updated = min(1, max(0, proposedLevel))
        guard updated != level else { return }
        zoomAnchor = anchor
        level = updated
    }

    func magnify(by delta: CGFloat, maximumZoom: Double, anchor: TimelineZoomAnchor) {
        guard delta.isFinite, delta > -1, maximumZoom.isFinite, maximumZoom > 1 else { return }
        setLevel(level + log1p(delta) / log(maximumZoom), anchoredAt: anchor)
    }

    func fit() { setLevel(0) }
    func increase() { setLevel((level / Self.step + 1).rounded() * Self.step) }
    func decrease() { setLevel((level / Self.step - 1).rounded() * Self.step) }
}

private struct WindowDragArea: NSViewRepresentable {
    final class Surface: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {}
}

private final class WorkspacePresentation: ObservableObject {
    @Published var isDropTargeted = false
    @Published var showsExportSettings = false
    let razorPreview = RazorPreviewFocus()
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
    @ObservedObject var timelineControls: TimelineControls
    @StateObject private var presentation = WorkspacePresentation()
    @StateObject private var passthroughCheck = PassthroughCheck()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Tone.line).frame(height: 1)
            preview.frame(maxHeight: .infinity)
            Rectangle().fill(Tone.line).frame(height: 1)
            timeline
            Rectangle().fill(Tone.line).frame(height: 1)
            statusBar
        }
        .frame(minWidth: 880, minHeight: 592)
        .ignoresSafeArea(.container, edges: .top)
        .background(Tone.base)
        .foregroundStyle(Tone.text)
        .tint(Tone.gold)
        .preferredColorScheme(.dark)
        .onChange(of: editor.codec, initial: true) { _, newValue in
            if newValue == .passthrough && editor.size != .original { editor.size = .original }
        }
        .onChange(of: editor.size) { _, newValue in
            if editor.codec == .passthrough && newValue != .original { editor.size = .original }
        }
        .onChange(of: editor.segments.isEmpty) { _, empty in
            if empty {
                timelineControls.fit()
                timelineControls.tool = .selection
            }
        }
        .onChange(of: editor.busy) { _, busy in
            if busy { presentation.showsExportSettings = false }
        }
        .onDrop(of: [.fileURL], isTargeted: $presentation.isDropTargeted, perform: receiveFiles)
        .overlay {
            if presentation.isDropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Tone.gold, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { editor.errorMessage != nil }, set: { if !$0 { editor.clearError() } })) {
            Button("好") { editor.clearError() }
        } message: { Text(editor.errorMessage ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 28, height: 28)
                .accessibilityHidden(true)
                .padding(.trailing, 6)
            Rectangle().fill(Tone.line).frame(width: 1, height: 20)
            Button(action: editor.chooseFiles) { Label("导入视频", systemImage: "plus") }
                .buttonStyle(ToolButtonStyle()).disabled(editor.busy)
            Menu {
                Button("打开项目…", action: editor.openProject)
                Button("存储项目…", action: editor.saveProject).disabled(editor.segments.isEmpty)
            } label: {
                Label(editor.projectURL?.deletingPathExtension().lastPathComponent ?? "项目",
                      systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
            }
            .fixedSize().menuStyle(.borderlessButton).disabled(editor.busy)
            WindowDragArea()
                .frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                IconControl(symbol: "arrow.uturn.backward", title: "撤销（⌘Z）", action: editor.undo)
                    .disabled(!editor.canUndo || editor.busy)
                IconControl(symbol: "arrow.uturn.forward", title: "重做（⇧⌘Z）", action: editor.redo)
                    .disabled(!editor.canRedo || editor.busy)
            }
            Rectangle().fill(Tone.line).frame(width: 1, height: 20)
            Button { presentation.showsExportSettings.toggle() } label: {
                Label("导出设置", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(editor.busy)
            .popover(isPresented: $presentation.showsExportSettings, arrowEdge: .bottom) {
                settings
                    .frame(width: 326, height: editor.segments.isEmpty ? 272 : 390)
                    .foregroundStyle(Tone.text)
                    .tint(Tone.gold)
                    .preferredColorScheme(.dark)
            }
            Button { editor.exportMovie() } label: { Label("导出成片", systemImage: "square.and.arrow.up") }
                .buttonStyle(ToolButtonStyle(active: true))
                .disabled(editor.segments.isEmpty || editor.busy)
        }
        .padding(.leading, 82).padding(.trailing, 17).frame(height: 40).background(Tone.panel)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Tone.gold)
                Text("成片预览").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let segment = editor.selected {
                    Text(segment.source.url.lastPathComponent)
                        .font(.system(size: 11)).foregroundStyle(Tone.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(height: 22)
            projection
            transport
        }
        .padding(.horizontal, 17).padding(.top, 9).padding(.bottom, 4)
        .background {
            ZStack {
                LinearGradient(colors: [Tone.panel, Tone.base, Tone.base], startPoint: .top, endPoint: .bottom)
                DarkroomGrain()
            }
        }
    }

    private var projection: some View {
        ZStack {
            if editor.segments.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 29, weight: .light)).foregroundStyle(Tone.gold)
                    Text("拖入本地视频").font(.system(size: 17, weight: .medium))
                    Button(action: editor.chooseFiles) { Label("选择视频…", systemImage: "plus") }
                        .buttonStyle(ToolButtonStyle()).disabled(editor.busy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RadialGradient(colors: [Tone.panel, Tone.base, .black], center: .center,
                                   startRadius: 0, endRadius: 390)
                }
            } else if editor.previewSuspended {
                if editor.isExporting {
                    Text("导出期间暂停预览").font(.callout).foregroundStyle(Tone.muted)
                } else {
                    VStack(spacing: 8) {
                        Button(action: editor.togglePlayback) {
                            Label("继续预览", systemImage: "play.fill")
                        }
                        .buttonStyle(ToolButtonStyle()).disabled(editor.busy)
                        Text("也可以移动播放头定位").font(.caption).foregroundStyle(Tone.muted)
                    }
                }
            } else {
                PlayerSurface(player: editor.player)
                    .contentShape(Rectangle()).onTapGesture { if !editor.busy { editor.togglePlayback() } }
                    .accessibilityLabel("视频画面")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(7)
        .background(Tone.field, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).strokeBorder(Tone.line)
                .allowsHitTesting(false)
        }
        .overlay {
            ProjectionCorners().stroke(Tone.gold.opacity(0.64), lineWidth: 1)
                .padding(4).allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay {
            if timelineControls.tool == .razor, !editor.busy, !editor.playing, !editor.previewSuspended {
                RazorPreviewIndicator(focus: presentation.razorPreview, position: editor.playheadPosition)
                    .allowsHitTesting(false)
            }
        }
    }

    private var transport: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                PlayheadLabel(position: editor.playheadPosition)
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                Text("/  " + clockText(editor.duration, precise: true))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Tone.muted)
            }
            Spacer()
            if let first = editor.segments.first {
                let canvas = MediaEngine.canvas(for: first.source, size: editor.size)
                Text(editor.codec == .passthrough ? editor.codec.rawValue
                     : "\(editor.codec.rawValue) · \(Int(canvas.width)) × \(Int(canvas.height))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Tone.muted)
                    .help("成片导出规格")
            }
        }
        .frame(height: 35)
        .overlay {
            HStack(spacing: 4) {
                IconControl(symbol: "backward.frame.fill", title: "上一帧（←）", action: { editor.stepFrame(-1) })
                Button(action: editor.togglePlayback) {
                    Image(systemName: editor.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 42, height: 28)
                        .foregroundStyle(Tone.gold)
                        .background(Tone.field, in: RoundedRectangle(cornerRadius: 5))
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Tone.line) }
                }
                .buttonStyle(.plain)
                .help(editor.playing ? "暂停（空格）" : "播放（空格）")
                .accessibilityLabel(editor.playing ? "暂停" : "播放")
                IconControl(symbol: "forward.frame.fill", title: "下一帧（→）", action: { editor.stepFrame(1) })
            }
            .disabled(editor.segments.isEmpty || editor.busy)
        }
    }

    private var settings: some View {
        let request = PassthroughRequest(
            segments: editor.segments,
            enabled: !editor.busy && (editor.codec == .passthrough || editor.size == .original)
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(Tone.gold)
                    Text("导出设置").font(.system(size: 15, weight: .semibold))
                }
                Rectangle().fill(Tone.line).frame(height: 1)
                settingRow("编码") {
                    Picker("编码", selection: $editor.codec) {
                        Text("HEVC · H.265").tag(ExportCodec.hevc)
                        Text("H.264").tag(ExportCodec.h264)
                        Text("快速无损").tag(ExportCodec.passthrough)
                    }
                }
                if editor.size == .original, case .ineligible(_, let selection?) = passthroughEligibility {
                    Button {
                        presentation.showsExportSettings = false
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
                            Button {
                                presentation.showsExportSettings = false
                                editor.exportMovie(codecOverride: .passthrough)
                            } label: {
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
                Button {
                    presentation.showsExportSettings = false
                    editor.exportMovie(sample: true)
                } label: {
                    Label("试导出 10 秒", systemImage: "play.square.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ToolButtonStyle())
                .disabled(editor.segments.isEmpty || editor.codec == .passthrough)
                .help("从播放头开始，导出最多 10 秒以查看画质和体积")
            }
            .padding(17)
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
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Label("时间线", systemImage: "film")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Tone.gold)
                if !editor.segments.isEmpty {
                    let trackCount = Set(editor.segments.map(\.track)).count
                    Menu {
                        ForEach(Array(editor.segments.enumerated()), id: \.element.id) { index, segment in
                            Button("\(index + 1)  \(segment.source.url.lastPathComponent)") { editor.select(segment.id) }
                        }
                    } label: {
                        Text("\(trackCount) 轨 · \(editor.segments.count) 段")
                            .font(.caption).foregroundStyle(Tone.muted)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("定位到成片中的片段")
                }
                HStack(spacing: 4) {
                    Button { timelineControls.tool = .selection } label: {
                        HStack(spacing: 5) {
                            Label("选择", systemImage: "cursorarrow")
                            TimelineShortcut(key: "V")
                        }
                    }
                    .buttonStyle(ToolButtonStyle(active: timelineControls.tool == .selection))
                    .accessibilityLabel("选择工具")
                    .accessibilityAddTraits(timelineControls.tool == .selection ? .isSelected : [])
                    .help("选择或拖动片段（V）")
                    Button { timelineControls.tool = .razor } label: {
                        HStack(spacing: 5) {
                            Label("剃刀", systemImage: "scissors")
                            TimelineShortcut(key: "C")
                        }
                    }
                    .buttonStyle(ToolButtonStyle(active: timelineControls.tool == .razor))
                    .accessibilityLabel("剃刀工具")
                    .accessibilityAddTraits(timelineControls.tool == .razor ? .isSelected : [])
                    .help("点击要分割的位置（C）")
                }
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    Button(action: editor.trimBefore) {
                        HStack(spacing: 5) {
                            Text("裁片头")
                            TimelineShortcut(key: "Q")
                        }
                    }
                    .help("裁掉选中片段在播放头前的部分（Q）")
                    Button(action: editor.split) {
                        HStack(spacing: 5) {
                            Text("分割")
                            TimelineShortcut(key: "⌘K")
                        }
                    }
                    .help("在播放头处分割（⌘K）")
                    Button(action: editor.trimAfter) {
                        HStack(spacing: 5) {
                            Text("裁片尾")
                            TimelineShortcut(key: "W")
                        }
                    }
                    .help("裁掉选中片段在播放头后的部分（W）")
                }
                .buttonStyle(ToolButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                .disabled(editor.selected == nil)
                HStack(spacing: 0) {
                    IconControl(symbol: "arrow.left.to.line", title: "将选中片段前移", action: { editor.moveSelected(-1) })
                        .disabled(editor.selectedID == editor.segments.first?.id || editor.selected == nil)
                    IconControl(symbol: "arrow.right.to.line", title: "将选中片段后移", action: { editor.moveSelected(1) })
                        .disabled(editor.selectedID == editor.segments.last?.id || editor.selected == nil)
                    IconControl(symbol: "trash", title: "删除选中片段（⌫）", action: editor.deleteSelected)
                        .disabled(editor.selected == nil)
                }
                Divider().frame(height: 16)
                HStack(spacing: 2) {
                    IconControl(symbol: "minus.magnifyingglass", title: "缩小时间线（−）", action: timelineControls.decrease)
                        .disabled(timelineControls.level <= 0)
                    ViewThatFits(in: .horizontal) {
                        timelineZoomSlider.frame(width: 72)
                        timelineZoomSlider.frame(width: 44)
                        Color.clear.frame(width: 0, height: 1)
                    }
                    IconControl(symbol: "plus.magnifyingglass", title: "放大时间线（= 或 +）", action: timelineControls.increase)
                        .disabled(timelineControls.level >= 1)
                    Button("适合窗口", action: timelineControls.fit)
                        .buttonStyle(ToolButtonStyle()).disabled(timelineControls.level <= 0)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("将整条时间线缩放到窗口内（⇧Z）")
                }
            }
            .disabled(editor.segments.isEmpty || editor.busy)
            TimelineStrip(editor: editor, controls: timelineControls, razorPreview: presentation.razorPreview)
                .disabled(editor.busy)
            HStack(spacing: 9) {
                Button(action: editor.setIn) {
                    HStack(spacing: 5) {
                        Text("设入点")
                        TimelineShortcut(key: "I")
                    }
                }
                .help("将播放头位置设为删除区间的起点（I）").disabled(editor.selected == nil)
                timelineMark(editor.markIn, name: "入点")
                Button(action: editor.setOut) {
                    HStack(spacing: 5) {
                        Text("设出点")
                        TimelineShortcut(key: "O")
                    }
                }
                .help("将播放头位置设为删除区间的终点（O）").disabled(editor.selected == nil)
                timelineMark(editor.markOut, name: "出点")
                Spacer()
                Button(action: editor.removeRange) {
                    HStack(spacing: 6) {
                        Label("删除本轨区间", systemImage: "scissors")
                        TimelineShortcut(key: "⌘⌫")
                    }
                    .foregroundStyle(editor.canRemoveRange ? Tone.cursor : Tone.muted)
                }
                .disabled(!editor.canRemoveRange)
                .help("删除设点轨道内的区间，后续片段依次合拢（⌘⌫）")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(editor.segments.isEmpty || editor.busy)
        }
        .padding(.horizontal, 16).padding(.vertical, 9).background(Tone.panel)
    }

    private var timelineZoomSlider: some View {
        Slider(value: Binding(get: { timelineControls.level }, set: { timelineControls.setLevel($0) }),
               in: 0...1, step: TimelineControls.step)
            .controlSize(.small)
            .accessibilityLabel("时间线缩放").help("拖动滑块以播放头为中心缩放，也可在时间线上双指捏合")
    }

    private func timelineMark(_ seconds: Double?, name: String) -> some View {
        Text(seconds.map { clockText($0, precise: true) } ?? "—")
            .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
            .foregroundStyle(seconds == nil ? Tone.muted : Tone.cursor)
            .frame(minWidth: 60, alignment: .leading)
            .accessibilityLabel(name)
            .accessibilityValue(seconds.map { clockText($0, precise: true) } ?? "未设置")
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            if editor.busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(editor.segments.isEmpty ? Tone.muted : Tone.gold).frame(width: 5, height: 5)
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
        .font(.system(size: 11)).foregroundStyle(Tone.muted)
        .padding(.horizontal, 17).frame(height: 25).background(Tone.base)
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
        Text(clockText(position.seconds, precise: true)).foregroundStyle(Tone.gold)
    }
}

private struct TimelineShortcut: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Tone.muted)
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(Tone.base.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
    }
}

private enum TimelineLayout {
    static let rulerHeight: CGFloat = 25
    static let trackHeight: CGFloat = 46
    static let scrollerHeight: CGFloat = 16
    static let visibleTracks = 4
}

private struct TimelineClip: Identifiable {
    let segment: Segment
    let index: Int
    let start: Double

    var id: UUID { segment.id }
    var length: Double { segment.end - segment.start }
}

private struct TimelineTrack: Identifiable {
    let id: Int?
    let clips: [TimelineClip]

    var name: String {
        id == nil ? "原有轨道" : clips[0].segment.source.url.lastPathComponent
    }
}

private struct TimelineStrip: View {
    @ObservedObject var editor: Editor
    @ObservedObject var controls: TimelineControls
    let razorPreview: RazorPreviewFocus
    @StateObject private var viewport = TimelineViewport()
    private var clipDrag: TimelineClipDrag { viewport.clipDrag }

    private var tracks: [TimelineTrack] {
        var cursor = 0.0
        var rows: [Int: [TimelineClip]] = [:]
        for (index, segment) in editor.segments.enumerated() {
            let clip = TimelineClip(segment: segment, index: index, start: cursor)
            rows[segment.track ?? 0, default: []].append(clip)
            cursor += clip.length
        }
        return rows.keys.sorted().compactMap { key in
            rows[key].map { TimelineTrack(id: key == 0 ? nil : key, clips: $0) }
        }
    }

    var body: some View {
        let tracks = tracks
        let selectedRow = editor.selected.flatMap { selection in
            tracks.firstIndex { $0.id == selection.track }
        }
        let rowCount = max(1, tracks.count)
        let documentHeight = TimelineLayout.rulerHeight + CGFloat(rowCount) * TimelineLayout.trackHeight
        let visibleHeight = TimelineLayout.rulerHeight
            + CGFloat(min(rowCount, TimelineLayout.visibleTracks)) * TimelineLayout.trackHeight
        let verticalScroll = tracks.count > TimelineLayout.visibleTracks
        let horizontalScroll = !tracks.isEmpty && controls.level > 0

        HStack(spacing: 0) {
            if !tracks.isEmpty {
                TimelineTrackHeaders(tracks: tracks, selectedRow: selectedRow, viewport: viewport,
                                     visibleHeight: visibleHeight) { editor.select($0) }
                    .frame(width: 132)
                Rectangle().fill(Tone.line).frame(width: 1)
            }
            GeometryReader { geometry in
                let scrollbarWidth = verticalScroll ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
                let viewportWidth = max(1, geometry.size.width - scrollbarWidth)
                let duration = editor.duration
                let fps = editor.segments.first?.source.fps ?? 30
                let maximumZoom = max(4, duration * max(480, fps * 12) / viewportWidth)
                let width = viewportWidth * pow(maximumZoom, horizontalScroll ? controls.level : 0)
                let scaling = width / max(duration, 0.001)
                TimelineScrollView(documentSize: CGSize(width: width, height: documentHeight),
                                   verticalScroll: verticalScroll, selectedRow: selectedRow,
                                   scaling: scaling, maximumZoom: maximumZoom, controls: controls,
                                   allowsMagnification: !editor.busy && !tracks.isEmpty,
                                   usesRazor: controls.tool == .razor && !editor.busy && !tracks.isEmpty,
                                   position: editor.playheadPosition, viewport: viewport) {
                    ZStack(alignment: .topLeading) {
                        Tone.base
                        VStack(spacing: 0) {
                            Color.clear.frame(height: TimelineLayout.rulerHeight)
                            if tracks.isEmpty {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                                    .foregroundStyle(Tone.line).frame(height: 38).padding(.horizontal, 3)
                            }
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { row, track in
                                let rowTop = TimelineLayout.rulerHeight + CGFloat(row) * TimelineLayout.trackHeight
                                let isVisible = rowTop < viewport.origin.y + visibleHeight
                                    && rowTop + TimelineLayout.trackHeight > viewport.origin.y + TimelineLayout.rulerHeight
                                trackRow(track, selected: row == selectedRow, width: width, scaling: scaling,
                                         visibleWidth: isVisible ? viewportWidth : 0)
                            }
                        }
                        if !tracks.isEmpty {
                            TimelinePlayhead(position: editor.playheadPosition, width: width, scaling: scaling)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: width, height: documentHeight)
                    .disabled(editor.busy)
                }
                .overlay(alignment: .topLeading) {
                    TimelineRuler(editor: editor, viewport: viewport, documentWidth: width,
                                  scaling: scaling, fps: fps)
                        .frame(width: viewportWidth, height: TimelineLayout.rulerHeight)
                }
            }
        }
        .frame(height: visibleHeight + (horizontalScroll ? TimelineLayout.scrollerHeight : 0))
        .background(Tone.base)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).strokeBorder(Tone.line)
                .allowsHitTesting(false)
        }
        .onChange(of: controls.tool) { _, _ in clipDrag.finish() }
        .onChange(of: editor.segments) { _, _ in clipDrag.finish() }
        .onChange(of: editor.busy) { _, busy in
            if busy { clipDrag.finish() }
        }
    }

    private func trackRow(_ track: TimelineTrack, selected: Bool, width: CGFloat,
                          scaling: CGFloat, visibleWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(selected ? Tone.gold.opacity(0.045) : Tone.base).overlay(alignment: .bottom) {
                Rectangle().fill(Tone.line).frame(height: 1)
            }
            ForEach(track.clips) { clip in
                clipView(clip, scaling: scaling, visibleWidth: visibleWidth)
                    .offset(x: clip.start * scaling)
            }
            if track.id == editor.markedTrack, editor.markIn != nil || editor.markOut != nil {
                ZStack(alignment: .leading) {
                    Color.clear
                    if let start = editor.markIn, let end = editor.markOut, end > start {
                        Rectangle().fill(Tone.cursor.opacity(0.19))
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Tone.cursor.opacity(0.8)).frame(height: 1)
                            }
                            .frame(width: (end - start) * scaling)
                            .offset(x: start * scaling)
                    }
                    ForEach(Array([editor.markIn, editor.markOut].enumerated()), id: \.offset) { index, marker in
                        if let marker {
                            let x = max(0, min(width - 1, marker * scaling))
                            TimelineRangeBracket(isStart: index == 0)
                                .stroke(Tone.cursor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                                .frame(width: 6, height: TimelineLayout.trackHeight - 5)
                                .offset(x: index == 0 ? x : x - 6)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: TimelineLayout.trackHeight)
    }

    @ViewBuilder
    private func clipView(_ clip: TimelineClip, scaling: CGFloat, visibleWidth: CGFloat) -> some View {
        let segment = clip.segment
        let width = clip.length * scaling
        let relativeOrigin = viewport.origin.x - clip.start * scaling
        let visibleStart = max(0, relativeOrigin)
        let visibleEnd = visibleWidth > 0 ? min(width, relativeOrigin + visibleWidth) : 0
        let target = card(segment, index: clip.index, width: width,
                          visibleStart: visibleStart, visibleEnd: visibleEnd)
            .onTapGesture(coordinateSpace: .local) { point in
                let offset = point.x / scaling
                switch controls.tool {
                case .selection: editor.select(segment.id, at: offset)
                case .razor: editor.split(segment.id, atClipOffset: offset)
                }
            }
            .contextMenu {
                Button("选中此片段") { editor.select(segment.id) }
                Button("片段前移") { editor.select(segment.id); editor.moveSelected(-1) }
                Button("片段后移") { editor.select(segment.id); editor.moveSelected(1) }
                Divider()
                Button("删除片段") { editor.select(segment.id); editor.deleteSelected() }
            }
        if controls.tool == .selection {
            target
                .overlay(alignment: .topLeading) {
                    TimelineDropIndicator(drag: clipDrag, clipID: clip.id, width: width,
                                          visibleStart: visibleStart, visibleEnd: visibleEnd)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .onDrag { clipDrag.begin(clip.id) } preview: { dragPreview(for: segment) }
                .onDrop(of: [TimelineClipDrag.contentType],
                        delegate: ClipDropDelegate(editor: editor, drag: clipDrag, clipID: clip.id, width: width))
        } else {
            target.modifier(TimelineRazorGuide(clip: clip, scaling: scaling,
                                               visibleStart: visibleStart, visibleEnd: visibleEnd,
                                               enabled: !editor.busy, preview: razorPreview,
                                               cutOffset: { editor.razorCutOffset(in: segment, at: $0) }))
                .help("点击高亮帧，分割片段")
        }
    }

    private func dragPreview(for segment: Segment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "film").foregroundStyle(Tone.gold)
            Text(segment.source.url.deletingPathExtension().lastPathComponent)
                .lineLimit(1).truncationMode(.middle)
            Text(clockText(segment.end - segment.start, precise: true))
                .monospacedDigit().foregroundStyle(Tone.muted)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Tone.text)
        .padding(.horizontal, 10).frame(maxWidth: 255).frame(height: 34)
        .background(Tone.field, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Tone.gold) }
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 6))
    }

    private func card(_ segment: Segment, index: Int, width: CGFloat,
                      visibleStart: CGFloat, visibleEnd: CGFloat) -> some View {
        let selected = editor.selectedID == segment.id
        let gap = min(2, width / 4)
        let contentWidth = width - gap
        let edge: CGFloat = 5
        let clipHeight = TimelineLayout.trackHeight - 5
        let artworkWidth = min(106, contentWidth * 0.44)
        let filmBase = selected ? Tone.gold.opacity(0.17) : Tone.field
        let perforationEnd = min(contentWidth, visibleEnd)
        let hasArtwork = contentWidth >= 112 && visibleEnd > edge && visibleStart < artworkWidth + edge
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(filmBase)
            if contentWidth >= 23 && perforationEnd > visibleStart {
                TimelineFilmPerforations(start: visibleStart, clipWidth: contentWidth,
                                         tint: selected ? Tone.gold.opacity(0.52) : Tone.muted.opacity(0.30))
                    .frame(width: perforationEnd - visibleStart, height: clipHeight)
                    .offset(x: visibleStart)
            }
            if contentWidth > 29 {
                HStack(spacing: 6) {
                    if hasArtwork {
                        let shot = segment.start + min(0.65, (segment.end - segment.start) / 2)
                        ZStack {
                            Tone.base
                            if !editor.busy {
                                FilmThumbnail(url: segment.source.preparedURL ?? segment.source.url, seconds: shot)
                            }
                        }
                        .frame(width: artworkWidth, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    } else if contentWidth <= 60 {
                        Image(systemName: "film").font(.system(size: 10))
                            .foregroundStyle(selected ? Tone.gold : Tone.muted)
                            .frame(maxWidth: .infinity)
                    }
                    if contentWidth > 60 {
                        Text(segment.source.url.deletingPathExtension().lastPathComponent)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        if contentWidth > 235 {
                            Spacer(minLength: 6)
                            Text(clockText(segment.end - segment.start, precise: true))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Tone.muted)
                        }
                    }
                }
                .padding(.horizontal, edge + 1)
            }
        }
        .frame(width: contentWidth, height: clipHeight)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selected ? Tone.gold : Tone.line, lineWidth: selected ? 1.35 : 1)
                .allowsHitTesting(false)
        }
        .padding(.trailing, gap)
        .clipped().contentShape(Rectangle())
        .help("\(segment.source.url.lastPathComponent) · \(clockText(segment.end - segment.start, precise: true))")
        .accessibilityLabel("片段 \(index + 1)，\(segment.source.url.lastPathComponent)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private final class RazorHover: ObservableObject {
    @Published private(set) var offset: Double?

    func set(_ value: Double?) {
        if value != offset { offset = value }
    }
}

private final class RazorPreviewFocus: ObservableObject {
    struct Frame: Equatable {
        let clipID: UUID
        let time: Double
        let frameRate: Double

        func matches(_ playhead: Double) -> Bool {
            abs(playhead - time) < 0.5 / max(1, frameRate)
        }
    }

    @Published private(set) var frame: Frame?

    func update(_ frame: Frame) {
        if self.frame != frame { self.frame = frame }
    }

    func clear(for clipID: UUID) {
        if frame?.clipID == clipID { frame = nil }
    }
}

private struct RazorPreviewIndicator: View {
    @ObservedObject var focus: RazorPreviewFocus
    @ObservedObject var position: PlayheadPosition

    var body: some View {
        if let frame = focus.frame, frame.matches(position.seconds) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Tone.cursor, lineWidth: 2)
                    .accessibilityHidden(true)
                HStack(spacing: 9) {
                    Label("当前帧可分割", systemImage: "scissors")
                        .font(.system(size: 12, weight: .semibold))
                    Text(clockText(frame.time, precise: true))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(Tone.ink)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Tone.cursor, in: RoundedRectangle(cornerRadius: 5))
                .padding(12)
            }
        }
    }
}

private struct TimelineRazorGuide: ViewModifier {
    let clip: TimelineClip
    let scaling: CGFloat
    let visibleStart: CGFloat
    let visibleEnd: CGFloat
    let enabled: Bool
    let preview: RazorPreviewFocus
    let cutOffset: (Double) -> Double?
    @StateObject private var hover = RazorHover()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if enabled, let offset = hover.offset {
                    guide(at: offset).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point) where enabled:
                    updateOffset(cutOffset(point.x / scaling))
                default:
                    updateOffset(nil)
                }
            }
            .onChange(of: scaling) { _, _ in updateOffset(nil) }
            .onChange(of: enabled) { _, _ in updateOffset(nil) }
            .onDisappear { preview.clear(for: clip.id) }
    }

    private func updateOffset(_ offset: Double?) {
        hover.set(offset)
        if let offset {
            preview.update(.init(clipID: clip.id, time: clip.start + offset,
                                 frameRate: clip.segment.source.fps))
        } else {
            preview.clear(for: clip.id)
        }
    }

    private func guide(at offset: Double) -> some View {
        let width = clip.length * scaling
        let x = offset * scaling
        let chipWidth: CGFloat = 118
        let chipX = x + chipWidth + 9 <= visibleEnd ? x + 7 : x - chipWidth - 7
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Tone.cursor, lineWidth: 1.4)
                .padding(.trailing, min(2, width / 4))
            VStack(spacing: 0) {
                Image(systemName: "triangle.fill").rotationEffect(.degrees(180))
                    .font(.system(size: 8, weight: .bold))
                Rectangle().frame(width: 2).frame(maxHeight: .infinity)
                Image(systemName: "triangle.fill")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Tone.cursor)
            .frame(width: 9).offset(x: x - 4.5)
            if visibleEnd - visibleStart >= chipWidth + 16 {
                Label(clockText(clip.start + offset, precise: true), systemImage: "scissors")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(Tone.ink)
                    .frame(width: chipWidth, height: 21)
                    .background(Tone.cursor, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: max(visibleStart + 3, min(chipX, visibleEnd - chipWidth - 3)), y: 9)
            }
        }
        .frame(width: width, height: TimelineLayout.trackHeight - 5)
    }
}

private final class TimelineClipDrag: ObservableObject {
    static let contentType = UTType(exportedAs: "local.qingjian.timeline-clip", conformingTo: .data)

    struct Target: Equatable {
        let clipID: UUID
        let afterClip: Bool
        let insertBefore: UUID?
    }

    private(set) var source: UUID?
    @Published private(set) var target: Target?

    func begin(_ id: UUID) -> NSItemProvider {
        source = id
        show(nil)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: Self.contentType.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    func show(_ target: Target?) {
        if self.target != target { self.target = target }
    }

    func leave(_ clipID: UUID) {
        if target?.clipID == clipID { show(nil) }
    }

    func finish() {
        source = nil
        show(nil)
    }
}

private struct ClipDropDelegate: DropDelegate {
    let editor: Editor
    let drag: TimelineClipDrag
    let clipID: UUID
    let width: CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        !editor.busy && drag.source != nil && info.hasItemsConforming(to: [TimelineClipDrag.contentType])
    }

    func dropEntered(info: DropInfo) {
        updateTarget(at: info.location.x)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = updateTarget(at: info.location.x)
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        drag.leave(clipID)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { drag.finish() }
        guard validateDrop(info: info), let id = drag.source,
              let target = updateTarget(at: info.location.x) else { return false }
        editor.move(id, before: target.insertBefore)
        return true
    }

    @discardableResult
    private func updateTarget(at x: CGFloat) -> TimelineClipDrag.Target? {
        let target = destination(afterClip: x >= width / 2)
        if let target {
            drag.show(target)
        } else {
            drag.leave(clipID)
        }
        return target
    }

    private func destination(afterClip: Bool) -> TimelineClipDrag.Target? {
        guard !editor.busy, let id = drag.source, id != clipID,
              let source = editor.segments.firstIndex(where: { $0.id == id }),
              let destination = editor.segments.firstIndex(where: { $0.id == clipID }) else { return nil }
        let insertion = destination + (afterClip ? 1 : 0)
        guard insertion != source, insertion != source + 1 else { return nil }
        let next = insertion < editor.segments.count ? editor.segments[insertion].id : nil
        return .init(clipID: clipID, afterClip: afterClip, insertBefore: next)
    }
}

private struct TimelineDropIndicator: View {
    @ObservedObject var drag: TimelineClipDrag
    let clipID: UUID
    let width: CGFloat
    let visibleStart: CGFloat
    let visibleEnd: CGFloat

    var body: some View {
        if let target = drag.target, target.clipID == clipID, visibleEnd - visibleStart > 3 {
            let clipEdge = target.afterClip ? width - min(2, width / 4) : 0
            let x = min(visibleEnd - 2, max(visibleStart + 2, clipEdge))
            let chipWidth: CGFloat = 84
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Tone.gold.opacity(0.12))
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Tone.gold.opacity(0.7)) }
                    .padding(.trailing, min(2, width / 4))
                Capsule()
                    .fill(Tone.gold)
                    .frame(width: 3)
                    .shadow(color: Tone.gold.opacity(0.6), radius: 3)
                    .offset(x: x - 1.5)
                if visibleEnd - visibleStart >= chipWidth + 12 {
                    Label(target.afterClip ? "插到后面" : "插到前面",
                          systemImage: target.afterClip ? "arrow.right.to.line" : "arrow.left.to.line")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tone.ink)
                        .frame(width: chipWidth, height: 20)
                        .background(Tone.gold, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: min(visibleEnd - chipWidth - 3,
                                       max(visibleStart + 3, target.afterClip ? x - chipWidth - 5 : x + 5)), y: 10)
                }
            }
            .frame(width: width, height: TimelineLayout.trackHeight - 5)
        }
    }
}

private struct TimelineFilmPerforations: View {
    let start: CGFloat
    let clipWidth: CGFloat
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let pitch: CGFloat = 11
            let inset: CGFloat = 5
            let slotWidth: CGFloat = 5
            let slotHeight: CGFloat = 2.5
            let first = max(0, Int(floor((start - inset) / pitch)))
            let last = Int(ceil((start + size.width - inset) / pitch))
            guard first <= last else { return }
            var slots = Path()
            for slot in first...last {
                let x = inset + CGFloat(slot) * pitch
                guard x + slotWidth <= clipWidth - inset else { break }
                for y in [3, size.height - slotHeight - 3] {
                    slots.addRoundedRect(in: CGRect(x: x - start, y: y, width: slotWidth, height: slotHeight),
                                         cornerSize: CGSize(width: 0.7, height: 0.7))
                }
            }
            context.fill(slots, with: .color(tint))
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TimelineRangeBracket: Shape {
    let isStart: Bool

    func path(in rect: CGRect) -> Path {
        let edge = isStart ? rect.minX : rect.maxX
        let cap = isStart ? rect.maxX : rect.minX
        return Path { path in
            path.move(to: CGPoint(x: cap, y: rect.minY))
            path.addLine(to: CGPoint(x: edge, y: rect.minY))
            path.addLine(to: CGPoint(x: edge, y: rect.maxY))
            path.addLine(to: CGPoint(x: cap, y: rect.maxY))
        }
    }
}

private struct TimelineTrackHeaders: View {
    let tracks: [TimelineTrack]
    let selectedRow: Int?
    @ObservedObject var viewport: TimelineViewport
    let visibleHeight: CGFloat
    let select: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("素材轨道")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Tone.muted)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, minHeight: TimelineLayout.rulerHeight, alignment: .leading)
                .background(Tone.base)
                .overlay(alignment: .bottom) { Rectangle().fill(Tone.line).frame(height: 1) }
            VStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    Button { select(track.clips[0].id) } label: {
                        HStack(spacing: 7) {
                            Text("V\(index + 1)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(index == selectedRow ? Tone.gold : Tone.muted)
                                .frame(minWidth: 22)
                                .padding(.vertical, 3)
                                .background(index == selectedRow ? Tone.gold.opacity(0.13) : Tone.base.opacity(0.6),
                                            in: RoundedRectangle(cornerRadius: 3))
                            Text(track.name).lineLimit(1).truncationMode(.middle)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: TimelineLayout.trackHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(index == selectedRow ? Tone.gold.opacity(0.075) : Tone.field.opacity(0.48))
                    .overlay(alignment: .leading) {
                        if index == selectedRow {
                            Rectangle().fill(Tone.gold).frame(width: 2).allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottom) { Rectangle().fill(Tone.line).frame(height: 1) }
                    .help(track.name)
                    .accessibilityLabel("轨道 \(index + 1)，\(track.name)")
                }
            }
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .offset(y: -viewport.origin.y)
            .frame(height: visibleHeight - TimelineLayout.rulerHeight, alignment: .top)
            .clipped()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct TimelineRuler: View {
    @ObservedObject var editor: Editor
    @ObservedObject var viewport: TimelineViewport
    let documentWidth: CGFloat
    let scaling: CGFloat
    let fps: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Tone.base
            TimeRuler(viewport: viewport, duration: editor.duration, scaling: scaling, fps: fps)
            VStack {
                Spacer(minLength: 0)
                Rectangle().fill(Tone.line).frame(height: 1)
            }
            if !editor.segments.isEmpty {
                TimelinePlayhead(position: editor.playheadPosition, width: documentWidth, scaling: scaling,
                                 offset: viewport.origin.x, showsPin: true)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { event in
                guard !editor.busy, !editor.segments.isEmpty, abs(event.translation.width) >= 2 else { return }
                editor.scrub(to: (viewport.origin.x + event.location.x) / scaling)
            }
            .onEnded { event in
                guard !editor.busy, !editor.segments.isEmpty else { return }
                editor.seek((viewport.origin.x + event.location.x) / scaling)
            }
        )
        .help("拖动标尺定位播放头")
        .accessibilityHidden(true)
    }
}

@MainActor
private final class TimelineViewport: ObservableObject {
    let clipDrag = TimelineClipDrag()
    @Published private(set) var origin: CGPoint = .zero
    private var pendingOrigin: CGPoint?

    func scroll(to point: CGPoint) {
        let scheduled = pendingOrigin != nil
        guard point != (pendingOrigin ?? origin) else { return }
        pendingOrigin = point
        guard !scheduled else { return }
        // AppKit can update the clip bounds during SwiftUI layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, let point = self.pendingOrigin else { return }
            self.pendingOrigin = nil
            if self.origin != point { self.origin = point }
        }
    }
}

private final class TimelineScroller: NSScrollView {
    var didScroll: ((CGPoint) -> Void)?
    var usesRazor = false {
        didSet {
            if oldValue != usesRazor { window?.invalidateCursorRects(for: self) }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if usesRazor { addCursorRect(contentView.frame, cursor: .crosshair) }
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        didScroll?(clipView.bounds.origin)
    }
}

private final class TimelineClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private struct TimelineScrollView<Content: View>: NSViewRepresentable {
    let documentSize: CGSize
    let verticalScroll: Bool
    let selectedRow: Int?
    let scaling: CGFloat
    let maximumZoom: Double
    let controls: TimelineControls
    let allowsMagnification: Bool
    let usesRazor: Bool
    let position: PlayheadPosition
    let viewport: TimelineViewport
    @ViewBuilder var content: Content

    func makeCoordinator() -> Coordinator { Coordinator(content: content) }

    func makeNSView(context: Context) -> TimelineScroller {
        let scroller = TimelineScroller()
        scroller.contentView = TimelineClipView()
        scroller.drawsBackground = false
        scroller.hasHorizontalScroller = true
        scroller.scrollerStyle = .legacy
        scroller.autohidesScrollers = true
        scroller.horizontalScrollElasticity = .none
        scroller.verticalScrollElasticity = .none
        scroller.documentView = context.coordinator.document
        scroller.didScroll = { [weak viewport] x in viewport?.scroll(to: x) }
        context.coordinator.observe(position, in: scroller)
        context.coordinator.observeMagnification(controls, in: scroller)
        return scroller
    }

    func updateNSView(_ scroller: TimelineScroller, context: Context) {
        scroller.hasVerticalScroller = verticalScroll
        scroller.usesRazor = usesRazor
        context.coordinator.configureMagnification(maximumZoom: maximumZoom, enabled: allowsMagnification)
        context.coordinator.update(content: content, size: documentSize, selectedRow: selectedRow,
                                   scaling: scaling, zoomLevel: controls.level, zoomAnchor: controls.zoomAnchor,
                                   playhead: position.seconds, in: scroller)
    }

    static func dismantleNSView(_ nsView: TimelineScroller, coordinator: Coordinator) {
        coordinator.stopObservingMagnification()
    }

    @MainActor
    final class Coordinator {
        let document: NSHostingView<Content>
        private var observation: AnyCancellable?
        private var magnificationMonitor: Any?
        private var pinchAnchor: TimelineZoomAnchor?
        private var maximumZoom = 4.0
        private var allowsMagnification = false
        private var scaling: CGFloat = 1
        private var zoomLevel: Double?
        private var selectedRow: Int?

        init(content: Content) {
            document = NSHostingView(rootView: content)
            document.sizingOptions = []
        }

        func observe(_ position: PlayheadPosition, in scroller: TimelineScroller) {
            observation = position.$seconds.dropFirst().sink { [weak self, weak scroller] time in
                guard let self, let scroller, self.pinchAnchor == nil else { return }
                self.reveal(time, centered: false, in: scroller)
            }
        }

        func configureMagnification(maximumZoom: Double, enabled: Bool) {
            self.maximumZoom = maximumZoom
            allowsMagnification = enabled
            if !enabled { pinchAnchor = nil }
        }

        func observeMagnification(_ controls: TimelineControls, in scroller: TimelineScroller) {
            magnificationMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self, weak controls, weak scroller] event in
                guard let self, let controls, let scroller, let window = scroller.window,
                      event.window === window else { return event }
                let handled = self.magnify(by: event.magnification, at: event.locationInWindow,
                                           phase: event.phase, controls: controls, in: scroller)
                return handled ? nil : event
            }
        }

        func stopObservingMagnification() {
            if let magnificationMonitor { NSEvent.removeMonitor(magnificationMonitor) }
            magnificationMonitor = nil
        }

        func magnify(by delta: CGFloat, at location: CGPoint, phase: NSEvent.Phase,
                     controls: TimelineControls, in scroller: TimelineScroller) -> Bool {
            guard allowsMagnification else { return false }
            if phase == .began { pinchAnchor = nil }
            let clip = scroller.contentView
            let point = clip.convert(location, from: nil)
            guard pinchAnchor != nil || clip.bounds.contains(point) else { return false }
            if phase == .cancelled || phase == .ended {
                pinchAnchor = nil
                return true
            }
            let anchor = pinchAnchor ?? TimelineZoomAnchor(time: point.x / scaling, x: point.x - clip.bounds.minX)
            if !phase.isEmpty { pinchAnchor = anchor }
            controls.magnify(by: delta, maximumZoom: maximumZoom, anchor: anchor)
            return true
        }

        func update(content: Content, size: CGSize, selectedRow: Int?, scaling: CGFloat, zoomLevel: Double,
                    zoomAnchor: TimelineZoomAnchor?, playhead: Double, in scroller: TimelineScroller) {
            let zoomChanged = self.zoomLevel != zoomLevel
            let metricsChanged = self.scaling != scaling || document.frame.size != size
            let gestureAnchor = zoomChanged ? zoomAnchor : nil
            self.scaling = scaling
            self.zoomLevel = zoomLevel
            document.rootView = content
            if document.frame.size != size {
                document.setFrameSize(size)
                scroller.tile()
            }
            if let gestureAnchor {
                scrollHorizontally(to: gestureAnchor.time * scaling - gestureAnchor.x, in: scroller)
            } else if zoomChanged || metricsChanged {
                reveal(playhead, centered: zoomChanged, in: scroller)
            }
            if let selectedRow, selectedRow != self.selectedRow || (metricsChanged && gestureAnchor == nil) {
                revealRow(selectedRow, in: scroller)
            }
            self.selectedRow = selectedRow
        }

        private func revealRow(_ row: Int, in scroller: TimelineScroller) {
            let clip = scroller.contentView
            let visible = clip.bounds
            let rowTop = CGFloat(row) * TimelineLayout.trackHeight
            let rowBottom = rowTop + TimelineLayout.rulerHeight + TimelineLayout.trackHeight
            let y = min(rowTop, max(visible.minY, rowBottom - visible.height))
            let target = min(max(0, document.frame.height - visible.height), max(0, y))
            guard target != visible.minY else { return }
            clip.scroll(to: CGPoint(x: visible.minX, y: target))
            scroller.reflectScrolledClipView(clip)
        }

        private func reveal(_ time: Double, centered: Bool, in scroller: TimelineScroller) {
            let clip = scroller.contentView
            let visible = clip.bounds
            guard visible.width > 0 else { return }
            let x = min(document.frame.width - 1, time * scaling)
            guard centered || x < visible.minX || x >= visible.maxX else { return }
            scrollHorizontally(to: x - visible.width * (centered ? 0.5 : 0.25), in: scroller)
        }

        private func scrollHorizontally(to offset: CGFloat, in scroller: TimelineScroller) {
            let clip = scroller.contentView
            let visible = clip.bounds
            let end = max(0, document.frame.width - visible.width)
            let target = min(end, max(0, offset))
            clip.scroll(to: CGPoint(x: target, y: visible.minY))
            scroller.reflectScrolledClipView(clip)
        }
    }
}

private struct TimelinePlayhead: View {
    @ObservedObject var position: PlayheadPosition
    let width: CGFloat
    let scaling: CGFloat
    var offset: CGFloat = 0
    var showsPin = false

    var body: some View {
        let x = min(width - 1, max(1, position.seconds * scaling)) - offset
        let pinTop = TimelineLayout.rulerHeight - 11
        ZStack(alignment: .topLeading) {
            Color.clear
            if showsPin {
                Path { pin in
                    pin.move(to: CGPoint(x: 0, y: 0))
                    pin.addLine(to: CGPoint(x: 10, y: 0))
                    pin.addLine(to: CGPoint(x: 10, y: 6))
                    pin.addLine(to: CGPoint(x: 5, y: 11))
                    pin.addLine(to: CGPoint(x: 0, y: 6))
                    pin.closeSubpath()
                }
                .fill(Tone.gold).frame(width: 10, height: 11).offset(x: x - 5, y: pinTop)
            }
            Rectangle().fill(Tone.gold).frame(width: 1.25)
                .padding(.top, showsPin ? pinTop : 0)
                .offset(x: x - 0.625)
        }
    }
}

private struct TimeRuler: View {
    @ObservedObject var viewport: TimelineViewport
    let duration: Double
    let scaling: CGFloat
    let fps: Double

    var body: some View {
        Canvas { context, size in
            guard duration > 0 else { return }
            let offset = viewport.origin.x
            let target = 86 / scaling
            let intervals: [Double] = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30,
                                       60, 120, 300, 600, 900, 1800, 3600, 7200]
            let interval = intervals.first(where: { $0 >= target }) ?? max(7200, ceil(target / 3600) * 3600)
            let stepWidth = interval * scaling
            let right = min(duration * scaling, offset + size.width)
            let frameWidth = scaling / max(1, fps)
            if frameWidth >= 8 {
                let firstFrame = Int(ceil(offset / frameWidth))
                let lastFrame = Int(right / frameWidth)
                if firstFrame <= lastFrame {
                    for frame in firstFrame...lastFrame {
                        let x = CGFloat(frame) * frameWidth - offset
                        context.fill(Path(CGRect(x: x, y: size.height - 2, width: 1, height: 2)),
                                     with: .color(Tone.muted.opacity(0.28)))
                    }
                }
            }
            let first = Int(offset / stepWidth)
            let last = Int(right / stepWidth)
            guard first <= last else { return }
            for index in first...last {
                let x = Double(index) * stepWidth - offset
                for tick in 0..<4 {
                    let tickX = x + CGFloat(tick) * stepWidth / 4
                    guard tickX <= duration * scaling - offset else { break }
                    let height: CGFloat = tick == 0 ? 6 : 2
                    context.fill(Path(CGRect(x: tickX, y: size.height - height, width: 1, height: height)),
                                 with: .color(Tone.muted.opacity(0.45)))
                }
                let label = context.resolve(Text(clockText(Double(index) * interval, precise: interval < 1))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Tone.muted))
                let labelX = x + 4
                if labelX >= 0, labelX + label.measure(in: size).width <= size.width {
                    context.draw(label, at: CGPoint(x: labelX, y: 3), anchor: .topLeading)
                }
            }
        }
    }
}
