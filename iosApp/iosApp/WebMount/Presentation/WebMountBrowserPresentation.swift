import Foundation
import SwiftUI
import WebKit

@MainActor
struct WebMountRuntimeWebView: UIViewRepresentable {
    let webView: WKWebView?
    let isInteractive: Bool

    init(runtime: IOSWebMountWKRuntime, isInteractive: Bool) {
        webView = runtime.webView
        self.isInteractive = isInteractive
    }

    init(webView: WKWebView, isInteractive: Bool) {
        self.webView = webView
        self.isInteractive = isInteractive
    }

    func makeUIView(context: Context) -> WKWebView {
        let mountedWebView = webView ?? WKWebView()
        mountedWebView.isUserInteractionEnabled = isInteractive
        return mountedWebView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.isUserInteractionEnabled = isInteractive
    }
}

@MainActor
private struct WebMountBrowserPresentationHost: ViewModifier {
    let runtime: IOSWebMountWKRuntime
    let hostID: UUID
    @State private var isVisible = false
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                updateAvailability()
            }
            .onDisappear {
                isVisible = false
                runtime.setBrowserPresentationAvailable(false, hostID: hostID)
            }
            .onChange(of: scenePhase) { _, _ in
                updateAvailability()
            }
    }

    private func updateAvailability() {
        runtime.setBrowserPresentationAvailable(isVisible && scenePhase == .active, hostID: hostID)
    }
}

extension View {
    func browserPresentationHost(runtime: IOSWebMountWKRuntime, hostID: UUID) -> some View {
        modifier(WebMountBrowserPresentationHost(runtime: runtime, hostID: hostID))
    }
}

@MainActor
struct WebMountBrowserDialogOverlay: View {
    let dialog: IOSWebMountBrowserDialog
    let onResolve: (String?) -> Void

    @State private var promptText: String
    @FocusState private var promptIsFocused: Bool

    init(dialog: IOSWebMountBrowserDialog, onResolve: @escaping (String?) -> Void) {
        self.dialog = dialog
        self.onResolve = onResolve
        _promptText = State(initialValue: dialog.defaultText)
    }

    var body: some View {
        GeometryReader { geometry in
            let cardMaxHeight = max(1, geometry.size.height - 24)

            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()

                ViewThatFits(in: .vertical) {
                    regularDialogCard(availableHeight: cardMaxHeight)
                    fallbackDialogCard(maxHeight: cardMaxHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: cardMaxHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityAddTraits(.isModal)
        .onAppear {
            if isPrompt {
                promptIsFocused = true
            }
        }
    }

    private func regularDialogCard(availableHeight: CGFloat) -> some View {
        dialogCard(
            messageMaxHeight: min(220, max(44, availableHeight - (isPrompt ? 240 : 180)))
        )
        .padding(.horizontal, 20)
    }

    private func fallbackDialogCard(maxHeight: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            dialogCard(messageMaxHeight: 44)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func dialogCard(messageMaxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: dialogIcon)
                    .foregroundStyle(AmberTheme.accentAmber)
                Text("网页提示")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
            }

            Text(dialog.host)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(1)
                .truncationMode(.middle)

            ScrollView(.vertical, showsIndicators: false) {
                Text(dialog.message)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: messageMaxHeight, alignment: .topLeading)
            .scrollBounceBehavior(.basedOnSize)

            if isPrompt {
                TextField("输入内容", text: $promptText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($promptIsFocused)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("webmount.dialog.input")
            }

            HStack(spacing: 10) {
                if !isAlert {
                    Button(role: .cancel, action: {
                        resolve(nil)
                    }) {
                        Text("取消")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("webmount.dialog.cancel")
                }

                Button(action: {
                    resolve(isPrompt ? promptText : "")
                }) {
                    Text(isAlert ? "好" : "确定")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("webmount.dialog.confirm")
            }
        }
        .padding(20)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.20), radius: 22, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("webmount.dialog.card")
    }

    private var isAlert: Bool {
        switch dialog.kind {
        case .alert: true
        case .confirm, .prompt: false
        }
    }

    private var isPrompt: Bool {
        switch dialog.kind {
        case .alert, .confirm: false
        case .prompt: true
        }
    }

    private var dialogIcon: String {
        switch dialog.kind {
        case .alert: "exclamationmark.circle"
        case .confirm: "questionmark.circle"
        case .prompt: "character.cursor.ibeam"
        }
    }

    private func resolve(_ response: String?) {
        promptIsFocused = false
        onResolve(response)
    }
}
