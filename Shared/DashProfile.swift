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
    /// Tell the dash the phone app's state the way the official ZONTES app does:
    /// ECP_P2C_APPSTATUS_FOREGROUND (0x20020) with this mode on the CAR_DATA socket ~130 ms after
    /// the dash opens it, then every second, with CHECK_SN_RESULT on CAR_DATA too (RideScreen AA,
    /// field-tested on Zontes). 2 is the official app's normal state (its own car screen); 1 a true
    /// mirror. 0 sends nothing. Sent on CAR_CTRL instead (build 24), the 368G never acked it.
    var appStatusMode = 0

    // Shared by E, F and G.
    let proactivePxcHeartbeat = true
    let plainVideoFraming = true
    let phoneBrand = "samsung"
    let phoneModel = "SM-F711B"
    let phoneOsVersion = "35"
    /// Dash area 1280x535 is announced back as 1280x528 (16-aligned); the stream must match it.
    let fallbackWidth = 1280
    let fallbackHeight = 528
    /// The SM-F711B's display, upright: what the official app reads off getRealSize().
    let phoneScreenWidth = 1080
    let phoneScreenHeight = 2640
    let frameRate = 30
    let baseBitRate = 2_500_000
    let keyframeIntervalSeconds = 1.0

    static let zontesG = DashProfile(
        id: "zontes_368g_g",
        title: "Zontes 368G (G)",
        detail: "เหมือนแอป ZONTES ทางการที่สุด: เวอร์ชัน 1.12 (3034) และส่ง supportFunction คืนจอ",
        clientPackage: "tayo.com.ZontesIntelligence",
        clientVersionCode: 3034,
        clientVersionFingerprint: "V:1.12(3034)--ONLINE",
        clientInfoSupportFunction: true,
        supportFunction: 128
    )

    static let zontesH = DashProfile(
        id: "zontes_368g_h",
        title: "Zontes 368G (H) - แนะนำ",
        detail: "ตัวตนแอป ZONTES และบอกจอทุก 1 วินาทีว่าแอปเปิดอยู่ (0x20020) ทางช่อง CAR_DATA แบบแอปทางการ",
        clientPackage: "tayo.com.ZontesIntelligence",
        clientVersionCode: 3034,
        clientVersionFingerprint: "V:1.12(3034)--ONLINE",
        clientInfoSupportFunction: true,
        supportFunction: 128,
        appStatusMode: 2
    )

    /// RideScreen AA's identity (github.com/mgb1982/ridescreen-aa), which reports every Zontes 368
    /// working: the CFMOTO app's package at versionCode 126, plus the same Zontes app state.
    static let zontesI = DashProfile(
        id: "zontes_368g_i",
        title: "Zontes 368G (I) - แบบ RideScreen",
        detail: "ตัวตนแอป CFMOTO แบบแอป RideScreen AA ที่ใช้กับ 368 ได้ และบอกจอว่าแอปเปิดอยู่ (0x20020)",
        clientPackage: "com.cfmoto.cfmotointernational",
        clientVersionCode: 126,
        clientVersionFingerprint: "opencfmoto-poc",
        clientInfoSupportFunction: true,
        supportFunction: 128,
        appStatusMode: 2
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

    /// H first: the profile that paints on the 368G (field log 2026-11-08).
    static let all: [DashProfile] = [zontesH, zontesI, zontesG, zontesF, zontesE]

    static func byID(_ id: String?) -> DashProfile {
        all.first { $0.id == id } ?? zontesH
    }
}
