import SwiftUI

/// The dash's turn card, for the app: arrow, distance, instruction, then where to and when.
struct DashGuidanceBanner: View {
    @ObservedObject var navigator: DashNavigator

    var body: some View {
        let scene = navigator.sceneNavigation()
        let symbol = navigator.status == .rerouting ? "arrow.triangle.2.circlepath" : (scene?.maneuver.symbol ?? "arrow.up")
        let headline = navigator.status == .arrived ? "ถึงแล้ว"
            : (navigator.status == .rerouting ? "หาเส้นทางใหม่" : (scene?.distanceToManeuver.map(DashFormat.distance) ?? "–"))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 32, weight: .semibold))
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.title2.weight(.bold).monospacedDigit())
                    if let instruction = scene?.instruction, navigator.status == .guiding {
                        Text(instruction)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if let progress = navigator.progress, navigator.status != .arrived {
                HStack(spacing: 6) {
                    Text(Self.clock(Date().addingTimeInterval(progress.remainingTime)))
                        .fontWeight(.semibold)
                    Text("· \(DashFormat.distance(progress.remainingDistance))")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(navigator.destination?.name ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.subheadline.monospacedDigit())
            }
        }
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
