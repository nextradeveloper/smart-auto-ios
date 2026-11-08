import MapKit
import SwiftUI

/// Apple Maps' search-as-you-type, for choosing where the dash should guide to.
@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { completer.queryFragment = query }
    }
    @Published private(set) var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func focus(on location: CLLocation?) {
        guard let location else { return }
        completer.region = MKCoordinateRegion(center: location.coordinate,
                                              latitudinalMeters: 60_000, longitudinalMeters: 60_000)
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
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

/// "ไปที่ไหน": search, recent places, then the route preview.
struct DashDestinationSearch: View {
    @ObservedObject var dashScreen: DashScreenService
    @ObservedObject var navigator: DashNavigator
    @StateObject private var search = PlaceSearch()
    @Environment(\.dismiss) private var dismiss
    @State private var path: [DashDestination] = []
    @State private var resolving: MKLocalSearchCompletion?
    @State private var failure: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if search.query.isEmpty {
                    if !navigator.recents.isEmpty {
                        Section("ล่าสุด") {
                            ForEach(navigator.recents) { place in
                                Button { path.append(place) } label: {
                                    PlaceRow(symbol: "clock.fill", tint: .gray, title: place.name, subtitle: place.subtitle)
                                }
                            }
                        }
                    }
                } else {
                    Section {
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
            .navigationTitle("ไปที่ไหน")
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
            }
        }
    }

    @MainActor
    private func open(_ completion: MKLocalSearchCompletion) {
        resolving = completion
        Task {
            defer { resolving = nil }
            do {
                path.append(try await search.resolve(completion))
            } catch {
                failure = error.localizedDescription
            }
        }
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
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if busy { ProgressView() }
        }
        .padding(.vertical, 2)
    }
}

/// The route on a map, how long it takes, and the button that starts guidance on the dash.
struct DashRoutePreview: View {
    let destination: DashDestination
    @ObservedObject var dashScreen: DashScreenService
    var onStart: () -> Void
    @State private var route: MKRoute?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            RouteMapView(route: route, destination: destination)
                .frame(height: 280)
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(destination.name)
                            .font(.title3.bold())
                        if !destination.subtitle.isEmpty {
                            Text(destination.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    if let route {
                        VStack(alignment: .leading, spacing: 4) {
                            let duration = DashFormat.duration(route.expectedTravelTime)
                            Text("\(duration.value) \(duration.unit)")
                                .font(.title2.bold())
                            Text("\(DashFormat.distance(route.distance)) · ถึง \(Self.arrival(route))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        Button {
                            dashScreen.startNavigation(to: destination, route: route)
                            onStart()
                        } label: {
                            Text("เริ่มนำทาง")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("กำลังหาเส้นทาง")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("เส้นทาง")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRoute() }
    }

    @MainActor
    private func loadRoute() async {
        guard route == nil else { return }
        do {
            route = try await DashNavigator.route(to: destination, from: dashScreen.lastKnownLocation)
        } catch {
            failure = "หาเส้นทางไม่ได้: \(error.localizedDescription)"
        }
    }

    private static func arrival(_ route: MKRoute) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date().addingTimeInterval(route.expectedTravelTime))
    }
}

/// MKMapView, because SwiftUI's Map on iOS 16 cannot draw a route line.
private struct RouteMapView: UIViewRepresentable {
    let route: MKRoute?
    let destination: DashDestination

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.showsUserLocation = true
        view.pointOfInterestFilter = .excludingAll
        view.isRotateEnabled = false
        let pin = MKPointAnnotation()
        pin.coordinate = destination.coordinate
        pin.title = destination.name
        view.addAnnotation(pin)
        view.setRegion(MKCoordinateRegion(center: destination.coordinate, latitudinalMeters: 3000,
                                          longitudinalMeters: 3000), animated: false)
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        guard let route, context.coordinator.shown !== route else { return }
        context.coordinator.shown = route
        view.removeOverlays(view.overlays)
        view.addOverlay(route.polyline)
        view.setVisibleMapRect(route.polyline.boundingMapRect,
                               edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var shown: MKRoute?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer = MKPolylineRenderer(overlay: overlay)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 6
            renderer.lineCap = .round
            return renderer
        }
    }
}
