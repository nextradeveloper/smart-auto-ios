import CoreGraphics
import CoreLocation
import CoreText
import MapKit
import UIKit

/// Draws Smart Auto's dash screen. Core Graphics and Core Text only, because this runs behind the
/// lock screen where UIKit views and the GPU are not available.
///
/// Two screens, both after CarPlay's dark look: the Dashboard (map on the left, two cards on the
/// right) and guidance (map turned to our heading under a turn card, arrival card, speed). Apple's
/// system colours and SF Pro; nothing on screen that is not read at a glance.
final class DashRenderer {
    let size: CGSize

    /// Apple's system colours for one appearance, in sRGB like the frame they are drawn into.
    private struct Colors {
        let background, card, cardOverMap, emptyMap, label, secondary: CGColor
        let blue, routeCasing, green, yellow, red, shadow: CGColor

        static let dark = Colors(
            background: srgb(0, 0, 0, 1),
            card: srgb(0.110, 0.110, 0.118, 1),          // #1C1C1E
            cardOverMap: srgb(0.110, 0.110, 0.118, 0.94),
            emptyMap: srgb(0.067, 0.071, 0.078, 1),      // #111214
            label: srgb(1, 1, 1, 1),
            secondary: srgb(0.557, 0.557, 0.576, 1),     // #8E8E93
            blue: srgb(0.039, 0.518, 1, 1),              // #0A84FF
            routeCasing: srgb(0.016, 0.310, 0.690, 1),
            green: srgb(0.188, 0.820, 0.345, 1),         // #30D158
            yellow: srgb(1, 0.839, 0.039, 1),            // #FFD60A
            red: srgb(1, 0.271, 0.227, 1),               // #FF453A
            shadow: srgb(0, 0, 0, 0.45))

        static let light = Colors(
            background: srgb(0.949, 0.949, 0.969, 1),    // #F2F2F7
            card: srgb(1, 1, 1, 1),
            cardOverMap: srgb(1, 1, 1, 0.95),
            emptyMap: srgb(0.898, 0.898, 0.918, 1),      // #E5E5EA
            label: srgb(0, 0, 0, 1),
            secondary: srgb(0.431, 0.431, 0.451, 1),     // #6E6E73
            blue: srgb(0, 0.478, 1, 1),                  // #007AFF
            routeCasing: srgb(0, 0.349, 0.788, 1),
            green: srgb(0.204, 0.780, 0.349, 1),         // #34C759
            yellow: srgb(1, 0.584, 0, 1),                // #FF9500, readable on white
            red: srgb(1, 0.231, 0.188, 1),               // #FF3B30
            shadow: srgb(0, 0, 0, 0.25))

        private static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> CGColor {
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            return CGColor(colorSpace: space, components: [red, green, blue, alpha])
                ?? CGColor(red: red, green: green, blue: blue, alpha: alpha)
        }
    }

    /// The puck stays white-ringed in both appearances, as in Apple Maps.
    private static let white = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                       components: [1, 1, 1, 1]) ?? CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    /// The guidance map seen from above, before it is tilted into perspective (3D).
    private lazy var planar: CGContext? = CGContext(
        data: nil, width: Perspective.planarWidth, height: Perspective.planarHeight, bitsPerComponent: 8,
        bytesPerRow: Perspective.planarWidth * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

    /// The palette of the frame being drawn.
    private var colors = Colors.dark
    private var style: DashStyle = .dark
    /// Map on the right: every card and the puck swap sides.
    private var mirrored = false

    private enum Layout {
        static let margin: CGFloat = 16
        static let gap: CGFloat = 16
        static let cornerRadius: CGFloat = 20
        static let cardPadding: CGFloat = 28
        static let columnWidth: CGFloat = 408
        /// Guidance: where we sit, right of the cards and low, so more of the road ahead shows.
        static let guidancePuck = CGPoint(x: 760, y: 340)
        static let guidanceCardWidth: CGFloat = 400
    }

    private let clockFont = UIFont.monospacedDigitSystemFont(ofSize: 104, weight: .semibold) as CTFont
    private let speedFont = UIFont.monospacedDigitSystemFont(ofSize: 96, weight: .semibold) as CTFont
    private let maneuverDistanceFont = UIFont.monospacedDigitSystemFont(ofSize: 58, weight: .semibold) as CTFont
    private let etaValueFont = UIFont.monospacedDigitSystemFont(ofSize: 38, weight: .semibold) as CTFont
    private let pillSpeedFont = UIFont.monospacedDigitSystemFont(ofSize: 44, weight: .semibold) as CTFont
    private let pillTimeFont = UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold) as CTFont
    private let instructionFont = UIFont.systemFont(ofSize: 27, weight: .semibold) as CTFont
    private let headingFont = UIFont.systemFont(ofSize: 22, weight: .semibold) as CTFont
    private let bodyFont = UIFont.systemFont(ofSize: 26, weight: .regular) as CTFont
    private let bodyStrongFont = UIFont.systemFont(ofSize: 26, weight: .semibold) as CTFont
    private let captionFont = UIFont.systemFont(ofSize: 19, weight: .regular) as CTFont
    private let tinyFont = UIFont.systemFont(ofSize: 16, weight: .regular) as CTFont

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "th_TH")
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// SF Symbols rendered once per style, keyed "name|dark" / "name|light".
    private var symbols: [String: CGImage] = [:]

    init(size: CGSize) {
        self.size = size
        // Rendered here, once, rather than per frame behind the lock screen.
        for (style, palette) in [(DashStyle.dark, Colors.dark), (DashStyle.light, Colors.light)] {
            var wanted: [(String, CGFloat, CGColor)] = [
                ("speedometer", 22, palette.secondary), ("lock.fill", 24, palette.label),
                ("lock.open.fill", 24, palette.yellow), ("bolt.slash.fill", 24, palette.secondary),
                ("battery.100", 26, palette.green), ("battery.75", 26, palette.green),
                ("battery.50", 26, palette.yellow), ("battery.25", 26, palette.red),
                ("arrow.triangle.2.circlepath", 60, palette.label),
            ]
            wanted += DashManeuver.allSymbols.map { ($0, 60, palette.label) }
            for (name, point, color) in wanted {
                symbols[Self.symbolKey(name, style)] = Self.symbol(name, pointSize: point, color: UIColor(cgColor: color))
            }
        }
    }

    private static func symbolKey(_ name: String, _ style: DashStyle) -> String {
        "\(name)|\(style == .dark ? "dark" : "light")"
    }

    // MARK: Frame

    func draw(_ scene: DashScene, in context: CGContext) {
        style = scene.style
        mirrored = scene.mapOnRight
        colors = scene.style == .light ? .light : .dark
        context.saveGState()
        // Lay out top-left first, like UIKit; text and images flip back locally.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.interpolationQuality = .medium

        context.setFillColor(colors.background)
        context.fill(CGRect(origin: .zero, size: size))
        if let navigation = scene.navigation {
            drawGuidance(scene, navigation, context: context)
        } else {
            drawDashboard(scene, context: context)
        }
        context.restoreGState()
    }

    // MARK: Dashboard

    private func drawDashboard(_ scene: DashScene, context: CGContext) {
        let content = CGRect(origin: .zero, size: size).insetBy(dx: Layout.margin, dy: Layout.margin)
        let column = CGRect(x: content.maxX - Layout.columnWidth, y: content.minY,
                            width: Layout.columnWidth, height: content.height)
        let mapPane = CGRect(x: content.minX, y: content.minY,
                             width: column.minX - Layout.gap - content.minX, height: content.height)
        let cardHeight = (column.height - Layout.gap) / 2
        let clockCard = CGRect(x: column.minX, y: column.minY, width: column.width, height: cardHeight)
        let rideCard = CGRect(x: column.minX, y: clockCard.maxY + Layout.gap, width: column.width, height: cardHeight)

        drawOverviewMap(scene, in: side(mapPane), context: context)
        drawClockCard(scene, in: side(clockCard), context: context)
        drawRideCard(scene, in: side(rideCard), context: context)
    }

    /// `rect` laid out for a map on the left, moved to the other side when mirrored.
    private func side(_ rect: CGRect) -> CGRect {
        guard mirrored else { return rect }
        return CGRect(x: size.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
    }

    private func drawOverviewMap(_ scene: DashScene, in pane: CGRect, context: CGContext) {
        context.saveGState()
        context.addPath(CGPath(roundedRect: pane, cornerWidth: Layout.cornerRadius,
                               cornerHeight: Layout.cornerRadius, transform: nil))
        context.clip()
        context.setFillColor(colors.emptyMap)
        context.fill(pane)

        let center = CGPoint(x: pane.midX, y: pane.midY)
        if let position = scene.position ?? scene.location?.coordinate {
            if let map = scene.map {
                // Keep where we are at the centre of the pane, turned to our heading.
                let here = map.pixel(for: position)
                context.saveGState()
                context.translateBy(x: center.x, y: center.y)
                if let course = scene.course { context.rotate(by: -CGFloat(course) * .pi / 180) }
                drawImage(map.image, in: CGRect(x: -here.x, y: -here.y,
                                                width: CGFloat(map.image.width), height: CGFloat(map.image.height)),
                          context: context)
                context.restoreGState()
            }
            if scene.course != nil {
                drawArrowPuck(at: center, context: context)
            } else {
                drawDot(at: center, context: context)
            }
        } else {
            drawText("กำลังหาตำแหน่ง", font: bodyFont, color: colors.secondary,
                     at: CGPoint(x: center.x, y: center.y + 9), alignment: .center, context: context)
        }
        context.restoreGState()
    }

    /// Apple Maps' location puck: a blue dot in a white ring.
    private func drawDot(at point: CGPoint, context: CGContext) {
        context.saveGState()
        context.setShadow(offset: .zero, blur: 8, color: colors.shadow)
        context.setFillColor(Self.white)
        context.fillEllipse(in: CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28))
        context.restoreGState()
        context.setFillColor(colors.blue)
        context.fillEllipse(in: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
    }

    private func drawClockCard(_ scene: DashScene, in rect: CGRect, context: CGContext) {
        drawCard(rect, color: colors.card, context: context)
        let left = rect.minX + Layout.cardPadding
        drawText(timeFormatter.string(from: scene.date), font: clockFont, color: colors.label,
                 at: CGPoint(x: left, y: rect.minY + 140), context: context)
        drawText(dateFormatter.string(from: scene.date), font: bodyFont, color: colors.secondary,
                 at: CGPoint(x: left, y: rect.minY + 196), context: context)
    }

    private func drawRideCard(_ scene: DashScene, in rect: CGRect, context: CGContext) {
        drawCard(rect, color: colors.card, context: context)
        let left = rect.minX + Layout.cardPadding

        drawSymbol("speedometer", at: CGPoint(x: left, y: rect.minY + 26), context: context)
        drawText("ความเร็ว", font: headingFont, color: colors.secondary,
                 at: CGPoint(x: left + 32, y: rect.minY + 46), context: context)
        let speedEnd = drawText(speedText(scene), font: speedFont, color: colors.label,
                                at: CGPoint(x: left, y: rect.minY + 142), context: context)
        drawText("กม./ชม.", font: bodyFont, color: colors.secondary,
                 at: CGPoint(x: speedEnd + 12, y: rect.minY + 142), context: context)

        let rowBaseline = rect.minY + 204
        let vehicle = scene.vehicle
        guard vehicle.connected else {
            drawSymbol("bolt.slash.fill", at: CGPoint(x: left, y: rowBaseline - 24), context: context)
            drawText("รถยังไม่เชื่อม Bluetooth", font: bodyFont, color: colors.secondary,
                     at: CGPoint(x: left + 36, y: rowBaseline), context: context)
            return
        }
        var x = left
        if let voltage = vehicle.voltage {
            drawSymbol(Self.batterySymbol(voltage), at: CGPoint(x: x, y: rowBaseline - 22), context: context)
            x = drawText(String(format: "%.1f V", voltage), font: bodyStrongFont, color: colors.label,
                         at: CGPoint(x: x + 44, y: rowBaseline), context: context) + 28
        }
        if let locked = vehicle.locked {
            drawSymbol(locked ? "lock.fill" : "lock.open.fill", at: CGPoint(x: x, y: rowBaseline - 24), context: context)
            drawText(locked ? "ล็อกอยู่" : "ปลดล็อก", font: bodyFont, color: colors.label,
                     at: CGPoint(x: x + 30, y: rowBaseline), context: context)
        }
    }

    // MARK: Guidance

    private func drawGuidance(_ scene: DashScene, _ navigation: DashScene.Navigation, context: CGContext) {
        context.setFillColor(colors.emptyMap)
        context.fill(CGRect(origin: .zero, size: size))
        let puck = side(CGRect(origin: Layout.guidancePuck, size: .zero)).origin

        if scene.threeD, let position = scene.position ?? scene.location?.coordinate, let planar {
            drawPerspective(scene, navigation, at: position, planar: planar, context: context)
        } else if let position = scene.position ?? scene.location?.coordinate {
            let course = scene.course ?? 0
            let pixelsPerPoint = scene.map?.pixelsPerMapPoint
                ?? 1 / (scene.guidanceMetersPerPixel * MKMapPointsPerMeterAtLatitude(position.latitude))
            context.saveGState()
            context.translateBy(x: puck.x, y: puck.y)
            context.rotate(by: -CGFloat(course) * .pi / 180)
            if let map = scene.map {
                let here = map.pixel(for: position)
                drawImage(map.image, in: CGRect(x: -here.x, y: -here.y,
                                                width: CGFloat(map.image.width), height: CGFloat(map.image.height)),
                          context: context)
            }
            drawRoute(navigation.upcoming, from: MKMapPoint(position), pixelsPerPoint: pixelsPerPoint, context: context)
            context.restoreGState()
            drawArrowPuck(at: puck, context: context)
        } else {
            drawText("กำลังหาตำแหน่ง", font: bodyFont, color: colors.secondary,
                     at: CGPoint(x: puck.x, y: puck.y), alignment: .center, context: context)
        }

        drawManeuverCard(navigation, context: context)
        drawThenPill(navigation, context: context)
        drawArrivalCard(navigation, context: context)
        drawTimePill(scene, context: context)
        drawSpeedPill(scene, context: context)
    }

    /// Perspective without a GPU: the map and route are drawn from above into `planar`, then copied
    /// to the frame in thin bands, each scaled for its distance (far bands small, near ones large),
    /// which tilts the ground away like Apple Maps' 3D driving view. A fade hides the far edge.
    private func drawPerspective(_ scene: DashScene, _ navigation: DashScene.Navigation,
                                 at position: CLLocationCoordinate2D, planar: CGContext, context: CGContext) {
        let course = scene.course ?? 0
        let pixelsPerPoint = scene.map?.pixelsPerMapPoint
            ?? 1 / (scene.guidanceMetersPerPixel * MKMapPointsPerMeterAtLatitude(position.latitude))

        planar.saveGState()
        planar.translateBy(x: 0, y: CGFloat(Perspective.planarHeight))
        planar.scaleBy(x: 1, y: -1)
        planar.interpolationQuality = .medium
        planar.setFillColor(colors.emptyMap)
        planar.fill(CGRect(x: 0, y: 0, width: Perspective.planarWidth, height: Perspective.planarHeight))
        planar.translateBy(x: Perspective.planarPuck.x, y: Perspective.planarPuck.y)
        planar.rotate(by: -CGFloat(course) * .pi / 180)
        if let map = scene.map {
            let here = map.pixel(for: position)
            drawImage(map.image, in: CGRect(x: -here.x, y: -here.y,
                                            width: CGFloat(map.image.width), height: CGFloat(map.image.height)),
                      context: planar)
        }
        drawRoute(navigation.upcoming, from: MKMapPoint(position), pixelsPerPoint: pixelsPerPoint, context: planar)
        planar.restoreGState()
        guard let ground = planar.makeImage() else { return }

        let bands = Perspective.bands(height: size.height, width: size.width)
        for band in bands {
            guard let slice = ground.cropping(to: band.source) else { continue }
            drawImage(slice, in: band.destination, context: context)
        }

        // Fade the horizon into the background, as Apple's 3D view does.
        let fadeHeight: CGFloat = 120
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [colors.emptyMap, colors.emptyMap.copy(alpha: 0) ?? colors.emptyMap] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: fadeHeight), options: [])
        }
        drawArrowPuck(at: Perspective.screenPuck, context: context)
    }

    /// The route as Apple Maps draws it: a blue line with a darker casing.
    private func drawRoute(_ route: [CLLocationCoordinate2D], from origin: MKMapPoint, pixelsPerPoint: Double,
                           context: CGContext) {
        guard route.count >= 2 else { return }
        let path = CGMutablePath()
        for (index, coordinate) in route.enumerated() {
            let point = MKMapPoint(coordinate)
            let pixel = CGPoint(x: (point.x - origin.x) * pixelsPerPoint, y: (point.y - origin.y) * pixelsPerPoint)
            if index == 0 { path.move(to: pixel) } else { path.addLine(to: pixel) }
        }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.setStrokeColor(colors.routeCasing)
        context.setLineWidth(22)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(colors.blue)
        context.setLineWidth(15)
        context.strokePath()
    }

    /// The driving puck: a white arrow pointing the way we face, on blue in a white ring.
    private func drawArrowPuck(at point: CGPoint, context: CGContext) {
        context.saveGState()
        context.setShadow(offset: .zero, blur: 10, color: colors.shadow)
        context.setFillColor(Self.white)
        context.fillEllipse(in: CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48))
        context.restoreGState()
        context.setFillColor(colors.blue)
        context.fillEllipse(in: CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40))
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: point.x, y: point.y - 12))
        arrow.addLine(to: CGPoint(x: point.x + 10, y: point.y + 11))
        arrow.addLine(to: CGPoint(x: point.x, y: point.y + 5))
        arrow.addLine(to: CGPoint(x: point.x - 10, y: point.y + 11))
        arrow.closeSubpath()
        context.addPath(arrow)
        context.setFillColor(Self.white)
        context.fillPath()
    }

    private func drawManeuverCard(_ navigation: DashScene.Navigation, context: CGContext) {
        let rect = side(CGRect(x: Layout.margin, y: Layout.margin, width: Layout.guidanceCardWidth, height: 196))
        drawCard(rect, color: colors.cardOverMap, context: context)
        let left = rect.minX + 26
        let maxWidth = rect.width - 52

        let symbol: String
        let headline: String
        switch navigation.status {
        case .rerouting:
            symbol = "arrow.triangle.2.circlepath"
            headline = "เส้นทางใหม่"
        case .arrived:
            symbol = DashManeuver.arrive.symbol
            headline = "ถึงแล้ว"
        default:
            symbol = navigation.maneuver.symbol
            headline = navigation.distanceToManeuver.map(DashFormat.distance) ?? "ถึงแล้ว"
        }
        if let image = symbols[Self.symbolKey(symbol, style)] {
            // Centre the arrow in an 84-point box so every manoeuvre sits the same.
            let box = CGRect(x: left, y: rect.minY + 24, width: 84, height: 84)
            drawImage(image, in: CGRect(x: box.midX - CGFloat(image.width) / 2, y: box.midY - CGFloat(image.height) / 2,
                                        width: CGFloat(image.width), height: CGFloat(image.height)), context: context)
        }
        drawText(headline, font: maneuverDistanceFont, color: colors.label,
                 at: CGPoint(x: left + 104, y: rect.minY + 88), maxWidth: maxWidth - 104, context: context)
        drawText(navigation.instruction, font: instructionFont, color: colors.label,
                 at: CGPoint(x: left, y: rect.minY + 160), maxWidth: maxWidth, context: context)
    }

    /// "จากนั้น" and the turn after next, under the turn card, when the two come close together,
    /// as CarPlay shows it.
    private func drawThenPill(_ navigation: DashScene.Navigation, context: CGContext) {
        guard navigation.status == .guiding, let then = navigation.then,
              let image = symbols[Self.symbolKey(then.symbol, style)] else { return }
        let rect = side(CGRect(x: Layout.margin, y: Layout.margin + 196 + 10, width: 200, height: 60))
        drawCard(rect, color: colors.cardOverMap, radius: 30, context: context)
        drawText("จากนั้น", font: bodyFont, color: colors.secondary,
                 at: CGPoint(x: rect.minX + 24, y: rect.minY + 39), context: context)
        let fit = min(40 / CGFloat(image.width), 40 / CGFloat(image.height))
        let width = CGFloat(image.width) * fit, height = CGFloat(image.height) * fit
        drawImage(image, in: CGRect(x: rect.maxX - 24 - width, y: rect.midY - height / 2, width: width, height: height),
                  context: context)
    }

    private func drawArrivalCard(_ navigation: DashScene.Navigation, context: CGContext) {
        let rect = side(CGRect(x: Layout.margin, y: size.height - Layout.margin - 100,
                               width: Layout.guidanceCardWidth, height: 100))
        drawCard(rect, color: colors.cardOverMap, context: context)
        var columns: [(String, String)] = []
        if let arrival = navigation.arrival { columns.append((timeFormatter.string(from: arrival), "ถึง")) }
        if let time = navigation.remainingTime {
            let duration = DashFormat.duration(time)
            columns.append((duration.value, duration.unit))
        }
        if let meters = navigation.remainingDistance {
            columns.append(meters < 1000 ? ("\(Int((meters / 10).rounded()) * 10)", "ม.")
                                         : (String(format: meters < 10_000 ? "%.1f" : "%.0f", meters / 1000), "กม."))
        }
        let columnWidth = (rect.width - 40) / 3
        for (index, column) in columns.enumerated() {
            let x = rect.minX + 26 + CGFloat(index) * columnWidth
            drawText(column.0, font: etaValueFont, color: colors.label, at: CGPoint(x: x, y: rect.minY + 52), context: context)
            drawText(column.1, font: captionFont, color: colors.secondary, at: CGPoint(x: x, y: rect.minY + 82), context: context)
        }
    }

    private func drawTimePill(_ scene: DashScene, context: CGContext) {
        let rect = side(CGRect(x: size.width - Layout.margin - 176, y: Layout.margin, width: 176, height: 58))
        drawCard(rect, color: colors.cardOverMap, radius: 29, context: context)
        let time = timeFormatter.string(from: scene.date)
        if scene.vehicle.connected, let voltage = scene.vehicle.voltage {
            drawSymbol(Self.batterySymbol(voltage), at: CGPoint(x: rect.minX + 20, y: rect.minY + 17), context: context)
            drawText(time, font: pillTimeFont, color: colors.label,
                     at: CGPoint(x: rect.maxX - 20, y: rect.minY + 39), alignment: .right, context: context)
        } else {
            drawText(time, font: pillTimeFont, color: colors.label,
                     at: CGPoint(x: rect.midX, y: rect.minY + 39), alignment: .center, context: context)
        }
    }

    private func drawSpeedPill(_ scene: DashScene, context: CGContext) {
        let diameter: CGFloat = 116
        let rect = side(CGRect(x: size.width - Layout.margin - diameter, y: size.height - Layout.margin - diameter,
                               width: diameter, height: diameter))
        context.setFillColor(colors.cardOverMap)
        context.fillEllipse(in: rect)
        drawText(speedText(scene), font: pillSpeedFont, color: colors.label,
                 at: CGPoint(x: rect.midX, y: rect.midY + 12), alignment: .center, context: context)
        drawText("กม./ชม.", font: tinyFont, color: colors.secondary,
                 at: CGPoint(x: rect.midX, y: rect.midY + 36), alignment: .center, context: context)
    }

    // MARK: Shared

    private func speedText(_ scene: DashScene) -> String {
        guard let location = scene.location, location.speed >= 0 else { return "–" }
        return String(Int((location.speed * 3.6).rounded()))
    }

    static func batterySymbol(_ voltage: Double) -> String {
        switch voltage {
        case 12.4...: return "battery.100"
        case 12.0..<12.4: return "battery.75"
        case 11.6..<12.0: return "battery.50"
        default: return "battery.25"
        }
    }

    private func drawCard(_ rect: CGRect, color: CGColor, radius: CGFloat = Layout.cornerRadius, context: CGContext) {
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    // MARK: Primitives (top-left coordinates)

    /// Draws one line with its baseline at `point.y`, cut with "…" past `maxWidth`; returns the x
    /// where it ends.
    @discardableResult
    private func drawText(_ text: String, font: CTFont, color: CGColor, at point: CGPoint,
                          alignment: NSTextAlignment = .left, maxWidth: CGFloat? = nil,
                          context: CGContext) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        if let maxWidth, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            if let cut = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) { line = cut }
        }
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x: CGFloat
        switch alignment {
        case .center: x = point.x - width / 2
        case .right: x = point.x - width
        default: x = point.x
        }
        context.textPosition = CGPoint(x: x, y: point.y)
        CTLineDraw(line, context)
        return x + width
    }

    private func drawSymbol(_ name: String, at topLeft: CGPoint, context: CGContext) {
        guard let image = symbols[Self.symbolKey(name, style)] else { return }
        drawImage(image, in: CGRect(origin: topLeft, size: CGSize(width: image.width, height: image.height)),
                  context: context)
    }

    /// Images are stored top row first; undo the page flip around them.
    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func symbol(_ name: String, pointSize: CGFloat, color: UIColor) -> CGImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
            symbol.draw(at: .zero)
        }.cgImage
    }
}

/// The tilt of the 3D guidance view: how each screen row maps to the map seen from above.
///
/// Screen row y shows the ground at scale s(y), from 0.7 at the top (far) to 1.3 at the bottom
/// (near), with 1/s linear in y as a camera looking down at an angle sees it. Integrating 1/s gives
/// which row of the planar picture each screen row shows; the puck sits on screen row 430.
enum Perspective {
    static let farScale: CGFloat = 0.7
    static let nearScale: CGFloat = 1.3
    static let screenPuckRow: CGFloat = 430
    static let planarWidth = 1832
    static let planarHeight = 600
    /// Where we are in the planar picture: centred, 499 rows down (what 430 screen rows integrate to).
    static let planarPuck = CGPoint(x: CGFloat(planarWidth) / 2, y: 499)
    static let screenPuck = CGPoint(x: 640, y: screenPuckRow)

    struct Band {
        let source: CGRect
        let destination: CGRect
    }

    /// Screen height `height` in bands of about 8 rows, top to bottom.
    static func bands(height: CGFloat, width: CGFloat) -> [Band] {
        let a = 1 / farScale
        let b = (1 / nearScale - 1 / farScale) / height
        func planarRow(_ y: CGFloat) -> CGFloat {
            // Planar row of screen row y: the puck's row minus the ground between y and the puck.
            planarPuck.y - (a * (screenPuckRow - y) + b / 2 * (screenPuckRow * screenPuckRow - y * y))
        }
        var bands: [Band] = []
        var y: CGFloat = 0
        let step: CGFloat = 8
        while y < height {
            let next = min(height, y + step)
            let scale = 1 / (a + b * (y + next) / 2)
            let top = planarRow(y), bottom = planarRow(next)
            let sourceWidth = width / scale
            let source = CGRect(x: planarPuck.x - sourceWidth / 2, y: top, width: sourceWidth, height: max(1, bottom - top))
                .integral
                .intersection(CGRect(x: 0, y: 0, width: planarWidth, height: planarHeight))
            // Overlap by a row so no seam shows between bands.
            bands.append(Band(source: source, destination: CGRect(x: 0, y: y, width: width, height: next - y + 1)))
            y = next
        }
        return bands
    }
}
