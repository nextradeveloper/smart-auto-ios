import SwiftUI
import UIKit

@main
struct SmartAutoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Portrait everywhere except the full-screen dash map, which turns landscape like the dash.
@MainActor
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait

    static func set(_ mask: UIInterfaceOrientationMask, rotateTo orientation: UIInterfaceOrientationMask) {
        self.mask = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        var controller = scene.windows.first { $0.isKeyWindow }?.rootViewController ?? scene.windows.first?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
