import AVFoundation
import Combine
import SwiftUI

struct FilmThumbnail: View {
    let url: URL
    let seconds: Double
    @StateObject private var state = FilmThumbnailState()

    var body: some View {
        let request = FilmFrameRequest(url: url, seconds: seconds)
        Color.clear
            .overlay {
                if let loaded = state.frame, loaded.request == request {
                    GeometryReader { geometry in
                        Image(decorative: loaded.image, scale: 2)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                }
            }
            .task(id: request, priority: .utility) {
                // Briefly visible clips can disappear during a scroll before they need decoding.
                try? await Task.sleep(for: .milliseconds(100))
                if let image = await FilmFrameStore.shared.image(for: request), !Task.isCancelled {
                    state.frame = (request, image)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private final class FilmThumbnailState: ObservableObject {
    @Published var frame: (request: FilmFrameRequest, image: CGImage)?
}

private struct FilmFrameRequest: Hashable {
    let url: URL
    let seconds: Double

    var cacheKey: NSString { "\(url.absoluteString)\n\(seconds)" as NSString }
}

@MainActor
private final class FilmFrameStore {
    static let shared = FilmFrameStore()
    private let cache = NSCache<NSString, CGImage>()
    private var pending: (request: FilmFrameRequest, task: Task<CGImage?, Never>)?

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func image(for request: FilmFrameRequest) async -> CGImage? {
        guard request.url.isFileURL, request.seconds.isFinite, request.seconds >= 0 else { return nil }
        let key = request.cacheKey
        while !Task.isCancelled {
            if let image = cache.object(forKey: key) { return image }
            if let pending {
                let image = await pending.task.value
                if pending.request == request { return image }
                continue
            }

            // Keep only one decoder in flight and share work for identical requests.
            let task = Task(priority: .utility) {
                let image = await Self.generate(request)
                if let image {
                    cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
                }
                pending = nil
                return image
            }
            pending = (request, task)
            return await task.value
        }
        return nil
    }

    nonisolated private static func generate(_ request: FilmFrameRequest) async -> CGImage? {
        let asset = AVURLAsset(url: request.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange),
              request.seconds < range.duration.seconds else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 224, height: 128)
        let tolerance = CMTime(value: 1, timescale: 8)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let time = range.start + CMTime(seconds: request.seconds, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
