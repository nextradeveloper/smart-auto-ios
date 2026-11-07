import Foundation

/// The identity this phone presents to the dash, copied from the Android app's
/// TBoxModelProfile.ZONTES_368G_TEST_E / _F / _G (one of which paints on the user's 368G).
///
/// Brand, model and OS version default to the Android phone those tests ran on (Samsung
/// SM-F711B, Android 15 = SDK 35): the Go library hard-codes phoneType "Android", so the dash
/// already believes it is talking to an Android phone, and these are the exact values it accepted.
struct DashProfile: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String

    let clientPackage: String
    let clientVersionCode: Int
    let clientVersionFingerprint: String
    let clientInfoSupportFunction: Bool
    let supportFunction: Int

    // Shared by E, F and G.
    let proactivePxcHeartbeat = true
    let plainVideoFraming = true
    let phoneBrand = "samsung"
    let phoneModel = "SM-F711B"
    let phoneOsVersion = "35"
    /// Dash area 1280x535 is announced back as 1280x528 (16-aligned); the stream must match it.
    let fallbackWidth = 1280
    let fallbackHeight = 528
    let frameRate = 30
    let baseBitRate = 2_500_000
    let keyframeIntervalSeconds = 1.0

    static let zontesG = DashProfile(
        id: "zontes_368g_g",
        title: "Zontes 368G (G) - แนะนำ",
        detail: "เหมือนแอป ZONTES ทางการที่สุด: เวอร์ชัน 1.12 (3034) และส่ง supportFunction คืนจอ",
        clientPackage: "tayo.com.ZontesIntelligence",
        clientVersionCode: 3034,
        clientVersionFingerprint: "V:1.12(3034)--ONLINE",
        clientInfoSupportFunction: true,
        supportFunction: 128
    )

    static let zontesF = DashProfile(
        id: "zontes_368g_f",
        title: "Zontes 368G (F)",
        detail: "ตัวตนแอป ZONTES เวอร์ชัน 1.12 (3034)",
        clientPackage: "tayo.com.ZontesIntelligence",
        clientVersionCode: 3034,
        clientVersionFingerprint: "V:1.12(3034)--ONLINE",
        clientInfoSupportFunction: false,
        supportFunction: 0
    )

    static let zontesE = DashProfile(
        id: "zontes_368g_e",
        title: "Zontes 368G (E)",
        detail: "ตัวตนแอป ZONTES กับเวอร์ชันเริ่มต้นของไลบรารี",
        clientPackage: "tayo.com.ZontesIntelligence",
        clientVersionCode: 0,
        clientVersionFingerprint: "",
        clientInfoSupportFunction: false,
        supportFunction: 0
    )

    static let all: [DashProfile] = [zontesG, zontesF, zontesE]

    static func byID(_ id: String?) -> DashProfile {
        all.first { $0.id == id } ?? zontesG
    }
}
