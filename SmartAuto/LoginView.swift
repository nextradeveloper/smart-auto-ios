import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: ZontesAppModel
    @State private var account = ""
    @State private var password = ""
    @State private var acceptsTerms = false
    @State private var showsPassword = false
    @State private var policy: AppPolicy?
    @State private var showsConsentReminder = false
    @State private var showsPasswordHelp = false
    @State private var showsScanner = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case account, password }

    private var canSignIn: Bool {
        acceptsTerms && !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty && !model.isBusy
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text("Smart Auto")
                        .font(.headline)
                        .padding(.bottom, 16)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("เข้าสู่ระบบ")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("ใช้บัญชี ZONTES Smart ของคุณ หรือเชื่อมรถด้วย QR Code")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("อีเมล").font(.subheadline.weight(.medium))
                            TextField("name@example.com", text: $account)
                                .textContentType(.username)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .account)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                                .padding(16)
                                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(focusedField == .account ? AppTheme.accent : Color.white.opacity(0.12))
                                        .allowsHitTesting(false)
                                }
                                .accessibilityLabel("อีเมล ZONTES Smart")
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("รหัสผ่าน").font(.subheadline.weight(.medium))
                            HStack(spacing: 8) {
                                Group {
                                    if showsPassword {
                                        TextField("รหัสผ่าน", text: $password)
                                    } else {
                                        SecureField("รหัสผ่าน", text: $password)
                                    }
                                }
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .password)
                                .submitLabel(.go)
                                .onSubmit(signIn)
                                .accessibilityLabel("รหัสผ่าน ZONTES Smart")

                                Button {
                                    showsPassword.toggle()
                                    focusedField = .password
                                } label: {
                                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(showsPassword ? "ซ่อนรหัสผ่าน" : "แสดงรหัสผ่าน")
                            }
                            .padding(.leading, 16)
                            .padding(.trailing, 6)
                            .padding(.vertical, 6)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(focusedField == .password ? AppTheme.accent : Color.white.opacity(0.12))
                                    .allowsHitTesting(false)
                            }
                        }
                        Button("ลืมรหัสผ่าน?") { showsPasswordHelp = true }
                            .font(.footnote)
                            .tint(AppTheme.accent)
                            .frame(minHeight: 44)
                    }
                    .disabled(model.isBusy)

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
                        .disabled(model.isBusy)
                        .accessibilityValue(acceptsTerms ? "ยอมรับแล้ว" : "ยังไม่ยอมรับ")
                        .accessibilityAddTraits(acceptsTerms ? .isSelected : [])
                        .id("consent")
                        .onChange(of: acceptsTerms) { accepted in
                            if accepted { showsConsentReminder = false }
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { policyLinks }
                                .fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: 0) { policyLinks }
                        }

                        Button(action: signIn) {
                            HStack(spacing: 10) {
                                if model.isBusy { ProgressView().tint(.black) }
                                Text(model.isBusy ? "กำลังเข้าสู่ระบบ…" : "เข้าสู่ระบบ")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(!canSignIn)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                            Text("หรือ").font(.footnote).foregroundStyle(.secondary)
                            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                        }
                        Button(action: pairWithCode) {
                            Label("เชื่อมรถด้วย QR Code", systemImage: "qrcode.viewfinder")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(model.isBusy)
                        Text("แอป ZONTES Smart รุ่นใหม่ไม่มีบัญชีอีเมลแล้ว ให้สแกน QR Code ของรถแทน แล้วสั่งรถผ่าน Bluetooth ได้เลย")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 440, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: showsConsentReminder) { show in
                if show { proxy.scrollTo("consent", anchor: .center) }
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .alert("ลืมรหัสผ่าน", isPresented: $showsPasswordHelp) {
            Button("ตกลง", role: .cancel) {}
        } message: {
            Text("เปิดแอป ZONTES Smart แล้วใช้เมนูลืมรหัสผ่าน จากนั้นกลับมาเข้าสู่ระบบที่นี่ด้วยรหัสผ่านใหม่")
        }
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

    private func pairWithCode() {
        guard !model.isBusy else { return }
        focusedField = nil
        guard acceptsTerms else {
            showsConsentReminder = true
            return
        }
        showsScanner = true
    }

    private func signIn() {
        guard !model.isBusy else { return }
        focusedField = nil
        guard acceptsTerms else {
            showsConsentReminder = true
            return
        }
        guard canSignIn else { return }
        Task {
            await model.login(account: account.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        }
    }
}
