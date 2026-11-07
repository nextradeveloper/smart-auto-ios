import ReplayKit
import SwiftUI
import UIKit

/// iOS only lets a broadcast start from its own picker button. This keeps one picker, pinned
/// to our extension, and presses its button for us so the app can show its own big button.
final class BroadcastLauncher: ObservableObject {
    fileprivate weak var picker: RPSystemBroadcastPickerView?

    func launch() {
        guard let picker else { return }
        for case let button as UIButton in picker.subviews {
            button.sendActions(for: .allTouchEvents)
            return
        }
    }
}

/// A tiny, invisible host for the system picker. Put it anywhere in the view tree.
struct BroadcastPickerHost: UIViewRepresentable {
    let launcher: BroadcastLauncher

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = AppConstants.broadcastExtensionBundleID
        picker.showsMicrophoneButton = false
        picker.alpha = 0.011
        launcher.picker = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        launcher.picker = uiView
    }
}
