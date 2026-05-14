import SwiftUI

struct AuthView: View {
    @Environment(AppState.self) private var state
    let api: CueAPI

    enum Step { case phone, code, name }
    @State private var step: Step = .phone
    @State private var phone: String = ""
    @State private var code: String = ""
    @State private var name: String = ""
    @State private var pendingAuth: VerifyCodeResponse?
    @State private var sending = false
    @State private var errorMessage: String?

    var body: some View {
        let palette = state.palette

        ZStack {
            palette.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("Orbit")
                    .font(Fonts.serif(28, weight: .medium))
                    .tracking(-0.5)
                    .foregroundStyle(palette.ink)
                    .padding(.bottom, 8)

                Text(headline)
                    .font(Fonts.serif(28))
                    .tracking(-0.4)
                    .lineSpacing(4)
                    .foregroundStyle(palette.inkMuted)
                    .padding(.bottom, 28)

                switch step {
                case .phone: phoneStep
                case .code: codeStep
                case .name: nameStep
                }

                if let msg = errorMessage {
                    Text(msg)
                        .font(Fonts.sans(12))
                        .foregroundStyle(.red)
                        .padding(.top, 12)
                }

                Spacer(minLength: 0)

                #if DEBUG
                Text("Dev tip: bypass code 123456 works for any phone number.")
                    .font(Fonts.sans(11))
                    .foregroundStyle(palette.inkFade)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                #endif
            }
            .padding(.horizontal, 22)
            .padding(.top, Geo.statusBarReserve + 24)
            .padding(.bottom, 30)
        }
    }

    private var phoneStep: some View {
        let palette = state.palette
        return VStack(alignment: .leading, spacing: 16) {
            Text("PHONE NUMBER")
                .font(Fonts.sans(11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(palette.inkMuted)

            TextField("+1 555 555 5555", text: $phone)
                .font(Fonts.sans(18))
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(palette.cardEdge, lineWidth: 0.5)
                        )
                )
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .autocorrectionDisabled()

            Button {
                Task { await sendCode() }
            } label: {
                HStack(spacing: 8) {
                    if sending { ProgressView().tint(palette.bg) }
                    Text(sending ? "Sending…" : "Send code")
                        .font(Fonts.sans(15, weight: .semibold))
                }
                .foregroundStyle(palette.bg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(canSendCode ? palette.ink : palette.subtleStrong))
            }
            .buttonStyle(.plain)
            .disabled(!canSendCode || sending)
        }
    }

    private var codeStep: some View {
        let palette = state.palette
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("6-DIGIT CODE")
                    .font(Fonts.sans(11, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(palette.inkMuted)
                Spacer()
                Button("Change number") {
                    step = .phone
                    code = ""
                    errorMessage = nil
                }
                .font(Fonts.sans(12, weight: .semibold))
                .foregroundStyle(palette.accent)
            }

            TextField("123456", text: $code)
                .font(Fonts.sans(22, weight: .semibold))
                .monospacedDigit()
                .tracking(8)
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(palette.cardEdge, lineWidth: 0.5)
                        )
                )
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)

            Text("Sent to \(phone). Code is good for 10 minutes.")
                .font(Fonts.sans(12))
                .foregroundStyle(palette.inkMuted)

            Button {
                Task { await verifyCode() }
            } label: {
                HStack(spacing: 8) {
                    if sending { ProgressView().tint(palette.bg) }
                    Text(sending ? "Verifying…" : "Verify + continue")
                        .font(Fonts.sans(15, weight: .semibold))
                }
                .foregroundStyle(palette.bg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(canVerify ? palette.ink : palette.subtleStrong))
            }
            .buttonStyle(.plain)
            .disabled(!canVerify || sending)
        }
    }

    private var nameStep: some View {
        let palette = state.palette
        return VStack(alignment: .leading, spacing: 16) {
            Text("YOUR NAME")
                .font(Fonts.sans(11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(palette.inkMuted)

            TextField("First name", text: $name)
                .font(Fonts.sans(18))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(palette.cardEdge, lineWidth: 0.5)
                        )
                )
                .textContentType(.givenName)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { if canSaveName { Task { await saveName() } } }

            Button {
                Task { await saveName() }
            } label: {
                HStack(spacing: 8) {
                    if sending { ProgressView().tint(palette.bg) }
                    Text(sending ? "Saving…" : "Continue")
                        .font(Fonts.sans(15, weight: .semibold))
                }
                .foregroundStyle(palette.bg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(canSaveName ? palette.ink : palette.subtleStrong))
            }
            .buttonStyle(.plain)
            .disabled(!canSaveName || sending)
        }
    }

    private var headline: String {
        switch step {
        case .phone, .code: return "Sign in to listen + ask."
        case .name: return "What should we call you?"
        }
    }

    private var canSendCode: Bool {
        phone.filter(\.isNumber).count >= 10
    }

    private var canVerify: Bool {
        code.filter(\.isNumber).count == 6
    }

    private var canSaveName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func sendCode() async {
        errorMessage = nil
        sending = true
        defer { sending = false }
        do {
            try await api.sendCode(phoneNumber: phone)
            withAnimation(.easeOut(duration: 0.22)) { step = .code }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func verifyCode() async {
        errorMessage = nil
        sending = true
        defer { sending = false }
        do {
            let resp = try await api.verifyCode(phoneNumber: phone, code: code)
            let existingName = resp.account.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existingName.isEmpty {
                pendingAuth = resp
                withAnimation(.easeOut(duration: 0.22)) { step = .name }
            } else {
                api.applyAuth(token: resp.token, account: resp.account)
                }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func saveName() async {
        guard let auth = pendingAuth else { return }
        errorMessage = nil
        sending = true
        defer { sending = false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated = try await api.updateAccount(name: trimmed, tokenOverride: auth.token)
            api.applyAuth(token: auth.token, account: updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
