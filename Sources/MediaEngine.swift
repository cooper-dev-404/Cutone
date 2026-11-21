import Foundation
import AVFoundation
import CoreGraphics
import VideoToolbox
import Darwin

struct SourceInfo: Codable, Hashable, Sendable {
    let url: URL
    let duration: Double
    let fps: Double
    let width: Int
    let height: Int
    let hasAudio: Bool
    var preparedURL: URL? = nil
    var videoMbps: Double? = nil
}

struct Segment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var source: SourceInfo
    var start: Double
    var end: Double

    init(id: UUID = UUID(), source: SourceInfo, start: Double, end: Double) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
    }
}

enum ExportCodec: String, CaseIterable, Sendable {
    case hevc = "HEVC"
    case h264 = "H.264"
    case passthrough = "快速无损"
}

enum ExportSize: String, CaseIterable, Sendable {
    case original = "跟随首段"
    case uhd = "4K"
    case qhd = "1440p"
    case hd = "1080p"
}

private struct MediaIssue: LocalizedError {
    var errorDescription: String?
    init(_ reason: String) { errorDescription = reason }
}

enum MediaEngine {
    private struct Source {
        // AVAssetTrack holds a weak reference to its owning asset.
        let asset: AVURLAsset
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let videoRange: CMTimeRange
        let audioRange: CMTimeRange?
        let naturalSize: CGSize
        let transform: CGAffineTransform
        let info: SourceInfo

        init(_ url: URL, readBitrate: Bool = false) async throws {
            let file = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let video = try await file.loadTracks(withMediaType: .video).first,
                  try await file.load(.isComposable), try await video.load(.isDecodable) else {
                throw MediaIssue("无法剪辑「\(url.lastPathComponent)」中的视频轨道。请检查文件封装与编码。")
            }
            let range = try await video.load(.timeRange)
            let dimensions = try await video.load(.naturalSize)
            let orientation = try await video.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: dimensions).applying(orientation).standardized
            guard range.duration.seconds.isFinite, range.duration.seconds > 0,
                  bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width >= 1, bounds.height >= 1 else {
                throw MediaIssue("素材的视频时长或画面尺寸无效。")
            }
            let measuredFPS = try await Self.frameRate(of: video)
            let audioTracks = try await file.loadTracks(withMediaType: .audio)
            var audio = audioTracks.first
            if audioTracks.count > 1 {
                for track in audioTracks {
                    if try await track.load(.isEnabled) {
                        audio = track
                        break
                    }
                }
            }
            if let audio, try await !audio.load(.isDecodable) {
                throw MediaIssue("系统无法解码素材中选用的音轨。")
            }
            self.asset = file
            self.video = video
            self.audio = audio
            self.videoRange = range
            self.audioRange = try await audio?.load(.timeRange)
            self.naturalSize = dimensions
            self.transform = orientation
            let dataRate = readBitrate ? (try? await video.load(.estimatedDataRate)) : nil
            let videoMbps = dataRate.flatMap { $0.isFinite && $0 > 0 ? Double($0) / 1_000_000 : nil }
            self.info = SourceInfo(url: url, duration: range.duration.seconds,
                                   fps: measuredFPS.isFinite && measuredFPS > 0 ? measuredFPS : 30,
                                   width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded()),
                                   hasAudio: audio != nil, videoMbps: videoMbps)
        }

        private static func frameRate(of track: AVAssetTrack) async throws -> Double {
            let nominal = Double(try await track.load(.nominalFrameRate))
            // In MP4s with multiple edits, the nominal rate may include preroll that
            // never appears on screen. Check a bounded set of sample timestamps using
            // the media index, without decoding frames or scanning the source file.
            guard nominal.isFinite, nominal > 0,
                  let interval = try? await track.load(.minFrameDuration),
                  interval.isNumeric, interval > .zero else { return nominal }
            let candidate = 1 / interval.seconds
            let difference = abs(candidate - nominal) / nominal
            guard difference > 0.0001, difference < 0.02,
                  let edits = try? await track.load(.segments), edits.count > 1,
                  edits.allSatisfy({ !$0.isEmpty && $0.timeMapping.source.duration == $0.timeMapping.target.duration })
            else { return nominal }

            let boundaries = zip(edits, edits.dropFirst())
            guard boundaries.allSatisfy({ $0.timeMapping.target.end == $1.timeMapping.target.start }),
                  boundaries.contains(where: { $0.timeMapping.source.end != $1.timeMapping.source.start })
            else { return nominal }

            for index in Set([0, edits.count / 2, edits.count - 1]) {
                let range = edits[index].timeMapping.source
                let middle = range.start + CMTimeMultiplyByRatio(range.duration, multiplier: 1, divisor: 2)
                guard middle + CMTimeMultiply(interval, multiplier: 8) < range.end,
                      let cursor = track.makeSampleCursor(presentationTimeStamp: middle) else { return nominal }
                for _ in 0..<8 {
                    let previous = cursor.presentationTimeStamp
                    guard cursor.stepInPresentationOrder(byCount: 1) == 1,
                          cursor.presentationTimeStamp - previous == interval else { return nominal }
                }
            }
            return candidate
        }
    }

    static func inspect(_ url: URL, onCompatibilityProgress: @escaping @Sendable (CompatibilityProgress) -> Void = { _ in }) async throws -> SourceInfo {
        do {
            return try await Source(url, readBitrate: true).info
        } catch {
            try Task.checkCancellation()
            guard ["mp4", "mov", "m4v", "mkv", "ts", "mts", "m2ts", "avi", "webm", "flv", "wmv", "mpg", "mpeg", "mxf"].contains(url.pathExtension.lowercased()) else { throw error }
            let (prepared, info) = try await MediaCompatibility.prepare(url, progress: onCompatibilityProgress) {
                try await Source($0, readBitrate: true).info
            }
            return SourceInfo(url: url, duration: info.duration, fps: info.fps,
                              width: info.width, height: info.height, hasAudio: info.hasAudio,
                              preparedURL: prepared, videoMbps: info.videoMbps)
        }
    }

    static func frameDuration(_ fps: Double) -> CMTime {
        for numerator in [24000, 30000, 60000, 120000] where abs(fps - Double(numerator) / 1001) < 0.003 {
            return CMTime(value: 1001, timescale: Int32(numerator))
        }
        if abs(fps - fps.rounded()) < 0.0001, (1...1000).contains(fps.rounded()) {
            return CMTime(value: 1, timescale: Int32(fps.rounded()))
        }
        return CMTime(seconds: 1 / fps, preferredTimescale: 600000)
    }

    static func canvas(for source: SourceInfo, size: ExportSize) -> CGSize {
        let w = Double(source.width), h = Double(source.height)
        let ratio: Double
        switch size {
        case .original: ratio = 1
        case .uhd: ratio = min(3840 / max(w,h), 2160 / min(w,h))
        case .qhd: ratio = min(2560 / max(w,h), 1440 / min(w,h))
        case .hd: ratio = min(1920 / max(w,h), 1080 / min(w,h))
        }
        return CGSize(width: max(2, (w * ratio / 2).rounded() * 2),
                      height: max(2, (h * ratio / 2).rounded() * 2))
    }

    private struct Timeline {
        let asset: AVMutableComposition
        let composition: AVMutableVideoComposition
        let duration: CMTime
    }

    private static func build(_ segments: [Segment], size: ExportSize, fast: Bool = false,
                              referenceSource: SourceInfo? = nil) async throws -> Timeline {
        guard let first = segments.first else { throw MediaIssue("请先添加至少一个片段。") }
        // A short trial can start in a different source from the first clip of the project.
        let outputFormat = referenceSource ?? first.source
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaIssue("无法创建视频轨道。") }
        var audio: AVMutableCompositionTrack?
        var cache: [URL: Source] = [:]
        var videoEdits: [URL: [CMTimeMapping]] = [:]
        defer { withExtendedLifetime(cache) {} }
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var offset = CMTime.zero
        var videoDescription: CMFormatDescription?
        var audioDescription: CMFormatDescription?
        var firstTransform: CGAffineTransform?
        let renderSize = canvas(for: outputFormat, size: size)
        for (index, clip) in segments.enumerated() {
            try Task.checkCancellation()
            let url = clip.source.preparedURL ?? clip.source.url
            if cache[url] == nil { cache[url] = try await Source(url) }
            guard let source = cache[url] else { throw MediaIssue("素材已移除。") }
            guard clip.start.isFinite, clip.end.isFinite, clip.start >= 0, clip.end > clip.start,
                  clip.end <= source.info.duration + 0.0001 else { throw MediaIssue("片段的入点或出点超出素材范围。") }
            let timescale = max(60000, source.videoRange.duration.timescale)
            var start = source.videoRange.start + CMTime(seconds: clip.start, preferredTimescale: timescale)
            var end = min(source.videoRange.end, source.videoRange.start + CMTime(seconds: clip.end, preferredTimescale: timescale))
            if fast {
                let clipName = "第 \(index + 1) 段「\(clip.source.url.lastPathComponent)」"
                if let prepared = clip.source.preparedURL, !MediaCompatibility.preservesOriginalStreams(prepared) {
                    throw MediaIssue("\(clipName)在导入时已转换编码，请选用 HEVC 或 H.264。")
                }
                guard size == .original, abs(source.info.fps - first.source.fps) < 0.001,
                      source.info.hasAudio == first.source.hasAudio,
                      let description = try await source.video.load(.formatDescriptions).first,
                      [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC].contains(CMFormatDescriptionGetMediaSubType(description)),
                      videoDescription.map({ CFEqual($0, description) }) ?? true,
                      firstTransform.map({ $0 == source.transform }) ?? true
                else { throw MediaIssue("\(clipName)不满足快速无损条件。需使用规格一致的 H.264 或 HEVC 素材，并选择「跟随首段」。") }
                if let audio = source.audio {
                    guard let description = try await audio.load(.formatDescriptions).first,
                          CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC,
                          audioDescription.map({ CFEqual($0, description) }) ?? true
                    else { throw MediaIssue("\(clipName)的音轨不符合快速无损要求。快速无损支持规格一致的 AAC 音轨。") }
                    audioDescription = description
                }
                if start != source.videoRange.start || end != source.videoRange.end {
                    if videoEdits[url] == nil { videoEdits[url] = try await unscaledEdits(in: source.video) }
                    let edits = videoEdits[url] ?? []
                    start = try checkedSyncBoundary(start, in: source, edits: edits, label: "入点", clipName: clipName)
                    end = try checkedSyncBoundary(end, in: source, edits: edits, label: "出点", clipName: clipName)
                }
                videoDescription = description
                firstTransform = source.transform
                video.preferredTransform = source.transform
            }
            let range = CMTimeRange(start: start, end: end)
            guard range.duration > .zero else { throw MediaIssue("片段太短。") }
            try video.insertTimeRange(range, of: source.video, at: offset)
            if let input = source.audio, let availability = source.audioRange {
                let intersection = CMTimeRangeGetIntersection(range, otherRange: availability)
                if intersection.isValid && !intersection.isEmpty {
                    if audio == nil { audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                    guard let audio else { throw MediaIssue("无法创建音频轨道。") }
                    try audio.insertTimeRange(intersection, of: input, at: offset + (intersection.start - range.start))
                }
            }
            let bounds = CGRect(origin: .zero, size: source.naturalSize).applying(source.transform).standardized
            let scale = min(renderSize.width / bounds.width, renderSize.height / bounds.height)
            let dx = (renderSize.width - bounds.width * scale) / 2
            let dy = (renderSize.height - bounds.height * scale) / 2
            let transform = source.transform
                .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: dx, y: dy))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
            layer.setTransform(transform, at: offset)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: offset, duration: range.duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            offset = offset + range.duration
        }
        if let audio {
            let audioEnd = try await audio.load(.timeRange).end
            if audioEnd < offset {
                audio.insertEmptyTimeRange(CMTimeRange(start: audioEnd, end: offset))
            }
        }
        let rendered = AVMutableVideoComposition()
        rendered.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        rendered.renderSize = renderSize
        rendered.frameDuration = frameDuration(outputFormat.fps)
        rendered.instructions = instructions
        rendered.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        rendered.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        rendered.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return Timeline(asset: composition, composition: rendered, duration: offset)
    }

    static func preview(_ segments: [Segment]) async throws -> AVPlayerItem {
        let size: ExportSize = (segments.first.map { max($0.source.width, $0.source.height) > 1920 } ?? false) ? .hd : .original
        let timeline = try await build(segments, size: size)
        let item = AVPlayerItem(asset: timeline.asset)
        item.videoComposition = timeline.composition
        return item
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath() { return true }
        var a = stat(), b = stat()
        return stat(lhs.path, &a) == 0 && stat(rhs.path, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    static func export(_ segments: [Segment], to url: URL, codec: ExportCodec, size: ExportSize, bitrateMbps: Double,
                       referenceSource: SourceInfo? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard url.isFileURL else { throw MediaIssue("请选择本地导出位置。") }
        var sourceURLs = Set(segments.map { $0.source.url })
        sourceURLs.formUnion(segments.compactMap { $0.source.preparedURL })
        if let referenceSource {
            sourceURLs.insert(referenceSource.url)
            if let prepared = referenceSource.preparedURL { sourceURLs.insert(prepared) }
        }
        guard !sourceURLs.contains(where: { sameFile($0, url) }) else { throw MediaIssue("导出位置与源素材相同，请更换文件名。") }
        if codec != .passthrough {
            guard bitrateMbps.isFinite, (0.1...1000).contains(bitrateMbps) else { throw MediaIssue("请输入有效的视频码率（0.1–1000 Mbps）。") }
        }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".qingjian-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        let timeline = try await build(segments, size: size, fast: codec == .passthrough,
                                       referenceSource: codec == .passthrough ? nil : referenceSource)
        try Task.checkCancellation()
        if codec == .passthrough {
            try await copyCompressed(timeline, to: temp, progress: progress)
        } else {
            try await encode(timeline, to: temp, codec: codec, bitrate: Int(bitrateMbps * 1_000_000), progress: progress)
        }
        try Task.checkCancellation()
        guard !sourceURLs.contains(where: { sameFile($0, url) }) else { throw MediaIssue("目标文件现与源素材相同，请更换文件名。") }
        guard Darwin.rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        progress(1)
    }

    static func checkPassthrough(_ segments: [Segment]) async throws {
        let timeline = try await build(segments, size: .original, fast: true)
        try Task.checkCancellation()
        _ = try passthroughSession(for: timeline)
    }

    private static func unscaledEdits(in track: AVAssetTrack) async throws -> [CMTimeMapping] {
        try await track.load(.segments).filter { !$0.isEmpty && $0.timeMapping.source.duration == $0.timeMapping.target.duration }
            .map(\.timeMapping)
    }

    private static func checkedSyncBoundary(_ boundary: CMTime, in source: Source, edits: [CMTimeMapping],
                                            label: String, clipName: String) throws -> CMTime {
        if boundary == source.videoRange.start || boundary == source.videoRange.end { return boundary }
        // Sample cursors use media timestamps. A file edit can offset them from the track timeline.
        for edit in edits where CMTimeRangeContainsTime(edit.target, time: boundary) {
            let mediaTime = edit.source.start + (boundary - edit.target.start)
            let tolerance = CMTime(value: 1, timescale: 10_000)
            if let cursor = source.video.makeSampleCursor(presentationTimeStamp: mediaTime + tolerance),
               abs((cursor.presentationTimeStamp - mediaTime).seconds) < tolerance.seconds,
               cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                return edit.target.start + (cursor.presentationTimeStamp - edit.source.start)
            }
        }
        let seconds = (boundary - source.videoRange.start).seconds
        let time = seconds.formatted(.number.precision(.fractionLength(0...3)))
        throw MediaIssue("\(clipName)的\(label)（素材 \(time) 秒）未对齐关键帧。选用 HEVC 或 H.264 可保留原剪点。")
    }

    static func inwardKeyframeSelection(_ segment: Segment) async throws -> Segment? {
        let source = try await Source(segment.source.preparedURL ?? segment.source.url)
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end > segment.start else { return nil }
        let timescale = max(60_000, source.videoRange.duration.timescale)
        let start = source.videoRange.start + CMTime(seconds: segment.start, preferredTimescale: timescale)
        let end = min(source.videoRange.end, source.videoRange.start + CMTime(seconds: segment.end, preferredTimescale: timescale))
        guard let edit = try await unscaledEdits(in: source.video).first(where: {
            CMTimeRangeContainsTimeRange($0.target, otherRange: CMTimeRange(start: start, end: end))
        }) else { return nil }
        let searchSpan = CMTime(seconds: 5, preferredTimescale: timescale)
        let first = start == source.videoRange.start ? start : try nearbySyncSample(
            in: source.video, edit: edit, from: start, through: min(end, start + searchSpan), direction: 1)
        let last = end == source.videoRange.end ? end : try nearbySyncSample(
            in: source.video, edit: edit, from: end, through: max(start, end - searchSpan), direction: -1)
        guard let first, let last, first < last else { return nil }
        var adjusted = segment
        adjusted.start = first == start ? segment.start : (first - source.videoRange.start).seconds
        adjusted.end = last == end ? segment.end : (last - source.videoRange.start).seconds
        guard adjusted != segment, adjusted.start >= segment.start, adjusted.end <= segment.end else { return nil }
        try await checkPassthrough([adjusted])
        return adjusted
    }

    private static func nearbySyncSample(in track: AVAssetTrack, edit: CMTimeMapping, from boundary: CMTime,
                                         through limit: CMTime, direction: Int64) throws -> CMTime? {
        let mediaTime = edit.source.start + (boundary - edit.target.start)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: mediaTime) else { return nil }
        for _ in 0..<4096 {
            try Task.checkCancellation()
            let time = edit.target.start + (cursor.presentationTimeStamp - edit.source.start)
            guard time.isNumeric, direction > 0 ? time <= limit : time >= limit else { return nil }
            let isInside = direction > 0 ? time >= boundary : time <= boundary
            if isInside, cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue { return time }
            if cursor.stepInPresentationOrder(byCount: direction) != direction { return nil }
        }
        return nil
    }

    private static func passthroughSession(for timeline: Timeline) throws -> AVAssetExportSession {
        guard let session = AVAssetExportSession(asset: timeline.asset, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4) else { throw MediaIssue("这些片段无法直接封装为 MP4，请使用压缩导出。") }
        return session
    }

    private static func copyCompressed(_ timeline: Timeline, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let session = try passthroughSession(for: timeline)
        session.outputURL = url
        session.outputFileType = .mp4
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        progress(min(0.99, Double(session.progress)))
                        try? await Task.sleep(nanoseconds: 180_000_000)
                    }
                }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    session.exportAsynchronously { continuation.resume() }
                }
                group.cancelAll()
            }
            try Task.checkCancellation()
            guard session.status == .completed else { throw session.error ?? MediaIssue("快速导出失败。") }
        } onCancel: { session.cancelExport() }
    }

    private struct Stream {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        var finished = false
    }

    // AVFoundation's compositor treats frameDuration as a maximum rate and may omit
    // repeated frames. Hold each decoded image until the next presentation timestamp.
    private struct FrameSampler {
        let output: AVAssetReaderVideoCompositionOutput
        let interval: CMTime
        let end: CMTime
        private var time = CMTime.zero
        private var current: CMSampleBuffer?
        private var following: CMSampleBuffer?

        init(output: AVAssetReaderVideoCompositionOutput, interval: CMTime, end: CMTime) {
            self.output = output
            self.interval = interval
            self.end = end
        }

        mutating func nextSample() throws -> CMSampleBuffer? {
            if time >= end {
                // The last output interval can cover more than one remaining source frame.
                if following != nil {
                    while autoreleasepool(invoking: { output.copyNextSampleBuffer() != nil }) {
                        try Task.checkCancellation()
                    }
                    following = nil
                }
                return nil
            }
            if current == nil {
                current = output.copyNextSampleBuffer()
                following = output.copyNextSampleBuffer()
            }
            while let next = following, next.presentationTimeStamp <= time {
                current = next
                following = output.copyNextSampleBuffer()
            }
            guard let current else { throw MediaIssue("无法读取视频的首帧。") }
            let duration = min(interval, end - time)
            let pts = time
            time = time + interval
            if current.presentationTimeStamp == pts && current.duration == duration { return current }
            var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var result: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                               sampleBuffer: current, sampleTimingEntryCount: 1,
                                                               sampleTimingArray: &timing, sampleBufferOut: &result)
            guard status == noErr, let result else { throw MediaIssue("无法设置输出帧的时间戳。") }
            return result
        }
    }

    private static func encode(_ timeline: Timeline, to url: URL, codec: ExportCodec, bitrate: Int,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: timeline.asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        let videoTracks = try await timeline.asset.loadTracks(withMediaType: .video)
        let video = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        video.videoComposition = timeline.composition
        video.alwaysCopiesSampleData = false
        let interval = timeline.composition.frameDuration
        var frames = FrameSampler(output: video, interval: interval, end: timeline.duration)
        let canvas = timeline.composition.renderSize
        let system = ProcessInfo.processInfo
        // An export started by the user prioritizes throughput under normal power and thermal conditions.
        let prioritizeEfficiency = system.isLowPowerModeEnabled
            || system.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let settings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.width), AVVideoHeightKey: Int(canvas.height),
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 1 / interval.seconds,
                kVTCompressionPropertyKey_MaximizePowerEfficiency as String: prioritizeEfficiency
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let timescale = interval.timescale
        videoInput.mediaTimeScale = timescale < 60_000 ? timescale * ((60_000 + timescale - 1) / timescale) : timescale
        var streams = [Stream(output: video, input: videoInput)]
        let audioTracks = try await timeline.asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let audio = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            audio.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000, AVEncoderBitRateKey: 192000
            ])
            streams.append(Stream(output: audio, input: input))
        }
        for stream in streams {
            guard reader.canAdd(stream.output), writer.canAdd(stream.input) else { throw MediaIssue("系统无法处理当前轨道或导出设置。") }
            reader.add(stream.output)
            writer.add(stream.input)
        }
        try Task.checkCancellation()
        guard reader.startReading() else { throw reader.error ?? MediaIssue("读取素材失败。") }
        guard writer.startWriting() else { throw writer.error ?? MediaIssue("无法启动视频编码器。") }
        writer.startSession(atSourceTime: .zero)
        var lastReport = Date.distantPast
        while streams.contains(where: { !$0.finished }) {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? MediaIssue("编码中断。") }
            if reader.status == .failed { throw reader.error ?? MediaIssue("读取素材失败。") }
            var worked = false
            for index in streams.indices where !streams[index].finished && streams[index].input.isReadyForMoreMediaData {
                worked = true
                try autoreleasepool {
                    let stream = streams[index]
                    let sample = index == 0 ? try frames.nextSample() : stream.output.copyNextSampleBuffer()
                    if let sample {
                        guard stream.input.append(sample) else { throw writer.error ?? MediaIssue("无法写入编码帧。") }
                        if index == 0, Date().timeIntervalSince(lastReport) >= 0.15 {
                            progress(max(0, min(0.99, sample.presentationTimeStamp.seconds / timeline.duration.seconds)))
                            lastReport = Date()
                        }
                    } else {
                        stream.input.markAsFinished()
                        streams[index].finished = true
                    }
                }
            }
            if !worked { try await Task.sleep(nanoseconds: 8_000_000) }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? MediaIssue("读取素材未完成。") }
        writer.endSession(atSourceTime: timeline.duration)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaIssue("导出未完成。") }
    }
}
