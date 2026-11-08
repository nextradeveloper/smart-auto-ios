import MapKit
import SwiftUI

/// The dash on the phone, full screen and live: an Apple map you can pinch, drag and tilt into 3D,
/// with the dash's turn card over it. Tap a place or long-press anywhere to go there. The dash itself
/// has no touch and cannot draw 3D behind the lock screen, so − / + set how far its map reaches.
struct DashMapScreen: View {
    @ObservedObject var dashScreen: DashScreenService
    @ObservedObject var navigator: DashNavigator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(DashSettings.themeKey) private var theme = DashSettings.Theme.dark.rawValue
    @AppStorage(DashSettings.zoomKey) private var dashZoom = 1.0
    @State private var threeD = true
    @State private var recenter = 0
    @State private var chosen: DashDestination?

    var body: some View {
        ZStack {
            InteractiveMap(route: navigator.route, destination: navigator.destination, threeD: threeD,
                           recenter: recenter, dark: isDark) { place in chosen = place }
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    if navigator.isNavigating {
                        DashGuidanceBanner(navigator: navigator)
                            .padding(16)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    Spacer(minLength: 0)
                    MapButton(symbol: "xmark") { dismiss() }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if navigator.isNavigating {
                        MapButton(symbol: "xmark.circle.fill", tint: .red) { dashScreen.stopNavigation() }
                    }
                    Spacer()
                    VStack(spacing: 10) {
                        dashZoomControl
                        MapButton(symbol: threeD ? "view.2d" : "view.3d") { threeD.toggle() }
                        MapButton(symbol: "location.fill", tint: .blue) { recenter += 1 }
                    }
                }
            }
            .padding(16)
        }
        .preferredColorScheme(isDark ? .dark : .light)
        .sheet(item: $chosen) { place in
            NavigationStack {
                DashRoutePreview(destination: place, dashScreen: dashScreen) { chosen = nil }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("ปิด") { chosen = nil }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear { dashScreen.prepareLocation() }
    }

    private var isDark: Bool {
        switch DashSettings.Theme(rawValue: theme) ?? .dark {
        case .dark: return true
        case .light: return false
        case .system: return colorScheme == .dark
        }
    }

    /// − จอรถ + : how far the dash's own map reaches.
    private var dashZoomControl: some View {
        VStack(spacing: 0) {
            Button {
                dashZoom = DashSettings.stepZoom(closer: true)
            } label: {
                Image(systemName: "plus").frame(width: 48, height: 44)
            }
            .disabled(dashZoom == DashSettings.zoomLevels.first)
            Text("จอรถ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                dashZoom = DashSettings.stepZoom(closer: false)
            } label: {
                Image(systemName: "minus").frame(width: 48, height: 44)
            }
            .disabled(dashZoom == DashSettings.zoomLevels.last)
        }
        .font(.system(size: 18, weight: .semibold))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct MapButton: View {
    let symbol: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// MKMapView with 3D terrain and buildings, following us with our heading until dragged.
private struct InteractiveMap: UIViewRepresentable {
    let route: DashRoute?
    let destination: DashDestination?
    let threeD: Bool
    let recenter: Int
    let dark: Bool
    let onChoose: (DashDestination) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
        view.selectableMapFeatures = [.pointsOfInterest]
        view.showsUserLocation = true
        view.showsCompass = false
        view.isPitchEnabled = true
        view.setUserTrackingMode(.followWithHeading, animated: false)
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        view.addGestureRecognizer(press)
        context.coordinator.onChoose = onChoose
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChoose = onChoose
        view.overrideUserInterfaceStyle = dark ? .dark : .light

        let signature = route.map { "\($0.coordinates.count)/\(Int($0.distance))" }
        if signature != coordinator.routeSignature {
            coordinator.routeSignature = signature
            view.removeOverlays(view.overlays)
            view.removeAnnotations(view.annotations.filter { !($0 is MKUserLocation) && !($0 is MKMapFeatureAnnotation) })
            if let route {
                view.addOverlay(MKPolyline(coordinates: route.coordinates, count: route.coordinates.count))
            }
            if let destination {
                let pin = MKPointAnnotation()
                pin.coordinate = destination.coordinate
                pin.title = destination.name
                view.addAnnotation(pin)
            }
        }

        if threeD != coordinator.threeD || recenter != coordinator.recenter {
            coordinator.threeD = threeD
            coordinator.recenter = recenter
            let camera = view.camera.copy() as? MKMapCamera ?? MKMapCamera()
            camera.pitch = threeD ? 60 : 0
            if let here = view.userLocation.location?.coordinate { camera.centerCoordinate = here }
            camera.centerCoordinateDistance = threeD ? 700 : 1500
            view.setCamera(camera, animated: true)
            view.setUserTrackingMode(.followWithHeading, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onChoose: ((DashDestination) -> Void)?
        var routeSignature: String?
        var threeD = true
        var recenter = 0

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer = MKPolylineRenderer(overlay: overlay)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 9
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        /// A tapped place on the map (shop, temple, station…): offer to go there.
        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let feature = annotation as? MKMapFeatureAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: true)
            let request = MKMapItemRequest(mapFeatureAnnotation: feature)
            request.getMapItem { [weak self] item, _ in
                guard let item else { return }
                DispatchQueue.main.async { self?.onChoose?(DashDestination(item)) }
            }
        }

        /// Long-press anywhere: go there.
        @objc func pressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = gesture.view as? MKMapView else { return }
            let coordinate = view.convert(gesture.location(in: view), toCoordinateFrom: view)
            let place = DashDestination(name: "หมุดที่ปักไว้",
                                        subtitle: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
                                        coordinate: coordinate)
            onChoose?(place)
        }
    }
}
