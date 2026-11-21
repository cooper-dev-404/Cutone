import AppKit
import AVFoundation
import Foundation

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ detail: String) { description = detail }
}

private final class CompatibilityEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CompatibilityProgress] = []

    var snapshot: [CompatibilityProgress] { lock.withLock { events } }

    func record(_ event: CompatibilityProgress) {
        lock.withLock { events.append(event) }
    }
}

@main @MainActor struct EditorRegression {
    static func check(_ yes: Bool, _ detail: String) throws {
        guard yes else { throw Failure(detail) }
        print("PASS", detail)
    }

    static func close(_ a: Double, _ b: Double) -> Bool { abs(a-b) < 0.0001 }

    static func checkLosslessEligibility(_ sourceURL: URL, in directory: URL) async throws {
        let source = try await MediaEngine.inspect(sourceURL)
        let entireFile = Segment(source: source, start: 0, end: source.duration)
        try await MediaEngine.checkPassthrough([entireFile])
        print("PASS lossless export accepts the whole H.264 fixture")

        let trimmed = Segment(source: source, start: 0.01, end: source.duration)
        var diagnostic: String?
        do {
            try await MediaEngine.checkPassthrough([trimmed])
        } catch {
            diagnostic = error.localizedDescription
        }
        try check(diagnostic?.contains("关键帧") == true, "lossless export identifies a non-keyframe cut")

        let selection = Segment(source: source, start: 0.5, end: 6.5)
        guard let adjusted = try await MediaEngine.inwardKeyframeSelection(selection) else {
            throw Failure("No inward keyframe selection")
        }
        try check(close(adjusted.start, 1.9) && close(adjusted.end, 173.0 / 30),
                  "optional keyframe selection removes only material inside both original edges")
        let short = Segment(source: source, start: 0.5, end: 1)
        let noSelection = try await MediaEngine.inwardKeyframeSelection(short)
        try check(noSelection == nil, "keyframe alternative requires a nonempty inward selection")

        let editor = Editor()
        editor.importFiles([sourceURL])
        try await settled(editor)
        guard var replacement = editor.segments.first else { throw Failure("Could not import lossless fixture") }
        replacement.start = adjusted.start
        replacement.end = adjusted.end
        let original = editor.segments
        let movie = directory.appendingPathComponent("keyframe-one-off.mp4")
        editor.startExport(to: movie, codecOverride: .passthrough, selectionOverride: replacement)
        try await settled(editor)
        guard editor.lastExport == movie else { throw Failure(editor.errorMessage ?? "One-off export did not finish") }
        let result = try await MediaEngine.inspect(movie)
        try check(editor.codec == .hevc && editor.segments == original && close(result.duration, replacement.end - replacement.start),
                  "one-off keyframe export preserves the timeline and compression settings")
    }

    // Each fixture has short white flashes and corresponding 1 kHz tones.
    // Decode the output tracks independently to compare the actual picture and sound.
    static func cueTimes(_ url: URL, media: AVMediaType) async throws -> [Double] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: media).first else {
            throw Failure("Missing \(media.rawValue) track in \(url.lastPathComponent)")
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = media == .video
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        decoded.alwaysCopiesSampleData = false
        reader.add(decoded)
        guard reader.startReading() else { throw reader.error ?? Failure("Cannot decode sync cues") }
        var cues: [Double] = []
        while let buffer = decoded.copyNextSampleBuffer() {
            let time = buffer.presentationTimeStamp.seconds
            guard time.isFinite, time >= 0 else { continue }
            let onset: Double?
            if media == .video {
                guard let image = buffer.imageBuffer else { throw Failure("Missing decoded cue frame") }
                CVPixelBufferLockBaseAddress(image, .readOnly)
                let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self).pointee ?? 0
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
                onset = luma > 180 ? time : nil
            } else {
                guard buffer.numSamples > 0, let description = buffer.formatDescription,
                      let pcm = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      pcm.mChannelsPerFrame > 0, let block = buffer.dataBuffer
                else { throw Failure("Missing decoded cue audio") }
                let channels = Int(pcm.mChannelsPerFrame)
                var samples = [Int16](repeating: 0, count: buffer.numSamples * channels)
                let status = samples.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == noErr else { throw Failure("Cannot read decoded PCM cue") }
                onset = samples.firstIndex(where: { abs(Int($0)) > 4_000 }).map {
                    time + Double($0 / channels) / pcm.mSampleRate
                }
            }
            // Each cue is 100 ms long, with more than 200 ms between cue starts.
            if let onset, cues.last.map({ onset - $0 > 0.2 }) ?? true { cues.append(onset) }
        }
        guard reader.status == .completed else { throw reader.error ?? Failure("Incomplete decoded cue read") }
        return cues
    }

    static func checkSyncCues(_ url: URL, expected: [Double], label: String) async throws {
        let video = try await cueTimes(url, media: .video)
        let audio = try await cueTimes(url, media: .audio)
        let frame = 1.0 / 30
        try check(video.count == expected.count && audio.count == expected.count
                  && zip(video, expected).allSatisfy { abs($0 - $1) < frame + 0.0001 }
                  && zip(audio, expected).allSatisfy { abs($0 - $1) < 0.012 }
                  && zip(video, audio).allSatisfy { abs($0 - $1) <= frame },
                  "\(label): picture \(video), audio \(audio), expected \(expected)")
    }

    static func checkAudioSync(_ fixtures: URL, in directory: URL) async throws {
        let a = try await MediaEngine.inspect(fixtures.appendingPathComponent("Sync-A-delayed-audio-30fps.mp4"))
        let b = try await MediaEngine.inspect(fixtures.appendingPathComponent("Sync-B-aligned-60fps.mp4"))
        let trimmed = [
            Segment(source: a, start: 0.3, end: 1),
            Segment(source: a, start: 0, end: 0.3),
            Segment(source: b, start: 0.37, end: 1.73),
            Segment(source: a, start: 0.15, end: 0.35)
        ]
        for codec in [ExportCodec.h264, .hevc] {
            let movie = directory.appendingPathComponent("sync-\(codec.rawValue).mp4")
            try await MediaEngine.export(trimmed, to: movie, codec: codec, size: .original, bitrateMbps: 2) { _ in }
            try await checkSyncCues(movie, expected: [0.5, 1.43, 2.13],
                                    label: "\(codec.rawValue) mixed-rate trims with silent gaps")
        }
        let lossless = directory.appendingPathComponent("sync-lossless.mp4")
        let whole = Segment(source: a, start: 0, end: a.duration)
        try await MediaEngine.export([whole, whole], to: lossless, codec: .passthrough, size: .original,
                                     bitrateMbps: 0) { _ in }
        try await checkSyncCues(lossless, expected: [0.8, 1.5, 2.8, 3.5], label: "lossless join with delayed audio")

        let earlyAudio = try await MediaEngine.inspect(fixtures.appendingPathComponent("Sync-C-delayed-picture.mp4"))
        let nativeDefault = try await MediaEngine.inspect(fixtures.appendingPathComponent("Sync-D-default-audio.mp4"))
        defer { MediaCompatibility.cleanSession() }
        let compatibleDefault = try await checkCompatibilityImport(
            fixtures.appendingPathComponent("Sync-D-default-audio.mkv"), lossless: true
        )
        let compatiblePCM = try await checkCompatibilityImport(
            fixtures.appendingPathComponent("Sync-E-default-pcm.mkv"), lossless: false
        )
        for (info, name, expected) in [
            (earlyAudio, "early-audio", [0.2, 0.8, 1.5]),
            (nativeDefault, "native-default-audio", [0.8, 1.5]),
            (compatibleDefault, "compatible-default-audio", [0.8, 1.5]),
            (compatiblePCM, "compatible-default-pcm", [0.8, 1.5])
        ] {
            let movie = directory.appendingPathComponent(name + ".mp4")
            try await MediaEngine.export([Segment(source: info, start: 0, end: info.duration)], to: movie,
                                         codec: .h264, size: .original, bitrateMbps: 2) { _ in }
            try await checkSyncCues(movie, expected: expected, label: name)
        }
    }

    static func checkCompatibilityImport(_ source: URL, lossless: Bool) async throws -> SourceInfo {
        let events = CompatibilityEvents()
        let info = try await MediaEngine.inspect(source, onCompatibilityProgress: { events.record($0) })
        guard let prepared = info.preparedURL else {
            throw Failure("Missing MKV compatibility copy for \(source.lastPathComponent)")
        }
        let bytes = Int64(try prepared.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let asset = AVURLAsset(url: prepared)
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first,
              let description = try await audio.load(.formatDescriptions).first,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { throw Failure("Missing audio format for \(source.lastPathComponent)") }
        let expectedAudioCodec = lossless ? kAudioFormatMPEG4AAC : kAudioFormatLinearPCM
        let expectedSampleRate: Double = lossless ? 44_100 : 48_000
        try check(info.url == source && info.hasAudio && info.width == 320 && info.height == 180
                  && abs(info.fps - 30) < 0.1 && abs(info.duration - 2) < 0.02 && bytes > 0
                  && CMFormatDescriptionGetMediaSubType(description) == expectedAudioCodec
                  && format.mSampleRate == expectedSampleRate
                  && MediaCompatibility.preservesOriginalStreams(prepared) == lossless,
                  "MKV import retains dimensions, frame rate and selected audio (\(source.lastPathComponent))")
        let updates = events.snapshot
        let writes = updates.filter {
            (lossless ? $0.stage == .remuxing : $0.stage == .convertingAudio) && ($0.bytesWritten ?? 0) > 0
        }
        try check(updates.first?.stage == .probing && updates.last?.stage == .validating && !writes.isEmpty
                  && updates.allSatisfy {
                      ($0.fraction.map { $0.isFinite && (0...1).contains($0) } ?? true)
                      && ($0.bytesWritten.map { $0 >= 0 && $0 <= bytes } ?? true)
                  }, "MKV import reports compatible phases and written bytes (\(source.lastPathComponent))")
        return info
    }

    static func checkCompatibilityCancellation(_ source: URL, in directory: URL) async throws {
        let cache = directory.appendingPathComponent("cancelled-mkv-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let preferences = UserDefaults.standard
        let previousLocation = preferences.object(forKey: MediaCompatibility.directoryKey)
        preferences.set(cache.path, forKey: MediaCompatibility.directoryKey)
        defer {
            MediaCompatibility.cleanSession()
            preferences.set(previousLocation, forKey: MediaCompatibility.directoryKey)
        }
        let events = CompatibilityEvents()
        let releaseProgress = DispatchSemaphore(value: 0)
        let importTask = Task {
            try await MediaEngine.inspect(source, onCompatibilityProgress: { event in
                let firstWrite = event.stage == .remuxing && (event.bytesWritten ?? 0) > 0
                    && !events.snapshot.contains { $0.stage == .remuxing && ($0.bytesWritten ?? 0) > 0 }
                events.record(event)
                // Hold the first byte update so cancellation wins even on a tiny fixture.
                if firstWrite { _ = releaseProgress.wait(timeout: .now() + 10) }
            })
        }
        do {
            try await waitFor("MKV remux to write bytes") {
                events.snapshot.contains { $0.stage == .remuxing && ($0.bytesWritten ?? 0) > 0 }
            }
        } catch {
            importTask.cancel()
            releaseProgress.signal()
            _ = await importTask.result
            throw error
        }
        importTask.cancel()
        releaseProgress.signal()
        guard case .failure(let error) = await importTask.result, error is CancellationError else {
            throw Failure("Cancelling an MKV remux after bytes are written must stop the import")
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        try check(remaining.isEmpty, "cancelled MKV remux removes its partly written cache")
    }

    static func checkEditedSource(_ sourceURL: URL, in directory: URL) async throws {
        let source = AVURLAsset(url: sourceURL)
        defer { withExtendedLifetime(source) {} }
        let composition = AVMutableComposition()
        guard let original = try await source.loadTracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure("Missing video track for edit-list fixture")
        }
        let range = try await original.load(.timeRange)
        var position = CMTime.zero
        // Repeated unscaled edits share the original 30 fps grid, including their joins.
        for seconds: Int64 in [8, 8, 4] {
            let length = CMTime(value: seconds, timescale: 1)
            try track.insertTimeRange(CMTimeRange(start: range.start, duration: length), of: original, at: position)
            position = position + length
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure("Cannot create edit-list fixture")
        }
        let edited = directory.appendingPathComponent("repeated-cuts.mp4")
        session.outputURL = edited
        session.outputFileType = .mp4
        await session.export()
        guard session.status == .completed else { throw session.error ?? Failure("Failed to export edit-list fixture") }
        let info = try await MediaEngine.inspect(edited)
        try check(close(info.duration, 20) && close(info.fps, 30),
                  "20-second passthrough edit list preserves the source 30 fps (reported \(info.fps))")
    }

    // Encoders may reorder frames. Check every compressed sample in presentation order.
    static func checkFrameGrid(_ url: URL, fps: Int32, frames: Int) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure("No output video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let packets = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        packets.alwaysCopiesSampleData = false
        reader.add(packets)
        guard reader.startReading() else { throw reader.error ?? Failure("Failed to inspect output frames") }
        var times: [CMTime] = []
        while let buffer = packets.copyNextSampleBuffer() {
            for index in 0..<CMSampleBufferGetNumSamples(buffer) {
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(buffer, at: index, timingInfoOut: &timing) == noErr else {
                    throw Failure("Missing sample time")
                }
                times.append(timing.presentationTimeStamp)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? Failure("Incomplete frame read") }
        let sorted = times.sorted()
        // Compressed samples may include a constant B-frame composition-time offset.
        // The track's edit list maps its first displayed sample to timeline zero.
        let range = try await track.load(.timeRange)
        guard let first = sorted.first else { throw Failure("No compressed video samples") }
        try check(close(range.start.seconds, 0) && sorted.count == frames && sorted.enumerated().allSatisfy {
            close(($0.element - first).seconds, Double($0.offset) / Double(fps))
        }, "\(frames) video frames on the \(fps) fps presentation grid (\(url.lastPathComponent))")
    }

    static func settled(_ editor: Editor) async throws {
        try await waitFor("operation to complete", timeout: 70) { !editor.busy }
    }

    static func waitFor(_ detail: String, timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > limit { throw Failure("Timeout waiting for \(detail)") }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    static func main() async {
        do { try await run() }
        catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 3 else { throw Failure("Expected fixture directory and temporary output directory.") }
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let sources = ["A-2160p30-AVC.mp4", "B-1440p60-HEVC.mov"].map { fixtures.appendingPathComponent($0) }
        try await checkLosslessEligibility(sources[0], in: output)
        try await checkCompatibilityCancellation(fixtures.appendingPathComponent("Sync-D-default-audio.mkv"), in: output)
        try await checkAudioSync(fixtures, in: output)
        try await checkEditedSource(sources[0], in: output)
        let editor = Editor()
        editor.importFiles(sources)
        try await settled(editor)
        try check(editor.segments.count == 2 && close(editor.duration, 14), "mixed source import 8+6 s \(editor.errorMessage ?? "")")
        editor.togglePlayback()
        let playbackDeadline = Date().addingTimeInterval(9)
        while editor.playhead < 0.15, Date() < playbackDeadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try check(editor.playhead > 0.1 && editor.playing, "player preview advances after import")
        editor.togglePlayback()
        try check(!editor.playing, "player pause")
        for index in 1...80 {
            editor.scrub(to: Double(index) / 80)
        }
        editor.seek(2.3)
        try await waitFor("exact scrub target") { close(editor.player.currentTime().seconds, 2.3) }
        try check(close(editor.playhead, 2.3), "scrub finishes at the final exact position")
        editor.seek(editor.duration)
        try await waitFor("exact timeline end") { close(editor.player.currentTime().seconds, editor.duration) }
        try check(close(editor.playhead, editor.duration), "exact seek reaches the end of the timeline")
        editor.seek(2); editor.stepFrame(1)
        try check(close(editor.playhead, 61.0 / 30.0), "timeline frame stepping")
        editor.seek(1); editor.trimBefore()
        try check(close(editor.duration, 13) && close(editor.segments[0].start, 1), "trim start")
        editor.seek(5.5); editor.trimAfter()
        try check(close(editor.duration, 11.5) && close(editor.segments[0].end, 6.5), "trim end")
        editor.seek(2); editor.setIn(); editor.seek(4); editor.setOut()
        try check(editor.canRemoveRange, "range selected")
        editor.removeRange()
        try check(editor.segments.count == 3 && close(editor.duration, 9.5)
            && close(editor.segments[0].end,3) && close(editor.segments[1].start,5)
            && editor.segments[0].id != editor.segments[1].id, "delete middle, ripple & distinct identities")
        editor.seek(2.5); editor.split()
        try check(editor.segments.count == 4 && close(editor.segments[1].end, 5.5) && close(editor.segments[2].start, 5.5), "split at cursor")
        let originalOrder = editor.segments
        let target = editor.segments.last!.id
        editor.move(target, before: editor.segments[0].id)
        let reordered = editor.segments
        try check(reordered[0].id == target, "reorder across timeline")
        editor.undo(); try check(editor.segments == originalOrder, "undo")
        editor.redo(); try check(editor.segments == reordered, "redo")
        editor.codec = .h264; editor.size = .hd; editor.bitrateMbps = 8
        let project = output.appendingPathComponent("sample.qingjian")
        try check(editor.saveProject(to: project) && !editor.hasUnsavedChanges, "save timeline and export settings")
        editor.undo(); try check(editor.hasUnsavedChanges, "undo after save marks dirty")
        editor.redo(); try check(!editor.hasUnsavedChanges, "redo back to saved version")
        editor.bitrateMbps = 11; try check(editor.hasUnsavedChanges, "export setting change marks dirty")
        let loaded = Editor()
        loaded.loadProject(from: project)
        try await settled(loaded)
        try check(loaded.segments == reordered && loaded.codec == .h264 && loaded.size == .hd
            && loaded.bitrateMbps == 8 && !loaded.hasUnsavedChanges, "project round trip \(loaded.errorMessage ?? "")")
        var invalid = try JSONSerialization.jsonObject(with: Data(contentsOf: project)) as! [String:Any]
        var clips = invalid["clips"] as! [[String:Any]]
        clips[0]["path"] = output.appendingPathComponent("missing.mov").path
        invalid["clips"] = clips
        let broken = output.appendingPathComponent("broken.qingjian")
        try JSONSerialization.data(withJSONObject: invalid).write(to: broken)
        loaded.loadProject(from: broken)
        try await settled(loaded)
        try check(loaded.segments == reordered && loaded.errorMessage != nil && loaded.projectURL == project, "missing source preserves current project")
        loaded.clearError()
        loaded.startExport(to: sources[0]); try check(loaded.errorMessage != nil && !loaded.isExporting, "protect original video on export")
        loaded.clearError()
        try check(!loaded.saveProject(to: sources[1]), "protect source from project save")
        loaded.clearError()
        loaded.seek(5); loaded.setIn(); loaded.seek(7); loaded.setOut(); loaded.removeRange()
        try check(close(loaded.duration, 7.5) && close(loaded.segments[0].end, 5)
            && close(loaded.segments[1].start, 2), "delete across two sources")
        loaded.undo()
        loaded.select(loaded.segments[0].id); loaded.moveSelected(1)
        try check(loaded.segments[1].id == target, "move one position")
        loaded.deleteSelected(); try check(loaded.segments.count == 3 && close(loaded.duration, 3.5), "delete selected segment")
        loaded.undo(); loaded.undo()
        loaded.seek(0); loaded.setIn(); loaded.seek(loaded.duration); loaded.setOut(); loaded.removeRange()
        try check(loaded.segments.isEmpty && !loaded.canRemoveRange && loaded.selectedID == nil, "remove full range")
        loaded.undo(); try check(loaded.segments == reordered, "undo restores removed timeline")
        let trialStart = loaded.duration - 1
        loaded.seek(trialStart)
        try await waitFor("preview to be ready at the trial start") {
            loaded.player.currentItem?.status == .readyToPlay && close(loaded.player.currentTime().seconds, trialStart)
        }
        let trialSelection = loaded.selectedID
        let preview = output.appendingPathComponent("sample.mp4")
        loaded.startExport(to: preview, sample: true)
        try check(loaded.previewSuspended && loaded.player.currentItem == nil && !loaded.playing,
                  "export detaches the prepared player item")
        try await settled(loaded)
        try check(loaded.previewSuspended && loaded.player.currentItem == nil && close(loaded.playhead, trialStart)
                  && loaded.selectedID == trialSelection, "preview stays suspended at the same cursor after export")
        guard loaded.lastExport == preview else { throw Failure("sample export: \(loaded.errorMessage ?? loaded.status)") }
        let info = try await MediaEngine.inspect(preview)
        try check(close(info.duration, 1) && info.width == 1920 && info.height == 1080 && close(info.fps, 60),
                  "one-second sample retains project 60 fps at 1080p (actual \(info.width)×\(info.height) @ \(info.fps), \(info.duration) s)")
        try await checkFrameGrid(preview, fps: 60, frames: 60)
        guard let trial = loaded.trialResult else { throw Failure("No measured trial after export") }
        let bytes = try Data(contentsOf: preview).count
        try check(trial.url == preview && trial.bytes == Int64(bytes) && close(trial.duration, info.duration)
                  && trial.codec == .h264 && trial.size == .hd && trial.bitrateMbps == 8,
                  "measured sample carries the completed file size, duration and export settings")
        let projected = Int64((Double(bytes) * loaded.duration / info.duration).rounded())
        try check(trial.estimatedMovieBytes == projected, "estimate scales the actual one-second sample to the whole timeline")
        let resumeTarget = trialStart - 0.25
        loaded.seek(resumeTarget)
        try await waitFor("preview to reopen at the seek target") {
            loaded.player.currentItem?.status == .readyToPlay && close(loaded.player.currentTime().seconds, resumeTarget)
        }
        try check(!loaded.previewSuspended && !loaded.playing && close(loaded.playhead, resumeTarget),
                  "a seek reopens the preview at the exact target and keeps it paused")
        let missingParent = output.appendingPathComponent("missing-directory/sample.mp4")
        loaded.startExport(to: missingParent, sample: true)
        try await settled(loaded)
        try check(loaded.errorMessage != nil && !FileManager.default.fileExists(atPath: missingParent.path)
                  && loaded.lastExport == preview && loaded.trialResult?.url == preview,
                  "failed trial preserves the last completed measurement")
        loaded.clearError()
        let cancelled = output.appendingPathComponent("cancelled.mp4")
        loaded.startExport(to: cancelled, sample: true); loaded.cancelExport()
        try await settled(loaded)
        try check(!FileManager.default.fileExists(atPath: cancelled.path) && loaded.status.contains("取消")
                  && loaded.trialResult?.url == preview && loaded.lastExport == preview,
                  "cancelled trial preserves the prior measurement and leaves no partial result")
        try check(loaded.previewSuspended && loaded.player.currentItem == nil, "preview remains suspended after cancellation")
        loaded.togglePlayback()
        try await waitFor("playback to resume from the suspended cursor") {
            loaded.player.currentItem?.status == .readyToPlay && loaded.playing && loaded.playhead > resumeTarget + 0.1
        }
        try check(!loaded.previewSuspended, "play resumes a suspended preview from the current cursor")
        loaded.togglePlayback()
        loaded.bitrateMbps = 11
        try check(loaded.trialResult == nil, "bitrate change hides mismatched measurement")
        loaded.bitrateMbps = 8; loaded.codec = .hevc
        try check(loaded.trialResult == nil, "codec change hides mismatched measurement")
        loaded.codec = .h264; loaded.size = .qhd
        try check(loaded.trialResult == nil, "resolution change hides mismatched measurement")
        loaded.size = .hd
        try check(loaded.trialResult?.url == preview, "restoring matching settings reuses the measured sample")
        loaded.move(target, before: nil)
        try check(loaded.trialResult == nil && loaded.segments.first?.source.fps == 30
                  && loaded.segments.last?.source.fps == 60, "reorder invalidates a sample even at the same timeline length")
        loaded.size = .original
        loaded.seek(loaded.duration - 0.59)
        let secondPreview = output.appendingPathComponent("mixed-tail.mp4")
        loaded.startExport(to: secondPreview, sample: true)
        try await settled(loaded)
        let tail = try await MediaEngine.inspect(secondPreview)
        try check(tail.width == 3840 && tail.height == 2160 && close(tail.fps, 30) && close(tail.duration, 0.6),
                  "1440p60 tail uses the project 4K30 canvas and starts on its frame grid")
        try await checkFrameGrid(secondPreview, fps: 30, frames: 18)
        try check(loaded.trialResult?.url == secondPreview && close(loaded.trialResult?.duration ?? 0, tail.duration),
                  "new trial statistics report the actual subsecond tail duration")
        print("DONE")
    }
}
