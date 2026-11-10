import SwiftUI

struct DashcamView: View {
    private enum Page: Hashable { case videos, photos }
    @State private var page = Page.videos
    @State private var camera = DashcamClient.Camera.front
    @State private var query = ""
    @StateObject private var videos = DashcamVideoLibrary()
    @StateObject private var photos = DashcamPhotoLibrary()

    var body: some View {
        VStack(spacing: 0) {
            Picker("ประเภทไฟล์", selection: $page) {
                Text("วิดีโอ").tag(Page.videos)
                Text("รูปภาพ").tag(Page.photos)
            }
            .pickerStyle(.segmented)
            .padding(16)
            if page == .videos {
                Picker("เลือกกล้อง", selection: $camera) {
                    ForEach(DashcamClient.Camera.allCases) { camera in Text("กล้อง\(camera.title)").tag(camera) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                DashcamVideoBrowser(library: videos, camera: camera, query: query)
            } else {
                DashcamPhotoBrowser(library: photos, query: query)
            }
        }
        .background(AppTheme.background)
        .navigationTitle("กล้องรถ")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: page == .videos ? "ค้นหาชื่อคลิปในช่วงที่เลือก" : "ค้นหาชื่อภาพหรือวันที่ เช่น 2026-11-10")
        .onChange(of: page) { _ in query = "" }
        .onChange(of: camera) { _ in query = "" }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        if page == .videos { await videos.open(camera, refresh: true) }
                        else { await photos.load(refresh: true) }
                    }
                } label: { Label("รีเฟรชรายการ", systemImage: "arrow.clockwise") }
                .disabled(page == .videos ? videos.loading || videos.loadingMore : photos.loading)
            }
        }
    }
}

private struct DashcamVideoBrowser: View {
    @ObservedObject var library: DashcamVideoLibrary
    let camera: DashcamClient.Camera
    let query: String

    private var filtered: [DashcamClient.Video] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? library.videos : library.videos.filter {
            ($0.displayName + " " + $0.name).localizedStandardContains(text)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !library.dates.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { filters }
                        VStack(alignment: .leading, spacing: 8) { filters }
                    }
                    .disabled(library.loading || library.loadingMore)
                }
                if library.loading && library.videos.isEmpty {
                    DashcamLoadingRows()
                } else if let failure = library.failure, library.videos.isEmpty {
                    DashcamMessage(symbol: "wifi.exclamationmark", text: failure) {
                        Task { await library.open(camera, refresh: true) }
                    }
                } else if library.videos.isEmpty {
                    DashcamMessage(symbol: "video.slash", text: library.dates.isEmpty ? "ยังไม่มีคลิปจากกล้องนี้" : "ไม่มีคลิปในช่วงเวลานี้") {
                        Task { await library.open(camera, refresh: true) }
                    }
                } else {
                    Text("\(filtered.count) คลิป\(query.isEmpty ? "" : "ที่ตรงกับคำค้น") · กล้อง\(camera.title)")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let failure = library.failure {
                        Text(failure).font(.footnote).foregroundStyle(.orange)
                    }
                    if filtered.isEmpty {
                        Text("ไม่พบในคลิปที่โหลด ลองเลือกวันหรือช่วงเวลาอื่น")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { video in
                        NavigationLink {
                            DashcamPlayer(videos: filtered, selected: video)
                        } label: {
                            HStack(spacing: 14) {
                                DashcamThumbnail(url: video.thumbURL)
                                    .frame(width: 104, height: 66)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "play.fill").font(.caption).padding(6)
                                            .background(.black.opacity(0.7), in: Circle()).padding(4)
                                    }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(video.displayName).font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary).lineLimit(3)
                                    Text("\(DashcamLabels.date(library.date)) · \(library.time)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                    }
                    if library.hasMore {
                        Button {
                            Task { await library.loadMore() }
                        } label: {
                            HStack(spacing: 10) {
                                if library.loadingMore { ProgressView() }
                                Text(library.loadingMore ? "กำลังโหลดคลิป…" : "โหลดคลิปเพิ่มในช่วงนี้")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(library.loading || library.loadingMore)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await library.open(camera, refresh: true) }
        .task(id: camera) { await library.open(camera) }
    }

    private var filters: some View {
        Group {
            Menu {
                ForEach(library.dates, id: \.self) { date in
                    Button(DashcamLabels.date(date)) { Task { await library.selectDate(date) } }
                }
            } label: {
                Label(DashcamLabels.date(library.date), systemImage: "calendar")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("เลือกวันที่ \(DashcamLabels.date(library.date))")
            Menu {
                ForEach(library.times, id: \.self) { time in
                    Button(time) { Task { await library.selectTime(time) } }
                }
            } label: {
                Label(library.time.isEmpty ? "ไม่มีช่วงเวลา" : library.time, systemImage: "clock")
                    .frame(minHeight: 44)
            }
            .disabled(library.times.isEmpty)
            .accessibilityLabel("เลือกช่วงเวลา \(library.time)")
        }
        .buttonStyle(.bordered)
    }
}

private struct DashcamPhotoBrowser: View {
    @ObservedObject var library: DashcamPhotoLibrary
    let query: String
    @State private var day = "all"
    @State private var selected: DashcamClient.Picture?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchRequest = UUID()

    private var filtered: [DashcamClient.Picture] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.pictures.filter {
            (day == "all" || ($0.dateKey ?? "unknown") == day) &&
            (text.isEmpty || ($0.name + " " + ($0.dateKey ?? "")).localizedStandardContains(text))
        }
    }
    private var days: [String] { Set(library.pictures.compactMap(\.dateKey)).sorted(by: >) }
    private var groups: [String] {
        Set(filtered.map { $0.dateKey ?? "unknown" }).sorted {
            if $0 == "unknown" { return false }
            if $1 == "unknown" { return true }
            return $0 > $1
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !library.pictures.isEmpty {
                    Menu {
                        Button("ทุกวันที่โหลด") { day = "all" }
                        ForEach(days, id: \.self) { date in Button(date) { day = date } }
                        Button("ไม่ระบุวันที่") { day = "unknown" }
                    } label: {
                        Label(day == "all" ? "ทุกวันที่โหลด" : (day == "unknown" ? "ไม่ระบุวันที่" : day), systemImage: "calendar")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    Text("\(filtered.count) ภาพ · ค้นหาในภาพที่โหลดแล้ว")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure = library.failure {
                    DashcamMessage(symbol: "wifi.exclamationmark", text: failure) {
                        Task { await library.retry() }
                    }
                } else if library.loading && library.pictures.isEmpty {
                    DashcamLoadingRows()
                } else if filtered.isEmpty {
                    DashcamMessage(symbol: "photo", text: library.pictures.isEmpty ? "ยังไม่มีรูปภาพ" : "ไม่พบภาพ ลองเปลี่ยนวันที่หรือคำค้น", retry: nil)
                }
                ForEach(groups, id: \.self) { group in
                    Text(group == "unknown" ? "ไม่ระบุวันที่" : group).font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(filtered.filter { ($0.dateKey ?? "unknown") == group }) { picture in
                            Button { selected = picture } label: {
                                DashcamThumbnail(url: picture.url, symbol: "photo")
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("ดูภาพ \(picture.name)")
                        }
                    }
                }
                if searchTask != nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("กำลังค้นหาในภาพก่อนหน้า…").font(.footnote)
                        Spacer()
                        Button("ยกเลิก") { cancelSearch() }
                    }
                } else if filtered.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && library.hasMore {
                    Button("ค้นหาต่อในภาพก่อนหน้า") { searchEarlier() }
                        .buttonStyle(.bordered)
                        .disabled(library.loading)
                } else if library.hasMore && !library.pictures.isEmpty {
                    Button {
                        Task { await library.load() }
                    } label: {
                        HStack(spacing: 10) {
                            if library.loading { ProgressView() }
                            Text(library.loading ? "กำลังโหลดภาพ…" : "โหลดภาพก่อนหน้าเพิ่ม")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(library.loading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        }
        .refreshable { await library.load(refresh: true) }
        .task { await library.open() }
        .onChange(of: library.pictures) { _ in
            if day != "all" && day != "unknown" && !days.contains(day) { day = "all" }
        }
        .onChange(of: query) { _ in cancelSearch() }
        .onChange(of: day) { _ in cancelSearch() }
        .onDisappear { cancelSearch() }
        .fullScreenCover(item: $selected) { picture in
            DashcamPhotoViewer(pictures: filtered, selected: picture)
        }
    }

    private func searchEarlier() {
        let id = UUID()
        searchRequest = id
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedDay = day
        searchTask = Task {
            defer { if searchRequest == id { searchTask = nil } }
            await library.searchEarlier {
                (selectedDay == "all" || ($0.dateKey ?? "unknown") == selectedDay) &&
                ($0.name + " " + ($0.dateKey ?? "")).localizedStandardContains(text)
            }
        }
    }
    private func cancelSearch() {
        searchRequest = UUID()
        searchTask?.cancel()
        searchTask = nil
    }
}

struct DashcamMessage: View {
    let symbol: String
    let text: String
    let retry: (() -> Void)?
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let retry { Button("ลองอีกครั้ง", action: retry).buttonStyle(.bordered) }
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }
}

private struct DashcamLoadingRows: View {
    var body: some View {
        VStack(spacing: 16) {
            ForEach(0..<4) { _ in
                HStack(spacing: 14) {
                    SkeletonBlock().frame(width: 104, height: 66)
                    VStack(alignment: .leading, spacing: 10) {
                        SkeletonBlock().frame(height: 18)
                        SkeletonBlock().frame(width: 100, height: 12)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("กำลังโหลดรายการจากกล้อง")
    }
}
