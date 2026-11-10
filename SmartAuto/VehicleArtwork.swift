import CryptoKit
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

    /// Resized copies on disk. The ZONTES image server takes about two seconds to answer each
    /// request and sends several hundred KB per picture; its files never change, so a resized
    /// copy is kept for good.
    private static let diskDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("vehicle-artwork-resized", isDirectory: true)

    private static func diskURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(digest + ".png")
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
        let file = Self.diskURL(for: key)
        // Detached so downloads and decoding do not queue behind each other on this actor.
        let task = Task.detached(priority: .userInitiated) { () throws -> UIImage in
            if let saved = try? Data(contentsOf: file),
               let image = try? Self.decode(saved, maxPixelSize: maxPixelSize) {
                return image
            }
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let image = try Self.decode(data, maxPixelSize: maxPixelSize)
            if let png = image.pngData() {
                try? FileManager.default.createDirectory(at: Self.diskDirectory, withIntermediateDirectories: true)
                try? png.write(to: file, options: .atomic)
            }
            return image
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
        try? FileManager.default.removeItem(at: Self.diskDirectory)
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
