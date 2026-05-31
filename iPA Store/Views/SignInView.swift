// Views/SignInView.swift
import SwiftUI

struct SignInView: View {
    @EnvironmentObject var auth: AppleAuthService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var twoFACode = ""

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "bag.fill")
                        .font(.system(size: 52))
                        .foregroundColor(.accentColor)

                    Text("iPA Store")
                        .font(.largeTitle.bold())

                    Text("Sign in with your Apple ID to download apps")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 36)

                if auth.isSignedIn {
                    signedInView
                } else if auth.requires2FA {
                    twoFAView
                } else {
                    signInForm
                }
            }
            .padding(32)
            .frame(width: 420)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .padding(14)
        }
    }

    // MARK: - Sign In Form

    var signInForm: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                TextField("Apple ID (email)", text: $email)
                    .textFieldStyle(.roundedBorder)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            if let error = auth.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await auth.signIn(email: email, password: password) }
            } label: {
                HStack {
                    if auth.isLoading { ProgressView().controlSize(.small) }
                    Text(auth.isLoading ? "Signing in..." : "Sign In")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(email.isEmpty || password.isEmpty || auth.isLoading)

            Text("Credentials are stored securely in Keychain and never leave your device.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - 2FA View

    var twoFAView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            Text("Two-Factor Authentication")
                .font(.headline)

            Text("Enter the 6-digit code sent to your trusted Apple device.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            TextField("000000", text: $twoFACode)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit())
                .onChange(of: twoFACode) { _, new in
                    // Strip non-digits and cap at 6
                    twoFACode = String(new.filter(\.isNumber).prefix(6))
                }

            if let error = auth.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await auth.submitTwoFACode(twoFACode) }
            } label: {
                HStack {
                    if auth.isLoading { ProgressView().controlSize(.small) }
                    Text(auth.isLoading ? "Verifying..." : "Verify Code")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(twoFACode.count != 6 || auth.isLoading)

            if auth.canRequestSMSCode {
                Button("Text Code") {
                    Task {
                        twoFACode = ""
                        await auth.requestSMSCode()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(auth.isLoading)
            }

            Button("Start Over") {
                auth.requires2FA = false
                auth.errorMessage = nil
                twoFACode = ""
            }
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Signed In

    var signedInView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Signed In")
                .font(.title2.bold())

            Text(auth.appleID)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button("Sign Out", role: .destructive) {
                auth.signOut()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}
