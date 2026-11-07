import Foundation

/// Identifiers shared by the app and its broadcast extension.
///
/// The bundle identifiers live in project.yml; these must match it. The app group is how the
/// two processes talk: settings flow app -> extension, status and log flow extension -> app.
enum AppConstants {
    static let appGroup = "group.com.nextradeveloper.smartauto"
    static let broadcastExtensionBundleID = "com.nextradeveloper.smartauto.broadcast"

    /// EasyConn wake probe / EC init port on the dash.
    static let easyConnPort: UInt16 = 10930
    /// Ports the dash connects back to (PXC, media control, media stream). Go listens on them.
    static let reversePorts: [UInt16] = [10922, 10921, 10920]
}
