import DianeKit
import SwiftUI

/// Server → member → password. The app is the member remote: family/kiosk
/// sign-in, first-run setup, and password claims stay on the web kiosk.
struct SignInFlowView: View {
    enum Step: Hashable {
        case members
        case password(Components.Schemas.MemberIdentity)
    }

    @Environment(AppState.self) private var appState

    /// Remembered across launches — a family signs into one server.
    @AppStorage("diane.serverInput") private var serverInput = ""

    @State private var path: [Step] = []
    @State private var probing = false
    @State private var serverError: String?
    @State private var origin: URL?
    @State private var identities: Components.Schemas.IdentitiesResponse?

    var body: some View {
        NavigationStack(path: $path) {
            serverStep
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .members:
                        membersStep
                    case .password(let member):
                        PasswordStepView(
                            origin: origin!,
                            member: member,
                            onSignedIn: { token, sessionMember in
                                appState.didSignIn(
                                    origin: origin!,
                                    token: token,
                                    member: sessionMember
                                )
                            }
                        )
                    }
                }
        }
    }

    private var serverStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "house.lodge")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Diane")
                .font(.largeTitle.bold())
            Text("Your family hub. Enter your home server to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                TextField("family.example.com", text: $serverInput)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { connect() }

                if let serverError {
                    Text(serverError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button(action: connect) {
                    if probing {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(probing || serverInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 420)
            Spacer()
            Spacer()
        }
    }

    private var membersStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 16)], spacing: 20) {
                ForEach(identities?.members ?? [], id: \.id) { member in
                    Button {
                        path.append(.password(member))
                    } label: {
                        VStack(spacing: 8) {
                            MemberAvatarView(
                                name: member.name,
                                colorHex: member.color,
                                avatar: member.avatar,
                                size: 72
                            )
                            Text(member.name)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(identities?.householdName ?? "Who are you?")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func connect() {
        guard let url = ServerURL.normalize(serverInput) else {
            serverError = "That doesn't look like a server address."
            return
        }
        probing = true
        serverError = nil
        Task {
            defer { probing = false }
            let client = DianeClient(origin: url, token: { nil })
            do {
                let output = try await client.api.listIdentities()
                guard case .ok(let ok) = output else {
                    serverError = "That server answered, but not like a Diane server."
                    return
                }
                let response = try ok.body.json
                guard response.configured else {
                    serverError =
                        "This Diane server isn't set up yet — finish the setup on the family kiosk first."
                    return
                }
                origin = url
                identities = response
                path.append(.members)
            } catch {
                serverError =
                    "Couldn't reach \(url.host() ?? "the server"). Check the address — and that you're on your home network or the server is reachable from here."
            }
        }
    }
}

private struct PasswordStepView: View {
    let origin: URL
    let member: Components.Schemas.MemberIdentity
    let onSignedIn: (String, Components.Schemas.SessionMember) -> Void

    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            MemberAvatarView(
                name: member.name,
                colorHex: member.color,
                avatar: member.avatar,
                size: 88
            )
            .padding(.top, 32)
            Text("Hi, \(member.name)!")
                .font(.title2.bold())

            if member.passwordResetRequired == true {
                infoBox(
                    "Your password was reset. Set a new one on the family kiosk, then sign in here."
                )
            } else if member.hasPassword == false {
                infoBox(
                    "You don't have a password yet. A parent can set one up on the family kiosk."
                )
            } else {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { signIn() }
                    .onAppear { focused = true }

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button(action: signIn) {
                    if busy {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Sign in").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || password.isEmpty)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoBox(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func signIn() {
        guard !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            let client = DianeClient(origin: origin, token: { nil })
            do {
                let output = try await client.api.login(
                    body: .json(.init(scope: .member, memberId: member.id, password: password))
                )
                switch output {
                case .ok(let ok):
                    let response = try ok.body.json
                    guard let sessionMember = response.session.member else {
                        error = "The server answered with a non-member session — try again."
                        return
                    }
                    onSignedIn(response.token, sessionMember)
                case .unauthorized:
                    error = "That password isn't right."
                case .tooManyRequests:
                    error = "Too many tries — wait a minute, then try again."
                default:
                    error = "Sign-in failed. Try again in a moment."
                }
            } catch {
                self.error = "Couldn't reach the server. Check your connection and try again."
            }
        }
    }
}
