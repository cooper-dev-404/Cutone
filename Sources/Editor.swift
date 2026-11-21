import AppKit
import AVFoundation
import Combine
import Foundation
import QuartzCore
import UniformTypeIdentifiers

struct TrialExportResult {
    let url: URL
    let bytes: Int64
    let duration: Double
    let codec: ExportCodec
    let size: ExportSize
    let bitrateMbps: Double
    let estimatedMovieBytes: Int64

    static func measure(_ url: URL, timelineDuration: Double, codec: ExportCodec,
                        size: ExportSize, bitrateMbps: Double) async -> TrialExportResult? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let byteCount = attrs[.size] as? NSNumber, byteCount.int64Value > 0 else { return nil }
        let estimated = (Double(byteCount.int64Value) * timelineDuration / duration).rounded()
        guard estimated.isFinite, estimated >= 0, estimated < Double(Int64.max) else { return nil }
        return TrialExportResult(url: url, bytes: byteCount.int64Value, duration: duration,
                                 codec: codec, size: size, bitrateMbps: bitrateMbps,
                                 estimatedMovieBytes: Int64(estimated))
    }
}

@MainActor
final class PlayheadPosition: ObservableObject {
    @Published fileprivate(set) var seconds: Double = 0
}

@MainActor
final class Editor: ObservableObject {
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var playing = false
    @Published private(set) var previewSuspended = false
    @Published private(set) var markIn: Double?
    @Published private(set) var markOut: Double?
    @Published private(set) var busy = false
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "准备就绪"
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastExport: URL?
    @Published private var measuredTrial: TrialExportResult?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var projectURL: URL?
    @Published var codec: ExportCodec = .hevc
    @Published var size: ExportSize = .original
    @Published var bitrateMbps: Double = 20
    let player = AVPlayer()
    let playheadPosition = PlayheadPosition()
    var playhead: Double { playheadPosition.seconds }

    private var history: [Snapshot] = []
    private var future: [Snapshot] = []
    private var previewTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var sourceReadID: UUID?
    private var exportTask: Task<Void, Never>?
    private var previewRevision = 0
    private struct PreviewSeek: Equatable {
        let time: CMTime
        let tolerance: CMTime
    }
    private var activeSeek: PreviewSeek?
    private var pendingSeek: PreviewSeek?
    private var lastScrubSeek = -Double.infinity
    private let scrubInterval = 1.0 / 20
    private var exportID: UUID?
    private var encodingStartedAt: Double?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var itemObservation: NSKeyValueObservation?
    private var savedSegments: [Segment] = []
    private var savedCodec: ExportCodec = .hevc
    private var savedSize: ExportSize = .original
    private var savedBitrate: Double = 20

    var duration: Double { segments.reduce(0) { $0 + $1.end - $1.start } }
    var selected: Segment? { segments.first { $0.id == selectedID } }
    var sourceVideoMbps: Double? {
        var weightedRate = 0.0
        var duration = 0.0
        for segment in segments {
            guard let rate = segment.source.videoMbps, rate.isFinite, rate > 0 else { return nil }
            let length = segment.end - segment.start
            weightedRate += rate * length
            duration += length
        }
        guard duration > 0, weightedRate.isFinite else { return nil }
        return weightedRate / duration
    }
    var sourceVideoMbpsBelowTarget: Double? {
        guard let sourceVideoMbps, bitrateMbps >= max(sourceVideoMbps * 1.5, sourceVideoMbps + 2) else { return nil }
        return sourceVideoMbps
    }
    var estimatedExportRemainingSeconds: Double? {
        guard let encodingStartedAt, progress >= 0.03, progress < 0.98 else { return nil }
        let elapsed = ProcessInfo.processInfo.systemUptime - encodingStartedAt
        guard elapsed >= 5 else { return nil }
        return elapsed / progress * (1 - progress)
    }
    var trialResult: TrialExportResult? {
        guard let trial = measuredTrial, trial.codec == codec, trial.size == size,
              trial.bitrateMbps == bitrateMbps else { return nil }
        return trial
    }
    var canRemoveRange: Bool {
        guard let markIn, let markOut else { return false }
        return markOut > markIn + 0.000001
    }
    var hasUnsavedChanges: Bool {
        segments != savedSegments || ((projectURL != nil || !segments.isEmpty) &&
            (codec != savedCodec || size != savedSize || bitrateMbps != savedBitrate))
    }

    init() {
        player.actionAtItemEnd = .pause
    }

    deinit {
        previewTask?.cancel()
        importTask?.cancel()
        exportTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func clearError() { errorMessage = nil }

    func chooseFiles() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "导入本地视频"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video] + [
            "mp4", "mov", "m4v", "mkv", "webm", "avi", "ts", "m2ts", "mts", "mpg", "mpeg", "mxf"
        ].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func importFiles(_ urls: [URL]) {
        guard !busy, !urls.isEmpty else { return }
        pause()
        busy = true
        errorMessage = nil
        importTask = Task {
            defer { busy = false; importTask = nil }
            var imported: [Segment] = []
            var failures: [String] = []
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                status = "正在读取素材 \(index + 1) / \(urls.count)"
                do {
                    let source = try await inspectSource(url)
                    imported.append(Segment(source: source, start: 0, end: source.duration))
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled else { status = "已取消导入"; return }
            if let first = imported.first {
                let cursor = duration
                record()
                segments.append(contentsOf: imported)
                applyEdit(at: cursor, selection: first.id, message: "已导入 \(imported.count) 个视频")
            } else { status = "导入未完成" }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        }
    }

    private func inspectSource(_ url: URL) async throws -> SourceInfo {
        try Task.checkCancellation()
        let readID = UUID()
        sourceReadID = readID
        defer { sourceReadID = nil }
        return try await MediaEngine.inspect(url, onCompatibilityProgress: { [weak self] progress in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sourceReadID == readID else { return }
                let text = Self.compatibilityStatus(progress)
                if self.status != text { self.status = text }
            }
        })
    }

    private static func compatibilityStatus(_ progress: CompatibilityProgress) -> String {
        var message: String
        switch progress.stage {
        case .probing: return "正在识别素材封装"
        case .remuxing: message = "正在重封装兼容副本"
        case .convertingAudio: message = "正在复制视频并转换音轨"
        case .convertingVideo: message = "正在转换视频格式"
        case .validating: return "正在校验兼容副本"
        }
        if let fraction = progress.fraction, fraction.isFinite, fraction >= 0 {
            let percent = Int(min(99, fraction * 100))
            message += " · \(percent)%"
        }
        if let bytes = progress.bytesWritten, bytes > 0 {
            let written = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            message += " · 已写入 \(written)"
        }
        return message
    }

    func select(_ id: UUID, at offset: Double = 0) {
        guard !busy, let position = position(of: id) else { return }
        pause()
        seek(position + offset)
    }

    func seek(_ seconds: Double) {
        guard let time = movePlayhead(to: seconds) else { return }
        lastScrubSeek = -Double.infinity
        resumePreviewIfNeeded()
        seekPlayer(to: time)
    }

    func scrub(to seconds: Double) {
        guard let time = movePlayhead(to: seconds) else { return }
        let now = CACurrentMediaTime()
        guard now - lastScrubSeek >= scrubInterval else { return }
        resumePreviewIfNeeded()
        lastScrubSeek = now
        seekPlayer(to: time, tolerance: CMTime(value: 1, timescale: 15))
    }

    func togglePlayback() {
        guard !busy, !segments.isEmpty, player.currentItem?.status != .failed else { return }
        if playing { pause(); return }
        if playhead >= duration - 0.00001 { seek(0) }
        playing = true
        resumePreviewIfNeeded()
        startPlaybackIfReady()
    }

    private func suspendPreviewForExport() {
        pause()
        clearPreview()
        if !previewSuspended { previewSuspended = true }
    }

    func stepFrame(_ direction: Int) {
        guard !busy, let i = index(at: playhead) else { return }
        pause()
        let fps = max(1, segments.first?.source.fps ?? segments[i].source.fps)
        seek((round(playhead * fps) + Double(direction)) / fps)
    }

    func setIn() {
        guard !busy, !segments.isEmpty else { return }
        pause()
        markIn = snapped(playhead)
        if let out = markOut, let input = markIn, out <= input { markOut = nil }
        status = "已设入点"
    }

    func setOut() {
        guard !busy, !segments.isEmpty else { return }
        pause()
        markOut = snapped(playhead)
        if let input = markIn, let out = markOut, input >= out { markIn = nil }
        status = "已设出点"
    }

    func removeRange() {
        guard !busy, canRemoveRange, let a = markIn, let b = markOut else { return }
        erase(a..<b, message: "已删除选区")
    }

    func trimBefore() {
        guard !busy, let clip = selected, let first = position(of: clip.id) else { return }
        let cut = snapped(playhead)
        guard cut > first + 0.000001, cut < first + clip.end - clip.start - 0.000001 else {
            status = "请先把播放头移到片段内部"; return
        }
        erase(first..<cut, message: "已裁去片头")
    }

    func trimAfter() {
        guard !busy, let clip = selected, let first = position(of: clip.id) else { return }
        let cut = snapped(playhead), end = first + clip.end - clip.start
        guard cut > first + 0.000001, cut < end - 0.000001 else {
            status = "请先把播放头移到片段内部"; return
        }
        erase(cut..<end, message: "已裁去片尾")
    }

    func split() {
        guard !busy, let i = index(at: playhead) else { return }
        let clip = segments[i], begin = position(of: segments[i].id) ?? 0
        let cursor = snapped(playhead)
        let cut = clip.start + cursor - begin
        guard cut > clip.start + 0.000001, cut < clip.end - 0.000001 else {
            status = "请先把播放头移到片段内部"; return
        }
        record()
        let right = Segment(source: clip.source, start: cut, end: clip.end)
        segments.replaceSubrange(i...i, with: [
            Segment(id: clip.id, source: clip.source, start: clip.start, end: cut), right
        ])
        applyEdit(at: cursor, selection: right.id, message: "已在播放头处分割")
    }

    func deleteSelected() {
        guard !busy, let segment = selected, let first = position(of: segment.id) else { return }
        erase(first..<(first + segment.end - segment.start), message: "已删除片段")
    }

    func moveSelected(_ offset: Int) {
        guard !busy, let i = segments.firstIndex(where: { $0.id == selectedID }),
              segments.indices.contains(i + offset), offset != 0 else { return }
        let newIndex = i + offset
        let beforeIndex = i < newIndex ? newIndex + 1 : newIndex
        move(segments[i].id, before: beforeIndex < segments.count ? segments[beforeIndex].id : nil)
    }

    func move(_ id: UUID, before target: UUID?) {
        guard !busy, id != target, let i = segments.firstIndex(where: { $0.id == id }) else { return }
        var reordered = segments
        let clip = reordered.remove(at: i)
        let newIndex = target.flatMap { t in reordered.firstIndex { $0.id == t } } ?? reordered.count
        reordered.insert(clip, at: newIndex)
        guard reordered != segments else { return }
        record()
        segments = reordered
        applyEdit(at: position(of: id) ?? 0, selection: id, message: "已调整片段顺序")
    }

    func undo() {
        guard !busy, let previous = history.popLast() else { return }
        future.append(snapshot())
        restore(previous, message: "已撤销")
    }

    func redo() {
        guard !busy, let next = future.popLast() else { return }
        history.append(snapshot())
        restore(next, message: "已重做")
    }

    func exportKeyframeSelection(_ segment: Segment) {
        guard !busy, let trim = inwardTrimAmounts(for: segment) else { return }
        let precision = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...3))
        let head = trim.head.formatted(precision)
        let tail = trim.tail.formatted(precision)
        let alert = NSAlert()
        alert.messageText = "缩短到关键帧后快速导出？"
        alert.informativeText = "本次成片会从选段片头再裁掉 \(head) 秒，片尾再裁掉 \(tail) 秒，保留素材编码和码率。"
        alert.addButton(withTitle: "按上述剪点导出…")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            exportMovie(codecOverride: .passthrough, selectionOverride: segment)
        }
    }

    private func inwardTrimAmounts(for replacement: Segment) -> (head: Double, tail: Double)? {
        guard segments.count == 1, let original = segments.first, replacement.id == original.id,
              replacement.source == original.source, replacement.start < replacement.end,
              replacement.start >= original.start, replacement.end <= original.end else { return nil }
        let head = replacement.start - original.start, tail = original.end - replacement.end
        return head > 0 || tail > 0 ? (head, tail) : nil
    }

    func exportMovie(sample: Bool = false, codecOverride: ExportCodec? = nil, selectionOverride: Segment? = nil) {
        guard !busy, !segments.isEmpty else { return }
        let outputCodec = codecOverride ?? codec
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        if outputCodec == .passthrough {
            panel.title = "快速无损导出"
            panel.message = "复制原视频和音频码流，保留源编码与码率。"
        } else {
            panel.title = sample ? "试导出播放头后的 10 秒" : "\(outputCodec.rawValue) 压缩导出"
            if let sourceVideoMbps = sourceVideoMbpsBelowTarget {
                let source = sourceVideoMbps.formatted(.number.precision(.fractionLength(0...1)))
                let target = bitrateMbps.formatted(.number.precision(.fractionLength(0...1)))
                panel.message = "源视频平均约 \(source) Mbps。本次将以目标 \(target) Mbps 重新编码，成片可能更大。"
            }
        }
        let title = projectURL?.deletingPathExtension().lastPathComponent
            ?? segments[0].source.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = title + (sample ? "-试导出.mp4" : "-剪辑.mp4")
        if panel.runModal() == .OK, let url = panel.url {
            startExport(to: url, sample: sample, codecOverride: outputCodec, selectionOverride: selectionOverride)
        }
    }

    func startExport(to url: URL, sample: Bool = false, codecOverride: ExportCodec? = nil,
                     selectionOverride: Segment? = nil) {
        guard !busy, let firstSource = segments.first?.source else { return }
        let outputCodec = codecOverride ?? codec
        guard !sample || outputCodec != .passthrough else { return }
        guard !protectedURL(url) else { errorMessage = "请选择其他文件名，导出位置与素材或工程重合。"; return }
        let clips: [Segment]
        if let selectionOverride {
            guard !sample, outputCodec == .passthrough, inwardTrimAmounts(for: selectionOverride) != nil else { return }
            clips = [selectionOverride]
        } else if sample {
            let cursor = playhead < duration - 0.000001 ? playhead : max(0, duration - 10)
            let frame = MediaEngine.frameDuration(firstSource.fps).seconds
            let start = min(duration, floor(cursor / frame + 1e-8) * frame)
            clips = slice(start..<min(duration, start + 10))
        } else {
            clips = segments
        }
        guard !clips.isEmpty else { return }
        suspendPreviewForExport()
        let outputSize: ExportSize = outputCodec == .passthrough ? .original : size
        let bitrate = bitrateMbps
        let timelineDuration = duration
        let id = UUID()
        exportID = id
        encodingStartedAt = outputCodec == .passthrough ? nil : ProcessInfo.processInfo.systemUptime
        busy = true
        isExporting = true
        progress = 0
        errorMessage = nil
        if outputCodec == .passthrough {
            status = "正在复制原始码流"
        } else {
            status = sample ? "正在试导出 \(outputCodec.rawValue)" : "正在重新编码 \(outputCodec.rawValue)"
        }
        exportTask = Task(priority: .utility) { [self] in
            defer {
                encodingStartedAt = nil
                busy = false; isExporting = false; exportID = nil; exportTask = nil
            }
            do {
                try await MediaEngine.export(clips, to: url, codec: outputCodec, size: outputSize,
                                             bitrateMbps: bitrate, referenceSource: firstSource) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.exportID == id, value.isFinite else { return }
                        let next = min(1, value)
                        if next > self.progress { self.progress = next }
                    }
                }
                progress = 1
                lastExport = url
                status = "已导出 \(url.lastPathComponent)"
                if let previous = measuredTrial, Self.sameFile(previous.url, url) { measuredTrial = nil }
                if sample {
                    if let result = await TrialExportResult.measure(url, timelineDuration: timelineDuration,
                                                                    codec: outputCodec, size: outputSize, bitrateMbps: bitrate) {
                        measuredTrial = result
                    } else {
                        status = "试样已导出，无法读取成片统计"
                    }
                }
            } catch {
                if Task.isCancelled || error is CancellationError { status = "已取消导出" }
                else { status = "导出失败"; errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        encodingStartedAt = nil
        status = "正在取消导出"
        exportTask?.cancel()
    }

    func cancelImport() {
        guard busy, !isExporting else { return }
        sourceReadID = nil
        status = "正在取消读取"
        importTask?.cancel()
    }

    private struct ProjectClip: Codable {
        var path: String
        var id: UUID
        var start: Double
        var end: Double
    }
    private struct Project: Codable {
        var version: Int
        var clips: [ProjectClip]
        var codec: String
        var size: String
        var bitrate: Double
    }

    func saveProject() {
        guard !busy else { return }
        if let url = projectURL { saveProject(to: url); return }
        saveProjectAs()
    }

    func saveProjectAs() {
        guard !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "qingjian") ?? .data]
        panel.nameFieldStringValue = projectURL?.lastPathComponent ?? "我的剪辑.qingjian"
        panel.directoryURL = projectURL?.deletingLastPathComponent()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveProject(to: url)
    }

    @discardableResult
    func saveProject(to url: URL) -> Bool {
        guard !busy else { return false }
        guard !segments.contains(where: { Self.sameFile($0.source.url, url) }) else {
            errorMessage = "请选择与素材不同的工程文件名。"; return false
        }
        let project = Project(version: 1, clips: segments.map {
            ProjectClip(path: $0.source.url.path, id: $0.id, start: $0.start, end: $0.end)
        }, codec: codec.rawValue, size: size.rawValue, bitrate: bitrateMbps)
        do {
            try JSONEncoder().encode(project).write(to: url, options: .atomic)
            projectURL = url
            markSaved()
            status = "已保存工程"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func openProject() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "qingjian") ?? .data]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadProject(from: url)
    }

    func loadProject(from url: URL) {
        guard !busy else { return }
        if hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = "打开其他工程前保存当前剪辑？"
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "直接打开")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                saveProject()
                guard !hasUnsavedChanges else { return }
            case .alertThirdButtonReturn: break
            default: return
            }
        }
        pause()
        busy = true
        status = "正在打开工程"
        errorMessage = nil
        importTask = Task {
            defer { busy = false; importTask = nil }
            do {
                let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
                guard project.version == 1, Set(project.clips.map(\.id)).count == project.clips.count,
                      let storedCodec = ExportCodec(rawValue: project.codec),
                      let storedSize = ExportSize(rawValue: project.size),
                      project.bitrate.isFinite, project.bitrate > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let projectDirectory = url.deletingLastPathComponent()
                var material: [String: SourceInfo] = [:]
                var clips: [Segment] = []
                for saved in project.clips {
                    try Task.checkCancellation()
                    let resource: SourceInfo
                    if let cached = material[saved.path] { resource = cached }
                    else {
                        if status != "正在打开工程" { status = "正在打开工程" }
                        let assetURL = saved.path.hasPrefix("/")
                            ? URL(fileURLWithPath: saved.path)
                            : URL(fileURLWithPath: saved.path, relativeTo: projectDirectory).standardizedFileURL
                        do { resource = try await inspectSource(assetURL) }
                        catch {
                            throw NSError(domain: "QingJian", code: 1, userInfo: [
                                NSLocalizedDescriptionKey: "无法读取工程素材 \(assetURL.lastPathComponent)。\n\(assetURL.path)\n\(error.localizedDescription)"
                            ])
                        }
                        material[saved.path] = resource
                    }
                    guard saved.start >= 0, saved.end > saved.start, saved.end <= resource.duration + 0.001,
                          saved.end.isFinite, saved.start.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                    clips.append(Segment(id: saved.id, source: resource, start: saved.start, end: min(saved.end, resource.duration)))
                }
                try Task.checkCancellation()
                history.removeAll(); future.removeAll()
                canUndo = false; canRedo = false
                segments = clips
                projectURL = url
                codec = storedCodec; size = storedCodec == .passthrough ? .original : storedSize; bitrateMbps = project.bitrate
                markSaved()
                applyEdit(at: 0, selection: clips.first?.id, message: "已打开工程")
            } catch {
                if Task.isCancelled { status = "已取消打开工程" }
                else { status = "工程打开失败"; errorMessage = error.localizedDescription }
            }
        }
    }

    private func pause() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if playing { playing = false }
    }

    private func startPlaybackIfReady() {
        guard playing, player.currentItem?.status == .readyToPlay, timeObserver == nil else { return }
        player.play()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 12), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playing, self.activeSeek == nil, self.pendingSeek == nil,
                      CACurrentMediaTime() - self.lastScrubSeek >= self.scrubInterval else { return }
                self.movePlayhead(to: self.player.currentTime().seconds)
            }
        }
    }

    @discardableResult
    private func movePlayhead(to seconds: Double) -> Double? {
        guard seconds.isFinite else { return nil }
        let time = min(duration, max(0, seconds))
        if playhead != time { playheadPosition.seconds = time }
        if let target = index(at: time), selectedID != segments[target].id {
            selectedID = segments[target].id
        }
        return time
    }

    private func seekPlayer(to seconds: Double, tolerance: CMTime = .zero) {
        guard player.currentItem != nil else { return }
        pendingSeek = PreviewSeek(time: CMTime(seconds: seconds, preferredTimescale: 600_000), tolerance: tolerance)
        performPendingSeek()
    }

    private func performPendingSeek() {
        guard activeSeek == nil, player.currentItem?.status == .readyToPlay, let request = pendingSeek else { return }
        pendingSeek = nil
        activeSeek = request
        let revision = previewRevision
        player.seek(to: request.time, toleranceBefore: request.tolerance, toleranceAfter: request.tolerance) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.previewRevision == revision else { return }
                self.activeSeek = nil
                if finished && self.pendingSeek == request { self.pendingSeek = nil }
                self.performPendingSeek()
            }
        }
    }

    private func position(of id: UUID) -> Double? {
        var time = 0.0
        for clip in segments {
            if clip.id == id { return time }
            time += clip.end - clip.start
        }
        return nil
    }

    private func index(at time: Double) -> Int? {
        var end = 0.0
        for (index, clip) in segments.enumerated() {
            end += clip.end - clip.start
            if time < end - 0.000001 { return index }
        }
        return segments.indices.last
    }

    private func snapped(_ time: Double) -> Double {
        guard let i = index(at: time), let begin = position(of: segments[i].id) else { return 0 }
        let clip = segments[i]
        let length = clip.end - clip.start
        if abs(time - begin) < 0.000001 { return begin }
        if abs(time - begin - length) < 0.000001 { return begin + length }
        let rate = max(1, clip.source.fps)
        let sourceTime = (max(0, time - begin) + clip.start) * rate
        let rounded = min(clip.end, max(clip.start, sourceTime.rounded() / rate))
        return begin + rounded - clip.start
    }

    private func slice(_ range: Range<Double>) -> [Segment] {
        var cursor = 0.0
        var result: [Segment] = []
        for clip in segments {
            let end = cursor + clip.end - clip.start
            let lower = max(range.lowerBound, cursor)
            let upper = min(range.upperBound, end)
            if upper - lower > 0.000001 {
                result.append(Segment(id: clip.id, source: clip.source,
                                      start: max(clip.start, clip.start + (lower - cursor)),
                                      end: min(clip.end, clip.start + (upper - cursor))))
            }
            cursor = end
        }
        return result
    }

    private func erase(_ range: Range<Double>, message: String) {
        let before = slice(0..<range.lowerBound)
        let after = slice(range.upperBound..<max(range.upperBound, duration))
        let ids = Set(before.map(\.id))
        let retained = before + after.map { clip in
            ids.contains(clip.id) ? Segment(source: clip.source, start: clip.start, end: clip.end) : clip
        }
        record()
        segments = retained
        applyEdit(at: range.lowerBound, selection: nil, message: message)
    }

    private struct Snapshot {
        let segments: [Segment]
        let selection: UUID?
        let playhead: Double
        let markIn: Double?
        let markOut: Double?
    }

    private func snapshot() -> Snapshot {
        Snapshot(segments: segments, selection: selectedID, playhead: playhead, markIn: markIn, markOut: markOut)
    }

    private func markSaved() {
        savedSegments = segments
        savedCodec = codec; savedSize = size; savedBitrate = bitrateMbps
    }

    private func record() {
        history.append(snapshot())
        if history.count > 60 { history.removeFirst() }
        future.removeAll()
        canUndo = !history.isEmpty
        canRedo = false
    }

    private func restore(_ state: Snapshot, message: String) {
        segments = state.segments
        canUndo = !history.isEmpty; canRedo = !future.isEmpty
        applyEdit(at: state.playhead, selection: state.selection, message: message)
        markIn = state.markIn; markOut = state.markOut
    }

    private func applyEdit(at cursor: Double, selection: UUID?, message: String) {
        pause()
        lastExport = nil
        measuredTrial = nil
        playheadPosition.seconds = min(duration, max(0, cursor))
        selectedID = selection ?? index(at: playhead).map { segments[$0].id }
        markIn = nil; markOut = nil
        status = message
        rebuildPreview()
    }

    private func resumePreviewIfNeeded() {
        if previewSuspended && !busy { rebuildPreview() }
    }

    private func clearPreview() {
        previewRevision += 1
        previewTask?.cancel()
        previewTask = nil
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if player.currentItem != nil { player.replaceCurrentItem(with: nil) }
        activeSeek = nil
        pendingSeek = nil
        lastScrubSeek = -Double.infinity
    }

    private func rebuildPreview() {
        clearPreview()
        if previewSuspended { previewSuspended = false }
        let revision = previewRevision
        let clips = segments
        guard !clips.isEmpty else { return }
        previewTask = Task { [weak self] in
            do {
                let item = try await MediaEngine.preview(clips)
                guard let self, !Task.isCancelled, self.previewRevision == revision else { return }
                self.previewTask = nil
                self.player.replaceCurrentItem(with: item)
                self.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.previewRevision == revision else { return }
                        switch item.status {
                        case .readyToPlay:
                            self.performPendingSeek()
                            self.startPlaybackIfReady()
                        case .failed:
                            self.pause()
                            self.errorMessage = item.error?.localizedDescription ?? "系统播放器无法播放这段视频。"
                        default: break
                        }
                    }
                }
                self.endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.previewRevision == revision else { return }
                        self.pause()
                        self.movePlayhead(to: self.duration)
                    }
                }
                if self.playhead > 0 { self.seekPlayer(to: self.playhead) }
                self.startPlaybackIfReady()
            } catch {
                guard let self, !Task.isCancelled, self.previewRevision == revision else { return }
                self.previewTask = nil
                self.pause()
                self.errorMessage = "预览准备失败。\n\(error.localizedDescription)"
            }
        }
    }

    private func protectedURL(_ url: URL) -> Bool {
        segments.contains { Self.sameFile($0.source.url, url) } || projectURL.map { Self.sameFile($0, url) } == true
    }

    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let left = try? FileManager.default.attributesOfItem(atPath: a.path),
              let right = try? FileManager.default.attributesOfItem(atPath: b.path),
              let inode = left[.systemFileNumber] as? NSNumber,
              let device = left[.systemNumber] as? NSNumber else { return false }
        return inode == right[.systemFileNumber] as? NSNumber && device == right[.systemNumber] as? NSNumber
    }
}
