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
            case .system: return "ตามโทรศัพท์"
            }
        }
    }

    static let themeKey = "dash.theme"
    static let avoidHighwaysKey = "dash.avoidHighways"
    static let avoidTollsKey = "dash.avoidTolls"

    static var theme: Theme {
        Theme(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .dark
    }

    static var avoidHighways: Bool { UserDefaults.standard.bool(forKey: avoidHighwaysKey) }
    static var avoidTolls: Bool { UserDefaults.standard.bool(forKey: avoidTollsKey) }

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
