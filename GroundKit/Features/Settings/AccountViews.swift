import AuthenticationServices
import SwiftUI

/// The Account section at the top of Settings.
struct AccountSection: View {
    @Environment(AccountService.self) private var account
    @State private var showSignIn = false

    var body: some View {
        if account.isConfigured {
            Section {
                if let user = account.user {
                    NavigationLink {
                        AccountView()
                    } label: {
                        LabeledContent {
                            Text(syncText).font(.footnote)
                        } label: {
                            Text(account.displayName ?? user.email ?? "Your account")
                            if account.displayName != nil, let email = user.email { Text(email) }
                        }
                    }
                } else {
                    Button("Sign in or create an account") { showSignIn = true }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Optional. Signed in, your airport, glove mode, keep screen on, appearance and wind limits sync with GroundKit on Android and the web. Age and the data source stay on this device.")
            }
            .sheet(isPresented: $showSignIn) { SignInView() }
        }
    }

    private var syncText: String {
        if account.syncing { return "Syncing…" }
        if account.syncError != nil { return "Not synced" }
        return "Synced"
    }
}

/// Sign in with Apple, Google or Microsoft, or with an email and password; create an
/// account; or ask for a password-reset email.
struct SignInView: View {
    @Environment(AccountService.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign in"
        case create = "Create account"
        var id: Self { self }
    }

    @State private var mode = Mode.signIn
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var appleNonce = ""

    private static let minPassword = 8

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SignInWithAppleButton(mode == .create ? .signUp : .signIn) { request in
                        appleNonce = PKCE.random()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = PKCE.sha256Hex(appleNonce)
                    } onCompletion: { result in
                        Task { await finishApple(result) }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(minHeight: 50)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    ForEach(AuthProvider.allCases, id: \.self) { provider in
                        Button(provider.label) { Task { await signIn(with: provider) } }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .disabled(busy)

                Section {
                    Picker("Account", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    if mode == .create {
                        TextField("Name (optional)", text: $name)
                            .textContentType(.name)
                    }
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(mode == .create ? .newPassword : .password)
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text(mode.rawValue).bold() }
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                } header: {
                    Text("With email")
                } footer: {
                    if mode == .create {
                        Text("At least \(Self.minPassword) characters. We send a link to confirm your address. See the privacy policy at groundkit.harrydatahub.com/privacy.")
                    } else {
                        Button("Forgot password?") { Task { await reset() } }
                            .font(.footnote)
                            .disabled(busy)
                    }
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color("StatusWarning")) }
                }
                if let notice {
                    Section { Label(notice, systemImage: "envelope.fill") }
                }
            }
            .navigationTitle(mode == .create ? "Create account" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onChange(of: account.user) { _, user in if user != nil { dismiss() } }
            .onChange(of: mode) { error = nil }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do {
            try await work()
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // The person closed the sign-in page.
        } catch let e as ASAuthorizationError where e.code == .canceled {
            // The person cancelled Sign in with Apple.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submit() async {
        if mode == .create && password.count < Self.minPassword {
            error = "Use at least \(Self.minPassword) characters for your password."
            return
        }
        await run {
            if mode == .signIn {
                try await account.signIn(email: email, password: password)
            } else if try await !account.signUp(email: email, password: password, displayName: name) {
                mode = .signIn
                notice = "We sent a link to \(email). Open it to confirm your address, then sign in here."
            }
        }
    }

    private func reset() async {
        guard !email.isEmpty else {
            error = "Enter your email address first."
            return
        }
        await run {
            try await account.resetPassword(email: email)
            notice = "If \(email) has an account, we sent it a link to choose a new password."
        }
    }

    private func signIn(with provider: AuthProvider) async {
        guard let start = account.providerStart(provider) else { return }
        await run {
            let callback = try await webAuthenticationSession.authenticate(
                using: start.url, callbackURLScheme: SupabaseConfig.callbackScheme, preferredBrowserSession: .ephemeral)
            try await account.providerFinish(callback: callback, pkce: start.pkce)
        }
    }

    private func finishApple(_ result: Result<ASAuthorization, Error>) async {
        await run {
            let auth = try result.get()
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                throw SupabaseError(status: 0, code: nil, message: "Apple did not return a sign-in token.")
            }
            let name = credential.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
            try await account.signInWithApple(idToken: token, rawNonce: appleNonce, fullName: name)
        }
    }
}

/// The signed-in account: name, sync status, sign out and delete.
struct AccountView: View {
    @Environment(AccountService.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            if let user = account.user {
                Section {
                    LabeledContent("Email", value: user.email ?? "Not shared by the provider")
                    LabeledContent("Signed in with", value: user.providers.map(Self.providerName).joined(separator: ", "))
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .onSubmit { Task { await saveName() } }
                    if name != (account.displayName ?? "") {
                        Button("Save name") { Task { await saveName() } }.disabled(busy)
                    }
                }
                Section {
                    LabeledContent("Settings", value: account.syncing ? "Syncing…" : account.syncError == nil ? "Synced" : "Not synced")
                    if let syncError = account.syncError {
                        Text(syncError).font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { Task { await account.sync() } }
                    }
                } footer: {
                    Text("Your airport, glove mode, keep screen on, appearance and wind limits. Turnarounds, shifts and notes sync through iCloud as before.")
                }
                Section {
                    Button("Sign out") {
                        Task {
                            await account.signOut()
                            dismiss()
                        }
                    }
                }
                Section {
                    Button("Delete account", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Deletes your account, profile and synced settings for good. Settings on this device stay.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color("StatusWarning")) }
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .onAppear { name = account.displayName ?? "" }
        .confirmationDialog("Delete your GroundKit account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                Task {
                    busy = true
                    defer { busy = false }
                    do {
                        try await account.deleteAccount()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func saveName() async {
        busy = true
        defer { busy = false }
        do {
            try await account.saveDisplayName(name)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func providerName(_ id: String) -> String {
        ["email": "Email", "apple": "Apple", "google": "Google", "azure": "Microsoft"][id] ?? id.capitalized
    }
}
