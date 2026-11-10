import AVKit
import SwiftUI

enum DashcamPlayback {
    static func seekTarget(current: Double, offset: Double, duration: Double) -> Double {
        let start = current.isFinite ? current : 0
        let end = duration.isFinite && duration > 0 ? duration : .greatestFiniteMagnitude
        return min(max(0, start + offset), end)
    }
}

@MainActor
final class DashcamPlaybackModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var ready = false
    @Published private(set) var buffering = false
    @Published private(set) var failure: String?
    @Published private(set) var speed: Float = 1
    private(set) var currentURL: URL?
    private var statusObservation: NSKeyValueObservation?
    private var timeObservation: NSKeyValueObservation?
    private var failedNotification: NSObjectProtocol?

    func load(_ url: URL) {
        stop()
        currentURL = url
        failure = nil
        buffering = true
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.defaultRate = speed
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.ready = item.status == .readyToPlay
                if item.status == .failed {
                    self.failure = "เล่นคลิปไม่ได้ ตรวจ Wi-Fi ของรถ หรือลองดาวน์โหลดคลิป"
                    self.buffering = false
                } else {
                    self.buffering = !self.ready || self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item, self.failure == nil else { return }
                self.buffering = waiting || !self.ready
            }
        }
        failedNotification = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                                     object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.failure = "การเล่นสะดุด ตรวจ Wi-Fi ของรถแล้วลองอีกครั้ง"
                self.buffering = false
            }
        }
        player.play()
    }

    func setSpeed(_ speed: Float) {
        self.speed = speed
        player.defaultRate = speed
        if player.rate != 0 { player.rate = speed }
    }

    func skip(_ seconds: Double) {
        guard ready else { return }
        let target = DashcamPlayback.seekTarget(current: player.currentTime().seconds, offset: seconds,
                                                duration: player.currentItem?.duration.seconds ?? .nan)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func stop() {
        player.pause()
        statusObservation = nil
        timeObservation = nil
        if let failedNotification { NotificationCenter.default.removeObserver(failedNotification) }
        failedNotification = nil
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        ready = false
        buffering = false
    }

    deinit { if let failedNotification { NotificationCenter.default.removeObserver(failedNotification) } }
}

private struct DashcamNativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) { controller.player = nil }
}

struct DashcamPlayer: View {
    @State private var videos: [DashcamClient.Video]
    @State private var index: Int
    @StateObject private var playback = DashcamPlaybackModel()
    @State private var fullscreen = false
    @Environment(\.scenePhase) private var scenePhase

    init(videos: [DashcamClient.Video], selected: DashcamClient.Video) {
        let playlist = videos.contains(where: { $0.id == selected.id }) ? videos : [selected] + videos
        _videos = State(initialValue: playlist)
        _index = State(initialValue: playlist.firstIndex(where: { $0.id == selected.id }) ?? 0)
    }
    private var video: DashcamClient.Video? { videos.indices.contains(index) ? videos[index] : nil }

    var body: some View {
        ScrollView {
            if let video {
                VStack(alignment: .leading, spacing: 20) {
                    VideoPlayer(player: playback.player)
                        .aspectRatio(16.0 / 9, contentMode: .fit)
                        .background(.black)
                    if let failure = playback.failure {
                        Text(failure).font(.subheadline).foregroundStyle(.orange)
                        Button("ลองเล่นอีกครั้ง") { playback.load(video.playURL) }
                    } else if playback.buffering {
                        HStack(spacing: 10) { ProgressView(); Text("กำลังโหลดวิดีโอจากกล้อง…").font(.footnote) }
                        Button("โหลดใหม่") { playback.load(video.playURL) }.font(.footnote)
                    }
                    Text(video.displayName).font(.headline).textSelection(.enabled)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        Button { playback.skip(-10) } label: { Label("ย้อน 10 วินาที", systemImage: "gobackward.10").labelStyle(.iconOnly) }
                            .disabled(!playback.ready)
                        Menu {
                            ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { speed in
                                Button("\(speed.formatted())×") { playback.setSpeed(speed) }
                            }
                        } label: { Text("\(playback.speed.formatted())×").monospacedDigit() }
                        .accessibilityLabel("ความเร็วการเล่น \(playback.speed.formatted()) เท่า")
                        Button { playback.skip(10) } label: { Label("ข้าม 10 วินาที", systemImage: "goforward.10").labelStyle(.iconOnly) }
                            .disabled(!playback.ready)
                        Button { fullscreen = true } label: { Label("เต็มจอ", systemImage: "arrow.up.left.and.arrow.down.right") }
                    }
                    .buttonStyle(.bordered)
                    HStack {
                        Button { index -= 1 } label: { Label("ก่อนหน้า", systemImage: "backward.end") }
                            .disabled(index == 0)
                        Spacer()
                        Text("\(index + 1) / \(videos.count)").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button { index += 1 } label: { Label("ถัดไป", systemImage: "forward.end") }
                            .disabled(index + 1 >= videos.count)
                    }
                    .buttonStyle(.bordered)
                    DashcamDownloadButton(url: video.playURL).id(video.id)
                }
                .padding(16)
            }
        }
        .background(AppTheme.background)
        .navigationTitle("ดูคลิป")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: video?.id) {
            if let video, playback.currentURL != video.playURL { playback.load(video.playURL) }
        }
        .onDisappear { if !fullscreen { playback.stop() } }
        .onChange(of: scenePhase) { if $0 != .active { playback.player.pause() } }
        .fullScreenCover(isPresented: $fullscreen) {
            NavigationStack {
                DashcamNativePlayer(player: playback.player)
                    .background(.black)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("ปิดเต็มจอ") { fullscreen = false } }
                    }
                    .navigationBarTitleDisplayMode(.inline)
            }
            .preferredColorScheme(.dark)
            .onAppear { OrientationLock.set(.allButUpsideDown, rotateTo: .landscapeRight) }
            .onDisappear { OrientationLock.set(.portrait, rotateTo: .portrait) }
        }
    }
}

struct DashcamPhotoViewer: View {
    @State private var pictures: [DashcamClient.Picture]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(pictures: [DashcamClient.Picture], selected: DashcamClient.Picture) {
        let gallery = pictures.contains(where: { $0.id == selected.id }) ? pictures : [selected] + pictures
        _pictures = State(initialValue: gallery)
        _index = State(initialValue: gallery.firstIndex(where: { $0.id == selected.id }) ?? 0)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $index) {
                    ForEach(Array(pictures.enumerated()), id: \.element.id) { position, picture in
                        DashcamPhotoPage(picture: picture, active: position == index)
                            .tag(position)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                if pictures.indices.contains(index) {
                    VStack(spacing: 8) {
                        Text(pictures[index].name).font(.footnote).lineLimit(2).textSelection(.enabled)
                        Text("\(index + 1) / \(pictures.count) · บีบหรือแตะสองครั้งเพื่อซูม")
                            .font(.caption).foregroundStyle(.secondary)
                        DashcamDownloadButton(url: pictures[index].url).id(pictures[index].id)
                    }
                    .padding(16)
                }
            }
            .background(.black)
            .navigationTitle("ดูภาพ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("ปิด") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { OrientationLock.set(.allButUpsideDown, rotateTo: .portrait) }
        .onDisappear { OrientationLock.set(.portrait, rotateTo: .portrait) }
    }
}

private struct DashcamPhotoPage: View {
    let picture: DashcamClient.Picture
    let active: Bool
    @State private var image: UIImage?
    @State private var failure = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image { DashcamZoomImage(image: image).accessibilityLabel(picture.name) }
            else if failure {
                DashcamMessage(symbol: "photo", text: "โหลดภาพไม่ได้ ตรวจ Wi-Fi ของรถ") { attempt += 1 }
            } else { ProgressView("กำลังโหลดภาพ…") }
        }
        .task(id: "\(active)-\(attempt)") {
            guard active else { image = nil; return }
            failure = false
            do {
                let loaded = try await DashcamImageStore.shared.image(picture.url, pixels: 4096)
                try Task.checkCancellation()
                image = loaded
            } catch { if !Task.isCancelled { failure = true } }
        }
    }
}

struct DashcamDownloadButton: View {
    let url: URL
    @State private var saved: URL?
    @State private var download: Task<Void, Never>?
    @State private var failure: String?
    @State private var request = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saved {
                ShareLink(item: saved) { Label("แชร์ไฟล์ / บันทึกไปยังไฟล์", systemImage: "square.and.arrow.up") }
            } else if download != nil {
                HStack {
                    ProgressView()
                    Text("กำลังดาวน์โหลด…").font(.subheadline)
                    Spacer()
                    Button("ยกเลิก") { request = UUID(); download?.cancel(); download = nil }
                }
            } else {
                Button {
                    failure = nil
                    let id = UUID()
                    request = id
                    download = Task {
                        defer { if request == id { download = nil } }
                        do {
                            let file = try await DashcamClient().download(url)
                            try Task.checkCancellation()
                            guard request == id else { return }
                            saved = file
                        } catch {
                            if !Task.isCancelled && request == id { failure = "ดาวน์โหลดไม่สำเร็จ ตรวจ Wi-Fi ของรถแล้วลองอีกครั้ง" }
                        }
                    }
                } label: { Label(failure == nil ? "ดาวน์โหลดไฟล์" : "ลองดาวน์โหลดอีกครั้ง", systemImage: "arrow.down.circle") }
            }
            if let failure { Text(failure).font(.footnote).foregroundStyle(.orange) }
        }
        .buttonStyle(.bordered)
        .onDisappear { request = UUID(); download?.cancel(); download = nil }
    }
}
