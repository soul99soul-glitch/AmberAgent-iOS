import SafariServices
import Shared
import SwiftUI

private struct ChatGptSiwcSafariItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

private struct ChatGptSiwcSafariView: UIViewControllerRepresentable {
    let url: URL
    let onUserDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserDismiss: onUserDismiss)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = false
        let controller = SFSafariViewController(url: url, configuration: config)
        controller.dismissButtonStyle = .cancel
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        private let onUserDismiss: () -> Void

        init(onUserDismiss: @escaping () -> Void) {
            self.onUserDismiss = onUserDismiss
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onUserDismiss()
        }
    }
}

/// Drives the official Sign in with ChatGPT (SIWC) loopback OAuth + SFSafariViewController flow.
@MainActor
final class ChatGptSiwcLoginModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case authorizing
        case exchanging
        case signedIn(email: String?, name: String?)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published fileprivate var safariItem: ChatGptSiwcSafariItem?
    @Published var showFirstSignInConfirmation = false
    @Published private(set) var isRefreshingModels = false
    @Published private(set) var modelRefreshMessage: String?
    @Published private(set) var modelRefreshIsError = false

    let providerId: String
    private let client: IOSChatGptSiwcOAuthClient
    private let onModelsFetched: ([IOSChatGptSiwcModelItem]) -> Void
    private var loginTask: Task<Void, Never>?
    private var modelRefreshTask: Task<Void, Never>?
    private var activeServer: IOSChatGptSiwcLoopbackServer?
    private var modelRequestGeneration = 0

    init(
        providerId: String,
        onModelsFetched: @escaping ([IOSChatGptSiwcModelItem]) -> Void
    ) {
        self.providerId = providerId
        self.onModelsFetched = onModelsFetched
        self.client = IOSChatGptSiwcOAuthClient(providerId: providerId)
        restorePersistedPhase()
    }

    var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    var isAuthorizing: Bool {
        switch phase {
        case .preparing, .authorizing, .exchanging:
            return true
        case .idle, .signedIn, .failed:
            return false
        }
    }

    func startLogin(onSignedIn: @escaping () -> Void) {
        cancelLogin()
        phase = .preparing

        loginTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let server = IOSChatGptSiwcLoopbackServer()
            self.activeServer = server
            defer {
                server.stop()
                if self.activeServer === server {
                    self.activeServer = nil
                }
            }
            do {
                let redirectUri = try await server.start()
                let registration = IOSChatGptSiwcAuthStore.loadRegistration(providerId: self.providerId)
                let authRequest = try IOSChatGptSiwcOAuthClient.buildAuthorizationRequest(
                    redirectUri: redirectUri,
                    registration: registration,
                    state: server.state
                )
                try Task.checkCancellation()

                self.phase = .authorizing
                self.safariItem = ChatGptSiwcSafariItem(url: authRequest.authorizeURL)

                let callbackURL = try await server.waitForCallback()
                try Task.checkCancellation()
                self.phase = .exchanging
                self.safariItem = nil
                let callbackResult = try IOSChatGptSiwcOAuthClient.parseAndValidateCallback(
                    url: callbackURL,
                    expectedState: authRequest.state,
                    requestedClientId: authRequest.clientId,
                    isDynamicRegistration: authRequest.isDynamicRegistration
                )
                let credentials = try await self.client.exchangeAuthorizationCode(
                    request: authRequest,
                    callback: callbackResult
                )
                try Task.checkCancellation()

                self.phase = .signedIn(email: credentials.email, name: credentials.name)
                if !IOSChatGptSiwcAuthStore.hasShownFirstSignInConfirmation(providerId: self.providerId) {
                    IOSChatGptSiwcAuthStore.markFirstSignInConfirmationShown(providerId: self.providerId)
                    self.showFirstSignInConfirmation = true
                }
                onSignedIn()
                await self.applyModels(generation: self.modelRequestGeneration)
            } catch {
                // cancelLogin already restored the UI. A newer attempt may own it now.
                guard !Task.isCancelled else { return }
                self.safariItem = nil
                self.restorePersistedPhase()
                if self.isSignedIn {
                    self.modelRefreshIsError = true
                    self.modelRefreshMessage = "重新登录失败：\(error.localizedDescription)"
                } else {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func handleSafariUserDismiss() {
        guard phase == .authorizing else { return }
        cancelLogin()
    }

    func cancelLogin() {
        activeServer?.stop()
        activeServer = nil
        loginTask?.cancel()
        loginTask = nil
        safariItem = nil
        invalidateModelRequests()
        restorePersistedPhase()
    }

    func refreshModels() {
        invalidateModelRequests()
        let generation = modelRequestGeneration
        modelRefreshTask = Task { await applyModels(generation: generation) }
    }

    func logout(onLoggedOut: @escaping () -> Void) {
        cancelLogin()
        let generation = modelRequestGeneration
        Task {
            do {
                try await client.logout {
                    phase = .idle
                    modelRefreshIsError = false
                    modelRefreshMessage = nil
                    onLoggedOut()
                }
            } catch {
                guard generation == modelRequestGeneration else { return }
                if isSignedIn {
                    modelRefreshIsError = true
                    modelRefreshMessage = error.localizedDescription
                }
                else { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func applyModels(generation: Int) async {
        guard generation == modelRequestGeneration, !isRefreshingModels else { return }
        isRefreshingModels = true
        modelRefreshIsError = false
        modelRefreshMessage = nil
        defer {
            if generation == modelRequestGeneration {
                isRefreshingModels = false
                modelRefreshTask = nil
            }
        }
        do {
            let models = try await client.fetchModelsOrThrow()
            guard generation == modelRequestGeneration, !Task.isCancelled, isSignedIn else { return }
            onModelsFetched(models)
            modelRefreshIsError = false
            modelRefreshMessage = models.isEmpty
                ? "已连接 ChatGPT 套餐，当前账号未返回可列出的模型。"
                : "已刷新 \(models.count) 个 ChatGPT 官方模型。"
        } catch {
            guard generation == modelRequestGeneration, !Task.isCancelled else { return }
            if IOSChatGptSiwcAuthStore.load(providerId: providerId) == nil {
                phase = .failed(error.localizedDescription)
            } else {
                modelRefreshIsError = true
                modelRefreshMessage = "模型刷新失败：\(error.localizedDescription)"
            }
        }
    }

    private func invalidateModelRequests() {
        modelRequestGeneration += 1
        modelRefreshTask?.cancel()
        modelRefreshTask = nil
        isRefreshingModels = false
    }

    private func restorePersistedPhase() {
        if let credentials = IOSChatGptSiwcAuthStore.load(providerId: providerId) {
            phase = .signedIn(email: credentials.email, name: credentials.name)
        } else {
            phase = .idle
        }
    }
}

/// Official Sign in with ChatGPT sheet shown from ProviderDetailView.
struct ChatGptSiwcLoginView: View {
    let providerId: String
    let autoStartLogin: Bool
    let onAuthModeChange: (OpenAIAuthMode) -> Void

    @StateObject private var model: ChatGptSiwcLoginModel
    @State private var didAutoStart = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var siwcStatusGreen: Color {
        colorScheme == .dark ? Color(hex: 0x4EC38E) : AmberTheme.accentGreen
    }

    init(
        providerId: String,
        autoStartLogin: Bool = false,
        onAuthModeChange: @escaping (OpenAIAuthMode) -> Void,
        onModelsFetched: @escaping ([IOSChatGptSiwcModelItem]) -> Void
    ) {
        self.providerId = providerId
        self.autoStartLogin = autoStartLogin
        self.onAuthModeChange = onAuthModeChange
        _model = StateObject(
            wrappedValue: ChatGptSiwcLoginModel(providerId: providerId, onModelsFetched: onModelsFetched)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    content
                }
                .padding(20)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .navigationTitle("ChatGPT 登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                if autoStartLogin, !didAutoStart, !model.isSignedIn, !model.isAuthorizing {
                    didAutoStart = true
                    model.startLogin {
                        onAuthModeChange(OpenAIAuthMode.chatgptSiwc)
                    }
                }
            }
            .onDisappear {
                if model.isAuthorizing {
                    model.cancelLogin()
                }
            }
            .sheet(item: $model.safariItem, onDismiss: {
                if model.safariItem == nil { model.handleSafariUserDismiss() }
            }) { item in
                ChatGptSiwcSafariView(url: item.url) {
                    if model.safariItem?.id == item.id { model.handleSafariUserDismiss() }
                }
                .ignoresSafeArea()
            }
            .alert("You're using your ChatGPT plan", isPresented: $model.showFirstSignInConfirmation) {
                Button("Manage usage") {
                    if let url = URL(string: IOSChatGptSiwcConstants.usageSettingsUrl) {
                        openURL(url)
                    }
                }
                Button("知道了", role: .cancel) {}
            } message: {
                Text("Amber 将通过官方 Sign in with ChatGPT 使用你的 ChatGPT 套餐额度调用公开 Responses API。你可随时在 chatgpt.com/settings/usage 查看或管理用量。")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(AmberTheme.accent)
            Text("ChatGPT 套餐登录（官方 SIWC）")
                .font(.headline)
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("使用 OpenAI 官方 Sign in with ChatGPT 授权你的 ChatGPT 套餐，通过公开 Responses API 推理，无需手动填写 API Key。")
                .font(.footnote)
                .foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch model.phase {
            case .idle:
                VStack(spacing: 14) {
                    continueWithChatGPTButton {
                        model.startLogin { onAuthModeChange(OpenAIAuthMode.chatgptSiwc) }
                    }
                    Text("授权将在应用内安全浏览器中完成，成功后自动返回并刷新可用模型。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .preparing:
                progressCard(text: "正在准备安全回环通道…")

            case .authorizing:
                progressCard(text: "请在弹出的 ChatGPT 页面完成授权…")

            case .exchanging:
                progressCard(text: "正在验证授权签名并保存凭据…")

            case let .signedIn(email, name):
                signedInView(email: email, name: name)

            case let .failed(message):
                VStack(spacing: 14) {
                    errorBanner(message: message)
                    continueWithChatGPTButton {
                        model.startLogin { onAuthModeChange(OpenAIAuthMode.chatgptSiwc) }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    private func errorBanner(message: String) -> some View {
        let radius = AmberTheme.radiusLarge
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AmberTheme.accentRed)
                .padding(.top, 1)
            Text(message)
                .font(.footnote)
                .foregroundStyle(AmberTheme.accentRed)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            AmberTheme.accentRed.opacity(0.08),
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(AmberTheme.accentRed.opacity(0.22), lineWidth: 0.5)
        }
    }

    private func progressCard(text: String) -> some View {
        let cardRadius = AmberTheme.radiusXLarge
        return VStack(spacing: 14) {
            ProgressView()
            Text(text)
                .font(.footnote)
                .foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("取消") { model.cancelLogin() }
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.muted)
                .padding(.horizontal, 16)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .padding(.horizontal, 16)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
    }

    private func signedInView(email: String?, name: String?) -> some View {
        let cardRadius = AmberTheme.radiusXLarge
        let buttonRadius = AmberTheme.controlRadius(14)
        return VStack(spacing: 16) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.footnote.weight(.semibold))
                    Text("Using ChatGPT plan")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(siwcStatusGreen)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    siwcStatusGreen.opacity(colorScheme == .dark ? 0.16 : 0.12),
                    in: Capsule()
                )

                if let email, !email.isEmpty {
                    Text(email)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let name, !name.isEmpty {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("端点：https://api.openai.com/v1/responses")
                    .font(.caption.monospaced())
                    .foregroundStyle(AmberTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
            }

            if let message = model.modelRefreshMessage {
                if model.modelRefreshIsError {
                    errorBanner(message: message)
                } else {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                }
            }

            VStack(spacing: 10) {
                Button {
                    model.refreshModels()
                } label: {
                    HStack(spacing: 8) {
                        if model.isRefreshingModels {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text(model.isRefreshingModels ? "正在刷新模型…" : "刷新模型")
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(AmberTheme.foreground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .background(
                        AmberTheme.surface2.opacity(0.9),
                        in: RoundedRectangle(cornerRadius: buttonRadius, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: buttonRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .opacity(model.isRefreshingModels ? 0.65 : 1)
                .disabled(model.isRefreshingModels)

                Button {
                    if let url = URL(string: IOSChatGptSiwcConstants.usageSettingsUrl) {
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Manage usage")
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .background(
                        AmberTheme.accent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: buttonRadius, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: buttonRadius, style: .continuous))
                }
                .buttonStyle(.plain)

                continueWithChatGPTButton(prominent: false) {
                    model.startLogin { onAuthModeChange(OpenAIAuthMode.chatgptSiwc) }
                }

                Button(role: .destructive) {
                    model.logout { onAuthModeChange(OpenAIAuthMode.apiKey) }
                } label: {
                    Text("退出登录")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentRed)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                        .background(
                            AmberTheme.accentRed.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: buttonRadius, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: buttonRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.modelRefreshMessage)
        .animation(.easeInOut(duration: 0.18), value: model.isRefreshingModels)
    }

    private func continueWithChatGPTButton(
        prominent: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let radius = AmberTheme.controlRadius(14)
        return Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Text("Continue with ChatGPT")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(prominent ? AmberTheme.background : AmberTheme.foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(
                prominent ? AmberTheme.foreground : AmberTheme.surface,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(AmberTheme.border, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
