import Foundation
import Darwin

private struct CompatibilityIssue: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CompatibilityProgress: Sendable {
    enum Stage: Sendable {
        case probing, remuxing, convertingAudio, convertingVideo, validating
    }

    let stage: Stage
    let fraction: Double?
    let bytesWritten: Int64?
}

private final class ChildHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func launch(_ p: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try p.run()
        process = p
    }
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}

enum MediaCompatibility {
    static let directoryKey = "QingJian.cacheFolder"
    private static let session = UUID().uuidString
    private static let lock = NSLock()
    private static var cached: [String: URL] = [:]
    private static var sessionFiles: Set<URL> = []
    private static var copiedStreams: Set<URL> = []

    static func preservesOriginalStreams(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return copiedStreams.contains(url)
    }

    private static func registered(_ key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return cached[key].flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    private static func keep(_ value: URL, key: String, lossless: Bool) {
        lock.lock()
        defer { lock.unlock() }
        cached[key] = value
        sessionFiles.insert(value)
        if lossless { copiedStreams.insert(value) }
    }
    private static func forget(_ url: URL, key: String) {
        lock.lock()
        defer { lock.unlock() }
        if cached[key] == url { cached.removeValue(forKey: key) }
    }
    static func cleanSession() {
        lock.lock()
        let files = sessionFiles
        cached.removeAll()
        sessionFiles.removeAll()
        copiedStreams.removeAll()
        lock.unlock()
        for url in files { try? FileManager.default.removeItem(at: url) }
        for folder in Set(files.map { $0.deletingLastPathComponent() }) { _ = rmdir(folder.path) }
    }
    private static func tool(_ name: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "MediaTools")
        else { throw CompatibilityIssue(message: "当前安装包缺少格式兼容工具。请使用完整的剪一刀应用包。") }
        return url
    }
    private struct ProgressReader {
        let stage: CompatibilityProgress.Stage
        let duration: Double?
        let report: @Sendable (CompatibilityProgress) -> Void
        var diagnostics = Data()
        private var partialLine = Data()
        private var fraction: Double?
        private var bytesWritten: Int64?
        private var didChange = false

        init(stage: CompatibilityProgress.Stage, duration: Double?, report: @escaping @Sendable (CompatibilityProgress) -> Void) {
            self.stage = stage
            self.duration = duration
            self.report = report
        }

        mutating func read(_ chunk: Data) {
            partialLine.append(chunk)
            while let newline = partialLine.firstIndex(of: 10) {
                let line = Data(partialLine[..<newline])
                partialLine.removeSubrange(...newline)
                readLine(line)
            }
            if partialLine.count > 8192 { partialLine = Data(partialLine.suffix(8192)) }
        }

        mutating func finish() -> Data {
            if !partialLine.isEmpty { readLine(partialLine) }
            return diagnostics
        }

        private mutating func readLine(_ data: Data) {
            let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                switch parts[0] {
                case "out_time_us":
                    if let time = Int64(parts[1]), time >= 0, let duration {
                        let value = min(0.99, Double(time) / 1_000_000 / duration)
                        if fraction.map({ value > $0 }) ?? true {
                            fraction = value
                            didChange = true
                        }
                    }
                    return
                case "total_size":
                    if let value = Int64(parts[1]), value >= 0, bytesWritten.map({ value > $0 }) ?? true {
                        bytesWritten = value
                        didChange = true
                    }
                    return
                case "progress":
                    if didChange {
                        report(CompatibilityProgress(stage: stage, fraction: fraction, bytesWritten: bytesWritten))
                        didChange = false
                    }
                    return
                case "frame", "fps", "bitrate", "out_time_ms", "out_time", "dup_frames", "drop_frames", "speed":
                    return
                default:
                    if parts[0].hasPrefix("stream_") && parts[0].hasSuffix("_q") { return }
                }
            }
            diagnostics.append(data)
            diagnostics.append(10)
            if diagnostics.count > 8192 { diagnostics.removeFirst(diagnostics.count - 8192) }
        }
    }

    private static func run(_ executable: URL, _ args: [String], progress: ProgressReader? = nil) async throws -> Data {
        let child = ChildHandle()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let process = Process()
                        let pipe = Pipe()
                        process.executableURL = executable
                        process.arguments = args
                        process.standardInput = FileHandle.nullDevice
                        process.standardOutput = pipe
                        process.standardError = pipe
                        do {
                            try child.launch(process)
                            var data = Data()
                            var progress = progress
                            while true {
                                let part = autoreleasepool { pipe.fileHandleForReading.availableData }
                                if part.isEmpty { break }
                                if progress != nil {
                                    progress?.read(part)
                                } else {
                                    data.append(part)
                                    if data.count > 1048576 { data.removeFirst(data.count - 1048576) }
                                }
                            }
                            process.waitUntilExit()
                            if let diagnostics = progress?.finish() { data = diagnostics }
                            guard process.terminationStatus == 0 else {
                                let detail = String(decoding: data.suffix(1000), as: UTF8.self)
                                throw CompatibilityIssue(message: "格式转换未完成。\n" + detail)
                            }
                            continuation.resume(returning: data)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: { child.stop() }
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
    static func prepare(_ original: URL, progress: @escaping @Sendable (CompatibilityProgress) -> Void,
                        inspect: (URL) async throws -> SourceInfo) async throws -> (URL, SourceInfo) {
        try Task.checkCancellation()
        let attributes = try original.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(original.standardizedFileURL.path)|\(attributes.fileSize ?? 0)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let cached = registered(key) {
            progress(CompatibilityProgress(stage: .validating, fraction: nil, bytesWritten: nil))
            do {
                let info = try await inspect(cached)
                try Task.checkCancellation()
                return (cached, info)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // Existing timeline segments may still refer to this cache path.
                forget(cached, key: key)
            }
        }
        progress(CompatibilityProgress(stage: .probing, fraction: nil, bytesWritten: nil))
        let probe = try tool("ffprobe"), converter = try tool("ffmpeg")
        let data = try await run(probe, ["-v","error","-protocol_whitelist","file","-show_entries",
            "stream=index,codec_type,codec_name,width,height:stream_disposition=default:format=duration","-of","json","-i",original.path])
        try Task.checkCancellation()
        let info = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let streams = info?["streams"] as? [[String: Any]] ?? []
        guard let video = streams.first(where: { $0["codec_type"] as? String == "video" }),
              let codec = video["codec_name"] as? String else {
            throw CompatibilityIssue(message: "文件中未找到可剪辑的视频轨道。")
        }
        let audioStreams = streams.filter { $0["codec_type"] as? String == "audio" }
        let audio = audioStreams.first { ($0["disposition"] as? [String: Int])?["default"] == 1 } ?? audioStreams.first
        let copy = ["h264","hevc","prores","mpeg4","mjpeg"].contains(codec)
        let convertsAudio = audio.map { $0["codec_name"] as? String != "aac" } ?? false
        let size = Double(attributes.fileSize ?? 0)
        let duration = Double((info?["format"] as? [String: Any])?["duration"] as? String ?? "")
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let pixels = Double(video["width"] as? Int ?? 1920) * Double(video["height"] as? Int ?? 1080)
        let rate = max(6_000_000, min(80_000_000, pixels * 5))
        let estimated = copy ? size : duration.map { $0 * (rate + 192_000) / 8 } ?? size
        let base = UserDefaults.standard.string(forKey: directoryKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("QingJian-" + session, isDirectory: true)
        let room = try base.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        if let room, Double(room) < estimated * 1.08 + 128_000_000 {
            throw CompatibilityIssue(message: String(format: "这一格式约需 %.1f GB 兼容缓存。请在「文件 → 兼容缓存位置」选择空间足够的磁盘后再导入。", estimated / 1e9))
        }
        // Budget the complete new PCM track on top of the original file size.
        let usePCM: Bool
        if copy && convertsAudio, let duration, let room {
            let pcmBytes = duration * 48_000 * 2 * 2
            usePCM = Double(room) >= (size + pcmBytes) * 1.08 + 128_000_000
        } else {
            usePCM = false
        }
        let url = folder.appendingPathComponent(UUID().uuidString + ".mov")
        var args = ["-nostdin","-v","error","-nostats","-progress","pipe:1","-stats_period","1",
                    "-n","-protocol_whitelist","file","-i",original.path,"-map","0:v:0"]
        if let audio {
            guard let index = audio["index"] as? Int else {
                throw CompatibilityIssue(message: "无法读取兼容转换的音轨编号。")
            }
            args += ["-map","0:\(index)"]
        }
        args += ["-sn","-dn"]
        if copy {
            args += ["-c:v","copy"]
            if codec == "hevc" { args += ["-tag:v","hvc1"] }
        } else {
            args += ["-c:v","h264_videotoolbox","-b:v",String(Int(rate)),"-pix_fmt","yuv420p"]
        }
        if usePCM {
            args += ["-c:a","pcm_s16le","-ar","48000","-ac","2"]
        } else if convertsAudio {
            args += ["-c:a","aac","-b:a","192k","-ac","2"]
        } else { args += ["-c:a","copy"] }
        let stage: CompatibilityProgress.Stage = !copy ? .convertingVideo : (convertsAudio ? .convertingAudio : .remuxing)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            progress(CompatibilityProgress(stage: stage, fraction: nil, bytesWritten: nil))
            let reader = ProgressReader(stage: stage, duration: duration, report: progress)
            _ = try await run(converter, args + [url.path], progress: reader)
            try Task.checkCancellation()
            progress(CompatibilityProgress(stage: .validating, fraction: nil, bytesWritten: nil))
            let prepared = try await inspect(url)
            try Task.checkCancellation()
            keep(url, key: key, lossless: copy && !convertsAudio)
            return (url, prepared)
        } catch {
            try? FileManager.default.removeItem(at: url)
            _ = rmdir(folder.path)
            throw error
        }
    }
}
