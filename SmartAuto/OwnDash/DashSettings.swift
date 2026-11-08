import Foundation
import UIKit

/// The rider's choices for the dash screen and routes, kept in UserDefaults.
enum DashSettings {
    enum Theme: String, CaseIterable, Identifiable {
        case dark, light, system

        var id: String { rawValue }
        var title: String {
            switch self {
            case .dark: return "มืด"
            case .light: return "สว่าง"
            case .system: return "อัตโนมัติ"
            }
        }
    }

    static let themeKey = "dash.theme"
    static let avoidHighwaysKey = "dash.avoidHighways"
    static let avoidTollsKey = "dash.avoidTolls"
    static let zoomKey = "dash.zoom"
    static let threeDKey = "dash.threeD"
    static let autoConnectKey = "dash.autoConnect"
    static let voiceKey = "dash.voice"
    static let mapOnRightKey = "dash.mapOnRight"

    /// Turn the dash screen on and off by itself, like RideScreen; on unless turned off.
    static var autoConnect: Bool { UserDefaults.standard.object(forKey: autoConnectKey) as? Bool ?? true }
    /// Spoken turn-by-turn; on unless turned off.
    static var voice: Bool { UserDefaults.standard.object(forKey: voiceKey) as? Bool ?? true }
    /// The dash laid out mirrored: map on the right, cards on the left (and the reverse in guidance).
    static var mapOnRight: Bool { UserDefaults.standard.bool(forKey: mapOnRightKey) }

    /// Guidance map tilted like Apple Maps' 3D driving view (dash and phone); on unless turned off.
    static var threeD: Bool { UserDefaults.standard.object(forKey: threeDKey) as? Bool ?? true }

    /// How far the dash map reaches: a multiplier on its metres per pixel, closest first.
    static let zoomLevels: [Double] = [0.6, 0.8, 1.0, 1.4, 2.0]

    static var zoom: Double {
        let value = UserDefaults.standard.double(forKey: zoomKey)
        return zoomLevels.contains(value) ? value : 1.0
    }

    /// One step closer (closer: true) or further out; returns the new level.
    @discardableResult
    static func stepZoom(closer: Bool) -> Double {
        let index = zoomLevels.firstIndex(of: zoom) ?? 2
        let next = zoomLevels[max(0, min(zoomLevels.count - 1, index + (closer ? -1 : 1)))]
        UserDefaults.standard.set(next, forKey: zoomKey)
        return next
    }

    static var theme: Theme {
        Theme(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .dark
    }

    static var avoidHighways: Bool { UserDefaults.standard.bool(forKey: avoidHighwaysKey) }
    /// Motorcycles may not use Thailand's expressways or motorways, which are the toll roads; so
    /// avoided unless turned off.
    static var avoidTolls: Bool { UserDefaults.standard.object(forKey: avoidTollsKey) as? Bool ?? true }

    /// The style to draw now. "ตามโทรศัพท์" follows the iPhone's own light or dark appearance.
    @MainActor
    static func currentStyle() -> DashStyle {
        switch theme {
        case .dark: return .dark
        case .light: return .light
        case .system: return UIScreen.main.traitCollection.userInterfaceStyle == .light ? .light : .dark
        }
    }
}
