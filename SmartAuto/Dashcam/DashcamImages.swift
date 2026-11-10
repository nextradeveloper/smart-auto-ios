import SwiftUI
import UIKit

/// Camera images stay in a bounded memory cache; viewing a photo doesn't save it to disk.
actor DashcamImageStore {
    static let shared = DashcamImageStore()
    private let cache = NSCache<NSString, UIImage>()
    private var pending: [String: Task<UIImage, Error>] = [:]
    private let session: URLSession
    private var generation = 0

    init() {
        cache.totalCostLimit = 16 * 1024 * 1024
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func image(_ url: URL, pixels: Int) async throws -> UIImage {
        let version = generation
        let key = "\(pixels):\(url.absoluteString)"
        if let image = cache.object(forKey: key as NSString) { return image }
        if let task = pending[key] {
            let image = try await task.value
            guard version == generation else { throw CancellationError() }
            return image
        }
        let session = session
        let task = Task<UIImage, Error> {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return try VehicleArtworkStore.decode(data, maxPixelSize: pixels)
        }
        pending[key] = task
        defer { if version == generation { pending[key] = nil } }
        let image = try await task.value
        guard version == generation else { throw CancellationError() }
        cache.setObject(image, forKey: key as NSString, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        return image
    }

    func clearCache() {
        generation += 1
        for task in pending.values { task.cancel() }
        pending.removeAll()
        cache.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }
}

struct DashcamThumbnail: View {
    let url: URL?
    var symbol = "video"
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        AppTheme.surface
                        Image(systemName: symbol).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            guard let loaded = try? await DashcamImageStore.shared.image(url, pixels: 360), !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// UIScrollView handles pinch, pan and double-tap without competing SwiftUI gestures.
struct DashcamZoomImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingPhotoScrollView { ZoomingPhotoScrollView() }
    func updateUIView(_ view: ZoomingPhotoScrollView, context: Context) {
        if view.picture.image !== image {
            view.setZoomScale(1, animated: false)
            view.picture.image = image
        }
    }
}

final class ZoomingPhotoScrollView: UIScrollView, UIScrollViewDelegate {
    let picture = UIImageView()
    private var previousSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        picture.contentMode = .scaleAspectFit
        addSubview(picture)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        panGestureRecognizer.isEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size {
            previousSize = bounds.size
            setZoomScale(1, animated: false)
            picture.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { panGestureRecognizer.isEnabled = zoomScale > 1 }
    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1 { setZoomScale(1, animated: true); return }
        let point = gesture.location(in: picture)
        let size = CGSize(width: bounds.width / 3, height: bounds.height / 3)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }
}
