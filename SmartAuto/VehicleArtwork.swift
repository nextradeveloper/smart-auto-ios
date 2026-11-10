import ImageIO
import SwiftUI
import UIKit

/// Shared by the dashboard and catalog; decoded images have a bounded memory cost.
actor VehicleArtworkStore {
    static let shared = VehicleArtworkStore()
    private let images = NSCache<NSString, UIImage>()
    private var pending: [String: Task<UIImage, Error>] = [:]
    private let session: URLSession
    private var generation = 0

    init() {
        images.totalCostLimit = 24 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                          diskCapacity: 40 * 1024 * 1024,
                                          diskPath: "vehicle-artwork")
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func image(url: URL, maxPixelSize: Int) async throws -> UIImage {
        let requestGeneration = generation
        let key = "\(maxPixelSize):\(url.absoluteString)"
        if let image = images.object(forKey: key as NSString) { return image }
        if let task = pending[key] {
            let image = try await task.value
            guard generation == requestGeneration else { throw CancellationError() }
            return image
        }
        let session = session
        let task = Task<UIImage, Error> {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return try Self.decode(data, maxPixelSize: maxPixelSize)
        }
        pending[key] = task
        defer { if generation == requestGeneration { pending[key] = nil } }
        let image = try await task.value
        guard generation == requestGeneration else { throw CancellationError() }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        images.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    func clearCache() {
        generation += 1
        for task in pending.values { task.cancel() }
        pending.removeAll()
        images.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    nonisolated static func decode(_ data: Data, maxPixelSize: Int) throws -> UIImage {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        return UIImage(cgImage: thumbnail)
    }
}

struct VehicleArtwork: View {
    let url: URL
    let maxPixelSize: Int
    @State private var image: UIImage?
    @State private var loadedURL: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if loadedURL == url, let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed && loadedURL == url {
                Image(systemName: "motorcycle")
                    .resizable().scaledToFit().foregroundStyle(.secondary).padding(24)
            } else {
                SkeletonBlock()
            }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            failed = false
            do {
                let result = try await VehicleArtworkStore.shared.image(url: url, maxPixelSize: maxPixelSize)
                try Task.checkCancellation()
                loadedURL = url
                image = result
            } catch {
                guard !Task.isCancelled else { return }
                loadedURL = url
                failed = true
            }
        }
    }
}
