import MapKit
import SwiftUI

/// Apple Maps' search-as-you-type, for choosing where the dash should guide to.
@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { findSuggestions() }
    }
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?

    private var completer = MKLocalSearchCompleter()
    private var region: MKCoordinateRegion?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func focus(on location: CLLocation?) {
        guard let location else { return }
        region = MKCoordinateRegion(center: location.coordinate,
                                    latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        if let region { completer.region = region }
    }

    func retry() { findSuggestions() }

    func cancel() {
        completer.delegate = nil
        completer.cancel()
        completer = MKLocalSearchCompleter()
        isLoading = false
    }

    private func findSuggestions() {
        cancel()
        results = []
        failure = nil
        let fragment = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty else { return }
        // A new completer identifies this query, so callbacks from older text are ignored.
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        if let region { completer.region = region }
        isLoading = true
        completer.queryFragment = fragment
    }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> DashDestination {
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let item = response.mapItems.first else { throw ZontesError.message("ไม่พบสถานที่นี้") }
        var destination = DashDestination(item)
        if destination.subtitle.isEmpty {
            destination = DashDestination(name: destination.name, subtitle: completion.subtitle,
                                          coordinate: destination.coordinate)
        }
        return destination
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            guard self.completer === completer else { return }
            self.results = results
            self.failure = nil
            self.isLoading = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.completer === completer else { return }
            self.results = []
            self.failure = "ค้นหาสถานที่ไม่ได้ ตรวจอินเทอร์เน็ตแล้วลองอีกครั้ง"
            self.isLoading = false
        }
    }
}

/// A place found nearby and how far it is.
private struct NearbyPlace: Identifiable {
    let place: DashDestination
    let meters: Double
    var id: String { place.id }
}

/// Places riders stop at, one tap away: what is near, nearest first.
private enum QuickPlace: String, CaseIterable, Identifiable {
    case fuel, food, cafe

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fuel: return "ปั๊มน้ำมัน"
        case .food: return "ร้านอาหาร"
        case .cafe: return "คาเฟ่"
        }
    }
    var symbol: String {
        switch self {
        case .fuel: return "fuelpump.fill"
        case .food: return "fork.knife"
        case .cafe: return "cup.and.saucer.fill"
        }
    }
    var tint: Color {
        switch self {
        case .fuel: return .blue
        case .food: return .orange
        case .cafe: return .brown
        }
    }
    var category: MKPointOfInterestCategory {
        switch self {
        case .fuel: return .gasStation
        case .food: return .restaurant
        case .cafe: return .cafe
        }
    }

    /// Up to 15 within 10 km of `location`, nearest first.
    func nearby(_ location: CLLocation) async throws -> [NearbyPlace] {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: 10_000)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [category])
        let items = try await MKLocalSearch(request: request).start().mapItems
        let places = items.map { item -> NearbyPlace in
            let coordinate = item.placemark.coordinate
            let meters = location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            return NearbyPlace(place: DashDestination(item), meters: meters)
        }
        return Array(places.sorted { $0.meters < $1.meters }.prefix(15))
    }
}

/// "ไปที่ไหน": search, places riders stop at, recent places, then the route preview. With `onPick`
/// it chooses a stop instead and closes.
struct DashDestinationSearch: View {
    @ObservedObject var dashScreen: DashScreenService
    @ObservedObject var navigator: DashNavigator
    var onPick: ((DashDestination) -> Void)? = nil
    @StateObject private var search = PlaceSearch()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var path: [DashDestination] = []
    @State private var resolving: MKLocalSearchCompletion?
    @State private var failure: String?
    @State private var quick: QuickPlace?
    @State private var nearby: [NearbyPlace] = []
    @State private var loadingNearby = false
    @State private var nearbyFailure: String?
    @State private var nearbyRequest = UUID()
    @State private var nearbyTask: Task<Void, Never>?
    @State private var resolveRequest = UUID()
    @State private var resolveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if search.query.isEmpty {
                    Section {
                        quickPlaces
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    if let quick {
                        Section {
                            if loadingNearby {
                                ProgressView("กำลังค้นหา\(quick.title)…")
                            } else if let nearbyFailure {
                                Text(nearbyFailure).foregroundStyle(.secondary)
                                Button("ลองอีกครั้ง") { loadNearby(quick) }
                            } else if nearby.isEmpty {
                                Text("ไม่พบ\(quick.title)ใกล้ๆ")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(nearby) { entry in
                                Button { choose(entry.place) } label: {
                                    PlaceRow(symbol: quick.symbol, tint: quick.tint, title: entry.place.name,
                                             subtitle: DashFormat.distance(entry.meters) + (entry.place.subtitle.isEmpty ? "" : " · " + entry.place.subtitle))
                                }
                            }
                        }
                    } else if !navigator.recents.isEmpty {
                        Section("ล่าสุด") {
                            ForEach(navigator.recents) { place in
                                Button { choose(place) } label: {
                                    PlaceRow(symbol: "clock.fill", tint: .gray, title: place.name, subtitle: place.subtitle)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        if search.isLoading {
                            ProgressView("กำลังค้นหาสถานที่…")
                        } else if let failure = search.failure {
                            Text(failure).foregroundStyle(.secondary)
                            Button("ลองอีกครั้ง") { search.retry() }
                        } else if search.results.isEmpty {
                            Text("ไม่พบสถานที่ ลองเปลี่ยนคำค้น")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(search.results, id: \.self) { completion in
                            Button { open(completion) } label: {
                                PlaceRow(symbol: "mappin", tint: .red, title: completion.title,
                                         subtitle: completion.subtitle, busy: resolving == completion)
                            }
                            .disabled(resolving != nil)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "ค้นหาสถานที่")
            .autocorrectionDisabled()
            .navigationTitle(onPick == nil ? "ไปที่ไหน" : "เพิ่มจุดแวะ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ปิด") { dismiss() }
                }
            }
            .navigationDestination(for: DashDestination.self) { place in
                DashRoutePreview(destination: place, dashScreen: dashScreen) { dismiss() }
            }
            .alert("ค้นหาไม่สำเร็จ", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("ตกลง", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .onAppear {
                dashScreen.prepareLocation()
                search.focus(on: dashScreen.lastKnownLocation)
                if !search.query.isEmpty { search.retry() }
            }
            .onChange(of: search.query) { _ in
                cancelResolving()
                nearbyTask?.cancel()
                nearbyRequest = UUID()
                loadingNearby = false
                quick = nil
                nearby = []
                nearbyFailure = nil
            }
            .onDisappear {
                nearbyTask?.cancel()
                cancelResolving()
                search.cancel()
            }
        }
    }

    private var quickPlaces: some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 96))], spacing: 8) {
            ForEach(QuickPlace.allCases) { place in
                Button { toggle(place) } label: {
                    Label(place.title, systemImage: place.symbol)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .padding(.vertical, 4)
                        .foregroundStyle(quick == place ? Color.white : place.tint)
                        .background(quick == place ? place.tint : place.tint.opacity(0.15),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggle(_ place: QuickPlace) {
        nearbyTask?.cancel()
        nearbyRequest = UUID()
        loadingNearby = false
        guard quick != place else { quick = nil; nearby = []; nearbyFailure = nil; return }
        quick = place
        loadNearby(place)
    }

    private func loadNearby(_ place: QuickPlace) {
        nearbyTask?.cancel()
        let request = UUID()
        nearbyRequest = request
        nearby = []
        nearbyFailure = nil
        dashScreen.prepareLocation()
        guard let location = dashScreen.lastKnownLocation else {
            loadingNearby = false
            nearbyFailure = "ยังไม่ทราบตำแหน่ง ตรวจสิทธิ์ตำแหน่งแล้วลองอีกครั้ง"
            return
        }
        loadingNearby = true
        nearbyTask = Task { @MainActor in
            defer { if nearbyRequest == request { loadingNearby = false } }
            do {
                let found = try await place.nearby(location)
                guard !Task.isCancelled, nearbyRequest == request, quick == place else { return }
                nearby = found
            } catch {
                guard !Task.isCancelled, nearbyRequest == request, quick == place else { return }
                nearbyFailure = "ค้นหา\(place.title)ไม่ได้ ตรวจอินเทอร์เน็ตแล้วลองอีกครั้ง"
            }
        }
    }

    private func choose(_ place: DashDestination) {
        if let onPick {
            onPick(place)
            dismiss()
        } else {
            path.append(place)
        }
    }

    @MainActor
    private func open(_ completion: MKLocalSearchCompletion) {
        cancelResolving()
        let request = UUID()
        resolveRequest = request
        resolving = completion
        resolveTask = Task {
            defer { if resolveRequest == request { resolving = nil } }
            do {
                let place = try await search.resolve(completion)
                guard !Task.isCancelled, resolveRequest == request else { return }
                choose(place)
            } catch {
                guard !Task.isCancelled, resolveRequest == request else { return }
                failure = error.localizedDescription
            }
        }
    }

    private func cancelResolving() {
        resolveTask?.cancel()
        resolveRequest = UUID()
        resolving = nil
    }
}

private struct PlaceRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var busy = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if busy { ProgressView() }
        }
        .padding(.vertical, 2)
    }
}

enum RoutePreviewLayout {
    static func mapHeight(availableHeight: CGFloat, landscape: Bool, accessibilityText: Bool) -> CGFloat {
        let height = max(0, availableHeight)
        let reserved: CGFloat = accessibilityText ? 280 : 180
        let cap: CGFloat = landscape ? 150 : 280
        let result = min(cap, height * (landscape ? 0.30 : 0.35), max(0, height - reserved))
        // Very short sheets keep the scrollable route list and its primary action usable.
        return result >= 72 ? result : 0
    }
}

/// Apple Maps' directions card: where from, stops (add, reorder, remove), where to; the ways to
/// get there to choose from (tap a card or a line on the map); avoid options; then ไป.
struct DashRoutePreview: View {
    let destination: DashDestination
    @ObservedObject var dashScreen: DashScreenService
    var onStart: () -> Void
    @State private var stops: [DashDestination] = []
    @State private var trips: [DashTrip] = []
    @State private var selected = 0
    @State private var failure: String?
    @State private var loading = false
    @State private var addingStop = false
    @State private var editMode: EditMode = .inactive
    @State private var addingFuel = false
    @State private var fuelStops: Set<String> = []
    @State private var fuelNote: String?
    @State private var retryAttempt = 0
    @State private var routeRequest = UUID()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(DashSettings.avoidHighwaysKey) private var avoidHighways = false
    @AppStorage(DashSettings.avoidTollsKey) private var avoidTolls = true

    /// Changes to any of these find the routes again.
    private var routeKey: String {
        stops.map(\.id).joined(separator: "|") + "/\(avoidHighways)/\(avoidTolls)/\(retryAttempt)"
    }

    private var trip: DashTrip? { trips.indices.contains(selected) ? trips[selected] : nil }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                let mapHeight = RoutePreviewLayout.mapHeight(availableHeight: geometry.size.height,
                    landscape: geometry.size.width > geometry.size.height,
                    accessibilityText: dynamicTypeSize.isAccessibilitySize)
                if mapHeight > 0 {
                    RouteMapView(trips: trips, selected: selected, destination: destination, stops: stops) { selected = $0 }
                        .frame(height: mapHeight)
                }
                List {
                    Section {
                        PlaceRow(symbol: "location.fill", tint: .blue, title: "ตำแหน่งของฉัน", subtitle: "")
                        ForEach(stops) { stop in
                            PlaceRow(symbol: "\((stops.firstIndex(of: stop) ?? 0) + 1).circle.fill", tint: .orange, title: stop.name, subtitle: stop.subtitle)
                        }
                        .onMove { stops.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { stops.remove(atOffsets: $0) }
                        PlaceRow(symbol: "mappin", tint: .red, title: destination.name, subtitle: destination.subtitle)
                        Button { addingStop = true } label: {
                            Label("เพิ่มจุดแวะ", systemImage: "plus.circle.fill")
                                .font(.body.weight(.semibold))
                        }
                        .disabled(editMode == .active)
                    } header: {
                        HStack {
                            Text("เส้นทาง")
                            Spacer()
                            if stops.count >= 2 {
                                Button(editMode == .active ? "เสร็จ" : "จัดลำดับ") {
                                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                                }
                                .font(.footnote.weight(.semibold))
                                .textCase(nil)
                            }
                        }
                    }

                    Section {
                        if loading && trips.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("กำลังหาเส้นทาง")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let failure, trips.isEmpty {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            Button("ลองหาเส้นทางอีกครั้ง") { retryAttempt += 1 }
                        }
                        ForEach(trips) { option in
                            let index = trips.firstIndex { $0.id == option.id } ?? 0
                            Button { selected = index } label: { tripRow(option, chosen: index == selected) }
                                .buttonStyle(.plain)
                        }
                    }

                    if let trip, let range = dashScreen.currentVehicle().rangeKm,
                       !stops.contains(where: { fuelStops.contains($0.id) }),
                       trip.distance > Double(range) * 1000 - 15_000 {
                        Section { fuelWarning(trip: trip, range: range) }
                    }

                    Section {
                        Toggle("เลี่ยงทางด่วน/มอเตอร์เวย์", isOn: $avoidTolls)
                        Toggle("เลี่ยงทางหลวง", isOn: $avoidHighways)
                    }
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, $editMode)
                .safeAreaInset(edge: .bottom) { goBar }
            }
        }
        .navigationTitle(destination.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: routeKey) { await loadRoutes() }
        .sheet(isPresented: $addingStop) {
            DashDestinationSearch(dashScreen: dashScreen, navigator: dashScreen.navigator) { place in
                if place.id != destination.id, !stops.contains(place) { stops.append(place) }
            }
        }
    }

    private func tripRow(_ option: DashTrip, chosen: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                let duration = DashFormat.duration(option.expectedTravelTime)
                Text("\(duration.value) \(duration.unit)")
                    .font(.title3.bold().monospacedDigit())
                Text("ถึง \(Self.clock(option.expectedTravelTime)) · \(DashFormat.distance(option.distance))"
                     + (option.name.isEmpty ? "" : " · \(option.name)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                let labels = DashTrip.labels(for: option, among: trips)
                if !labels.isEmpty {
                    Text(labels.joined(separator: " · "))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(chosen ? Color.blue : Color.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(chosen ? Color.blue : Color(.tertiaryLabel))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The tank will not last the route (range from the bike): offer a station on the way.
    @ViewBuilder
    private func fuelWarning(trip: DashTrip, range: Int) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("น้ำมันอาจไม่พอ")
                    .font(.headline)
                Text("วิ่งได้อีกราว \(range) กม. · เส้นทางนี้ \(DashFormat.distance(trip.distance))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "fuelpump.fill")
                .foregroundStyle(.orange)
        }
        Button { addFuelStop(trip: trip, range: range) } label: {
            HStack {
                Text(fuelNote ?? "เพิ่มปั๊มน้ำมันระหว่างทาง")
                Spacer()
                if addingFuel { ProgressView() }
            }
        }
        .disabled(addingFuel)
    }

    @MainActor
    private func addFuelStop(trip: DashTrip, range: Int) {
        addingFuel = true
        fuelNote = nil
        let route = DashRoute(legs: trip.legs)
        let target = FuelPlanner.target(routeDistance: route.distance, rangeMeters: Double(range) * 1000)
        Task { @MainActor in
            defer { addingFuel = false }
            guard let station = await FuelPlanner.station(along: route, near: target) else {
                fuelNote = "ไม่พบปั๊มใกล้เส้นทาง ลองเพิ่มจุดแวะเอง"
                return
            }
            // In order along the route, among the stops already there.
            let along = route.progress(at: station.coordinate, hint: nil).distanceAlong
            let index = stops.firstIndex { route.progress(at: $0.coordinate, hint: nil).distanceAlong > along } ?? stops.count
            fuelStops.insert(station.id)
            if !stops.contains(station) { stops.insert(station, at: index) }
        }
    }

    private var goBar: some View {
        Button {
            guard let trip else { return }
            dashScreen.startNavigation(to: destination, stops: stops, legs: trip.legs)
            onStart()
        } label: {
            Text("ไป")
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .controlSize(.large)
        .disabled(trip == nil || loading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @MainActor
    private func loadRoutes() async {
        let request = UUID()
        routeRequest = request
        loading = true
        failure = nil
        defer { if routeRequest == request { loading = false } }
        let origin = dashScreen.lastKnownLocation
        do {
            let found: [DashTrip]
            if stops.isEmpty {
                found = try await DashNavigator.routes(to: destination, from: origin).map { DashTrip(legs: [$0]) }
            } else {
                found = [DashTrip(legs: try await DashNavigator.legs(through: stops + [destination], from: origin))]
            }
            guard !Task.isCancelled, routeRequest == request else { return }
            trips = found
            selected = 0
            if found.isEmpty { failure = "ไม่พบเส้นทาง ลองเปลี่ยนจุดหมายหรือทางเลี่ยง" }
        } catch {
            guard !Task.isCancelled, routeRequest == request else { return }
            trips = []
            failure = "หาเส้นทางไม่ได้: \(error.localizedDescription)"
        }
    }

    private static func clock(_ fromNow: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date().addingTimeInterval(fromNow))
    }
}

/// MKMapView, because SwiftUI's Map on iOS 16 cannot draw a route line. Every way to choose is drawn,
/// the chosen one on top in full blue; tapping another line chooses it.
private struct RouteMapView: UIViewRepresentable {
    let trips: [DashTrip]
    let selected: Int
    let destination: DashDestination
    let stops: [DashDestination]
    var onSelect: (Int) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.showsUserLocation = true
        view.pointOfInterestFilter = .excludingAll
        view.isRotateEnabled = false
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                         action: #selector(Coordinator.tapped(_:))))
        view.setRegion(MKCoordinateRegion(center: destination.coordinate, latitudinalMeters: 3000,
                                          longitudinalMeters: 3000), animated: false)
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        let tripsKey = trips.map(\.id.uuidString).joined(separator: ",")
        let key = tripsKey + "/\(selected)/" + stops.map(\.id).joined(separator: ",")
        guard coordinator.key != key else { return }
        let refit = coordinator.tripsKey != tripsKey
        coordinator.key = key
        coordinator.tripsKey = tripsKey

        view.removeOverlays(view.overlays)
        view.removeAnnotations(view.annotations.filter { !($0 is MKUserLocation) })
        coordinator.lines = []
        coordinator.chosen = []
        // Others first, so the chosen route draws on top.
        for (index, trip) in trips.enumerated() where index != selected {
            for leg in trip.legs {
                coordinator.lines.append((leg.polyline, index))
                view.addOverlay(leg.polyline, level: .aboveRoads)
            }
        }
        if trips.indices.contains(selected) {
            for leg in trips[selected].legs {
                coordinator.lines.append((leg.polyline, selected))
                coordinator.chosen.insert(ObjectIdentifier(leg.polyline))
                view.addOverlay(leg.polyline, level: .aboveRoads)
            }
        }
        for (index, stop) in stops.enumerated() {
            let pin = MKPointAnnotation()
            pin.coordinate = stop.coordinate
            pin.title = "\(index + 1). \(stop.name)"
            view.addAnnotation(pin)
        }
        let pin = MKPointAnnotation()
        pin.coordinate = destination.coordinate
        pin.title = destination.name
        view.addAnnotation(pin)

        if refit, let first = trips.first?.legs.first?.polyline.boundingMapRect {
            let rect = trips.flatMap(\.legs).reduce(first) { $0.union($1.polyline.boundingMapRect) }
            view.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var key = ""
        var tripsKey = ""
        var lines: [(MKPolyline, Int)] = []
        var chosen: Set<ObjectIdentifier> = []
        var onSelect: ((Int) -> Void)?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer = MKPolylineRenderer(overlay: overlay)
            let isChosen = chosen.contains(ObjectIdentifier(overlay))
            renderer.strokeColor = isChosen ? .systemBlue : UIColor.systemBlue.withAlphaComponent(0.4)
            renderer.lineWidth = isChosen ? 7 : 6
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        /// Chooses the route whose line is within about 24 points of the tap.
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? MKMapView, view.bounds.width > 0 else { return }
            let tap = MKMapPoint(view.convert(gesture.location(in: view), toCoordinateFrom: view))
            let tolerance = 24 * view.visibleMapRect.width / Double(view.bounds.width)
            var best: (index: Int, distance: Double)?
            for (line, index) in lines {
                let points = line.points()
                for i in 0 ..< max(0, line.pointCount - 1) {
                    let distance = Self.distance(tap, points[i], points[i + 1])
                    if distance < tolerance, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                        best = (index, distance)
                    }
                }
            }
            if let best { onSelect?(best.index) }
        }

        private static func distance(_ p: MKMapPoint, _ a: MKMapPoint, _ b: MKMapPoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }
    }
}
