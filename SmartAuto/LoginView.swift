import SwiftUI

/// ZONTES Smart no longer has email accounts, so the vehicle is paired from its QR code.
struct LoginView: View {
    @EnvironmentObject private var model: ZontesAppModel
    @State private var acceptsTerms = false
    @State private var policy: AppPolicy?
    @State private var showsConsentReminder = false
    @State private var showsScanner = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Smart Auto")
                    .font(.headline)
                    .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 8) {
                    Text("เชื่อมรถ")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("สแกน QR Code ของรถเพื่อสั่งรถผ่าน Bluetooth")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 96, weight: .light))
                    .foregroundStyle(AppTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 12) {
                    if showsConsentReminder {
                        Text("กรุณายอมรับเงื่อนไขก่อนใช้งาน")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        acceptsTerms.toggle()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: acceptsTerms ? "checkmark.square.fill" : "square")
                                .font(.title3)
                                .foregroundStyle(acceptsTerms ? AppTheme.accent : Color.secondary)
                            Text("ยอมรับเงื่อนไขการใช้แอป และรับทราบนโยบายข้อมูลและความปลอดภัย")
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(acceptsTerms ? "ยอมรับแล้ว" : "ยังไม่ยอมรับ")
                    .accessibilityAddTraits(acceptsTerms ? .isSelected : [])
                    .onChange(of: acceptsTerms) { accepted in
                        if accepted { showsConsentReminder = false }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { policyLinks }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 0) { policyLinks }
                    }

                    Button(action: scan) {
                        Label("สแกน QR Code", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .sheet(isPresented: $showsScanner) {
            PairingScannerView { code in
                showsScanner = false
                model.pair(with: code)
            }
        }
        .sheet(item: $policy) { item in
            NavigationStack {
                AppPolicyView(policy: item)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("ปิด") { policy = nil }
                        }
                    }
            }
            .tint(AppTheme.accent)
        }
    }

    private var policyLinks: some View {
        ForEach(AppPolicy.allCases) { item in
            Button(item.shortTitle) { policy = item }
                .font(.footnote)
                .tint(AppTheme.accent)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("อ่าน\(item.title)")
        }
    }

    private func scan() {
        guard acceptsTerms else {
            showsConsentReminder = true
            return
        }
        showsScanner = true
    }
}
