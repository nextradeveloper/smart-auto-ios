import CoreGraphics
import CoreLocation
import CoreText
import UIKit

/// Draws Smart Auto's dash screen. Core Graphics and Core Text only, because this runs behind the
/// lock screen where UIKit views and the GPU are not available.
///
/// The look follows CarPlay's dark Dashboard: the map on the left, two cards on the right, Apple's
/// system colours and SF Pro, nothing on screen that is not read at a glance.
final class DashRenderer {
    let size: CGSize

    // Apple's dark-mode system colours.
    private enum Palette {
        static let background = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        static let card = CGColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)        // #1C1C1E
        static let emptyMap = CGColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1)    // #111214
        static let label = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        static let secondary = CGColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)   // #8E8E93
        static let blue = CGColor(red: 0.039, green: 0.518, blue: 1, alpha: 1)            // #0A84FF
        static let green = CGColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1)       // #30D158
        static let yellow = CGColor(red: 1, green: 0.839, blue: 0.039, alpha: 1)          // #FFD60A
        static let red = CGColor(red: 1, green: 0.271, blue: 0.227, alpha: 1)             // #FF453A
    }

    private enum Layout {
        static let margin: CGFloat = 16
        static let gap: CGFloat = 16
        static let cornerRadius: CGFloat = 20
        static let cardPadding: CGFloat = 28
        static let columnWidth: CGFloat = 408
    }

    private let clockFont = UIFont.monospacedDigitSystemFont(ofSize: 104, weight: .semibold) as CTFont
    private let speedFont = UIFont.monospacedDigitSystemFont(ofSize: 96, weight: .semibold) as CTFont
    private let headingFont = UIFont.systemFont(ofSize: 22, weight: .semibold) as CTFont
    private let bodyFont = UIFont.systemFont(ofSize: 26, weight: .regular) as CTFont
    private let bodyStrongFont = UIFont.systemFont(ofSize: 26, weight: .semibold) as CTFont

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

    private var symbols: [String: CGImage] = [:]

    init(size: CGSize) {
        self.size = size
        // Rendered once, here, rather than per frame behind the lock screen.
        for (name, point, color) in [
            ("speedometer", 22.0, Palette.secondary), ("clock", 22.0, Palette.secondary),
            ("lock.fill", 24.0, Palette.label), ("lock.open.fill", 24.0, Palette.yellow),
            ("bolt.slash.fill", 24.0, Palette.secondary),
            ("battery.100", 26.0, Palette.green), ("battery.75", 26.0, Palette.green),
            ("battery.50", 26.0, Palette.yellow), ("battery.25", 26.0, Palette.red),
        ] {
            symbols[name] = Self.symbol(name, pointSize: CGFloat(point), color: UIColor(cgColor: color))
        }
    }

    // MARK: Frame

    func draw(_ scene: DashScene, in context: CGContext) {
        context.saveGState()
        // Lay out top-left first, like UIKit; text and images flip back locally.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        context.setFillColor(Palette.background)
        context.fill(CGRect(origin: .zero, size: size))

        let content = CGRect(origin: .zero, size: size).insetBy(dx: Layout.margin, dy: Layout.margin)
        let column = CGRect(x: content.maxX - Layout.columnWidth, y: content.minY,
                            width: Layout.columnWidth, height: content.height)
        let mapPane = CGRect(x: content.minX, y: content.minY,
                             width: column.minX - Layout.gap - content.minX, height: content.height)
        let cardHeight = (column.height - Layout.gap) / 2
        let clockCard = CGRect(x: column.minX, y: column.minY, width: column.width, height: cardHeight)
        let rideCard = CGRect(x: column.minX, y: clockCard.maxY + Layout.gap, width: column.width, height: cardHeight)

        drawMap(scene, in: mapPane, context: context)
        drawClockCard(scene, in: clockCard, context: context)
        drawRideCard(scene, in: rideCard, context: context)
        context.restoreGState()
    }

    // MARK: Map

    private func drawMap(_ scene: DashScene, in pane: CGRect, context: CGContext) {
        context.saveGState()
        context.addPath(CGPath(roundedRect: pane, cornerWidth: Layout.cornerRadius,
                               cornerHeight: Layout.cornerRadius, transform: nil))
        context.clip()
        context.setFillColor(Palette.emptyMap)
        context.fill(pane)

        let center = CGPoint(x: pane.midX, y: pane.midY)
        if let location = scene.location {
            if let map = scene.map {
                // Keep where we are at the centre of the pane, whichever picture is current.
                let here = map.pixel(for: location.coordinate)
                let origin = CGPoint(x: center.x - here.x, y: center.y - here.y)
                drawImage(map.image, in: CGRect(origin: origin,
                                                size: CGSize(width: map.image.width, height: map.image.height)),
                          context: context)
            }
            drawPuck(at: center, accuracy: location.horizontalAccuracy, map: scene.map,
                     location: location, context: context)
        } else {
            drawText("กำลังหาตำแหน่ง", font: bodyFont, color: Palette.secondary,
                     at: CGPoint(x: center.x, y: center.y + 9), alignment: .center, context: context)
        }
        context.restoreGState()
    }

    /// Apple Maps' location puck: a blue dot in a white ring over a faint accuracy halo.
    private func drawPuck(at point: CGPoint, accuracy: CLLocationAccuracy, map: DashMapImage?,
                          location: CLLocation, context: CGContext) {
        if let map, accuracy > 0 {
            let edge = map.pixel(for: location.coordinate.offset(northMeters: accuracy))
            let radius = min(abs(edge.y - map.pixel(for: location.coordinate).y), 120)
            if radius > 18 {
                context.setFillColor(Palette.blue.copy(alpha: 0.16) ?? Palette.blue)
                context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                               width: radius * 2, height: radius * 2))
            }
        }
        context.setFillColor(Palette.label)
        context.fillEllipse(in: CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28))
        context.setFillColor(Palette.blue)
        context.fillEllipse(in: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
    }

    // MARK: Cards

    private func drawCard(_ rect: CGRect, context: CGContext) {
        context.setFillColor(Palette.card)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: Layout.cornerRadius,
                               cornerHeight: Layout.cornerRadius, transform: nil))
        context.fillPath()
    }

    private func drawClockCard(_ scene: DashScene, in rect: CGRect, context: CGContext) {
        drawCard(rect, context: context)
        let left = rect.minX + Layout.cardPadding
        drawText(timeFormatter.string(from: scene.date), font: clockFont, color: Palette.label,
                 at: CGPoint(x: left, y: rect.minY + 140), context: context)
        drawText(dateFormatter.string(from: scene.date), font: bodyFont, color: Palette.secondary,
                 at: CGPoint(x: left, y: rect.minY + 196), context: context)
    }

    private func drawRideCard(_ scene: DashScene, in rect: CGRect, context: CGContext) {
        drawCard(rect, context: context)
        let left = rect.minX + Layout.cardPadding

        drawSymbol("speedometer", at: CGPoint(x: left, y: rect.minY + 26), context: context)
        drawText("ความเร็ว", font: headingFont, color: Palette.secondary,
                 at: CGPoint(x: left + 32, y: rect.minY + 46), context: context)

        let speed = scene.location.map { $0.speed >= 0 ? String(Int(($0.speed * 3.6).rounded())) : "–" } ?? "–"
        let speedEnd = drawText(speed, font: speedFont, color: Palette.label,
                                at: CGPoint(x: left, y: rect.minY + 142), context: context)
        drawText("กม./ชม.", font: bodyFont, color: Palette.secondary,
                 at: CGPoint(x: speedEnd + 12, y: rect.minY + 142), context: context)

        let rowBaseline = rect.minY + 204
        let vehicle = scene.vehicle
        guard vehicle.connected else {
            drawSymbol("bolt.slash.fill", at: CGPoint(x: left, y: rowBaseline - 24), context: context)
            drawText("รถยังไม่เชื่อม Bluetooth", font: bodyFont, color: Palette.secondary,
                     at: CGPoint(x: left + 36, y: rowBaseline), context: context)
            return
        }
        var x = left
        if let voltage = vehicle.voltage {
            drawSymbol(Self.batterySymbol(voltage), at: CGPoint(x: x, y: rowBaseline - 22), context: context)
            x = drawText(String(format: "%.1f V", voltage), font: bodyStrongFont, color: Palette.label,
                         at: CGPoint(x: x + 44, y: rowBaseline), context: context) + 28
        }
        if let locked = vehicle.locked {
            drawSymbol(locked ? "lock.fill" : "lock.open.fill", at: CGPoint(x: x, y: rowBaseline - 24), context: context)
            drawText(locked ? "ล็อกอยู่" : "ปลดล็อก", font: bodyFont, color: Palette.label,
                     at: CGPoint(x: x + 30, y: rowBaseline), context: context)
        }
    }

    static func batterySymbol(_ voltage: Double) -> String {
        switch voltage {
        case 12.4...: return "battery.100"
        case 12.0..<12.4: return "battery.75"
        case 11.6..<12.0: return "battery.50"
        default: return "battery.25"
        }
    }

    // MARK: Primitives (top-left coordinates)

    /// Draws one line with its baseline at `point.y`; returns the x where it ends.
    @discardableResult
    private func drawText(_ text: String, font: CTFont, color: CGColor, at point: CGPoint,
                          alignment: NSTextAlignment = .left, context: CGContext) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = alignment == .center ? point.x - width / 2 : point.x
        context.textPosition = CGPoint(x: x, y: point.y)
        CTLineDraw(line, context)
        return x + width
    }

    private func drawSymbol(_ name: String, at topLeft: CGPoint, context: CGContext) {
        guard let image = symbols[name] else { return }
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

extension CLLocationCoordinate2D {
    /// The point `northMeters` due north (negative: south).
    func offset(northMeters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude + northMeters / 111_320, longitude: longitude)
    }
}
