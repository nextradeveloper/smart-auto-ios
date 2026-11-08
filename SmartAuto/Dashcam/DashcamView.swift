import AVKit
import SwiftUI

/// The bike's camera: recordings from the front and rear cameras, photos, and a test for a live view.
struct DashcamView: View {
    private enum Page: Hashable { case front, rear, photos }

    @State private var page: Page = .front
    @State private var probing: String?
    @State private var probeResult: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("กล้อง", selection: $page) {
                Text("กล้องหน้า").tag(Page.front)
                Text("กล้องหลัง").tag(Page.rear)
                Text("รูป").tag(Page.photos)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch page {
            case .front: DashcamRecordings(camera: .front)
            case .rear: DashcamRecordings(camera: .rear)
            case .photos: DashcamPhotos()
            }
        }
        .navigationTitle("กล้องรถ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let probing {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(probing).font(.footnote)
                    }
                } else {
                    Button("ทดสอบภาพสด") { probe() }
                }
            }
        }
        .alert("ทดสอบภาพสด", isPresented: Binding(get: { probeResult != nil }, set: { if !$0 { probeResult = nil } })) {
            Button("ตกลง", role: .cancel) {}
        } message: {
            Text((probeResult ?? "") + "\nส่ง log ให้ดูผลละเอียด")
        }
    }

    @MainActor
    private func probe() {
        probing = "เริ่ม"
        Task {
            let summary = await DashcamClient().probeLiveView { step in probing = step }
            probing = nil
            probeResult = summary
        }
    }
}

// MARK: Recordings

private struct DashcamDay: Identifiable {
    let date: String
    let times: [String]
    var id: String { date }
}

private struct DashcamRecordings: View {
    let camera: DashcamClient.Camera
    @State private var days: [DashcamDay] = []
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        Group {
            if loading && days.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure, days.isEmpty {
                DashcamMessage(symbol: "wifi.exclamationmark", text: failure) { Task { await load() } }
            } else if days.isEmpty {
                DashcamMessage(symbol: "video.slash", text: "ยังไม่มีวิดีโอ", retry: nil)
            } else {
                List {
                    ForEach(days) { day in
                        Section(day.date) {
                            ForEach(day.times, id: \.self) { time in
                                NavigationLink(time) {
                                    DashcamVideoList(camera: camera, date: day.date, time: time)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .task(id: camera) { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let client = DashcamClient()
            var loaded: [DashcamDay] = []
            for date in try await client.dates(camera) {
                loaded.append(DashcamDay(date: date, times: try await client.times(camera, date: date)))
            }
            days = loaded
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct DashcamVideoList: View {
    let camera: DashcamClient.Camera
    let date: String
    let time: String
    @State private var videos: [DashcamClient.Video] = []
    @State private var failure: String?

    var body: some View {
        List(videos) { video in
            NavigationLink {
                DashcamPlayer(video: video)
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: video.thumbURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color(white: 0.15)
                    }
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(video.title.isEmpty ? video.name : video.title)
                        .lineLimit(2)
                }
            }
        }
        .overlay {
            if let failure, videos.isEmpty { DashcamMessage(symbol: "wifi.exclamationmark", text: failure, retry: nil) }
        }
        .navigationTitle("\(date) \(time)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                videos = try await DashcamClient().videos(camera, date: date, time: time)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private struct DashcamPlayer: View {
    let video: DashcamClient.Video
    @State private var player: AVPlayer?
    @State private var saved: URL?
    @State private var saving = false

    var body: some View {
        VStack {
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
            Spacer()
        }
        .background(Color.black)
        .navigationTitle(video.title.isEmpty ? video.name : video.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DashcamSaveButton(url: video.playURL, saved: $saved, saving: $saving)
            }
        }
        .onAppear {
            let player = AVPlayer(url: video.playURL)
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: Photos

private struct DashcamPhotos: View {
    @State private var pictures: [DashcamClient.Picture] = []
    @State private var loading = true
    @State private var failure: String?
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        Group {
            if loading && pictures.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure, pictures.isEmpty {
                DashcamMessage(symbol: "wifi.exclamationmark", text: failure) { Task { await load() } }
            } else if pictures.isEmpty {
                DashcamMessage(symbol: "photo", text: "ยังไม่มีรูป", retry: nil)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(pictures) { picture in
                            NavigationLink {
                                DashcamPhoto(picture: picture)
                            } label: {
                                AsyncImage(url: picture.url) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Color(white: 0.15)
                                }
                                .frame(minHeight: 110)
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                            }
                        }
                    }
                }
                .refreshable { await load() }
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            pictures = try await DashcamClient().pictures()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct DashcamPhoto: View {
    let picture: DashcamClient.Picture
    @State private var saved: URL?
    @State private var saving = false

    var body: some View {
        AsyncImage(url: picture.url) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DashcamSaveButton(url: picture.url, saved: $saved, saving: $saving)
            }
        }
    }
}

// MARK: Shared

/// Download first, then the system share sheet ("บันทึกวิดีโอ", AirDrop, LINE…).
private struct DashcamSaveButton: View {
    let url: URL
    @Binding var saved: URL?
    @Binding var saving: Bool

    var body: some View {
        if let saved {
            ShareLink(item: saved) { Image(systemName: "square.and.arrow.up") }
        } else if saving {
            ProgressView()
        } else {
            Button {
                saving = true
                Task {
                    saved = try? await DashcamClient().download(url)
                    saving = false
                }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
        }
    }
}

private struct DashcamMessage: View {
    let symbol: String
    let text: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("ลองอีกครั้ง", action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
