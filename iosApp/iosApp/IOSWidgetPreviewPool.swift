import SwiftUI
@preconcurrency import WebKit

@MainActor
protocol IOSWidgetPreviewClient: AnyObject {
    var isActive: Bool { get }
    var isVisible: Bool { get }
    var canSnapshot: Bool { get }
    func mount()
    func captureSnapshot(_ completion: @escaping @MainActor (UIImage?) -> Void)
    func suspend(with image: UIImage)
}

@MainActor
final class IOSWidgetPreviewPool {
    static let shared = IOSWidgetPreviewPool()
    static let maxLiveWebViews = 4

    // Oldest interaction first. A snapshot in flight still occupies its slot.
    private var residents: [any IOSWidgetPreviewClient] = []
    private var waiting: [any IOSWidgetPreviewClient] = []
    private var pressureTargets: Set<ObjectIdentifier> = []
    private var failedSnapshots: Set<ObjectIdentifier> = []
    private var capturing: (any IOSWidgetPreviewClient)?

    func request(_ client: any IOSWidgetPreviewClient) {
        let id = ObjectIdentifier(client)
        pressureTargets.remove(id)
        failedSnapshots.removeAll()
        if let index = residents.firstIndex(where: { $0 === client }) {
            residents.append(residents.remove(at: index))
        } else if !waiting.contains(where: { $0 === client }) {
            waiting.append(client)
        }
        reconcile()
    }

    func remove(_ client: any IOSWidgetPreviewClient) {
        residents.removeAll { $0 === client }
        waiting.removeAll { $0 === client }
        pressureTargets.remove(ObjectIdentifier(client))
        failedSnapshots.remove(ObjectIdentifier(client))
        if capturing === client { capturing = nil }
        reconcile()
    }

    func handleMemoryWarning() {
        failedSnapshots.removeAll()
        pressureTargets = Set(residents.filter { !$0.isActive }.map(ObjectIdentifier.init))
        // Retain demand for views that the user can currently see.
        waiting.removeAll { !$0.isActive && !$0.isVisible }
        reconcile()
    }

    func didRender(_ client: any IOSWidgetPreviewClient) {
        failedSnapshots.remove(ObjectIdentifier(client))
        reconcile()
    }

    func reconcile() {
        while residents.count < Self.maxLiveWebViews, let next = nextRequest {
            waiting.removeAll { $0 === next }
            residents.append(next)
            next.mount()
        }
        guard capturing == nil, let victim = nextVictim else { return }
        capturing = victim
        victim.captureSnapshot { [weak self, weak victim] image in
            guard let self, let victim, capturing === victim else { return }
            capturing = nil
            // A tap, focus change or dismissal can change priority during takeSnapshot.
            if nextVictim === victim {
                let id = ObjectIdentifier(victim)
                if let image {
                    victim.suspend(with: image)
                    residents.removeAll { $0 === victim }
                    pressureTargets.remove(id)
                } else {
                    failedSnapshots.insert(id)
                }
            }
            reconcile()
        }
    }

    private var nextRequest: (any IOSWidgetPreviewClient)? {
        waiting.first(where: \.isActive) ?? waiting.first(where: \.isVisible) ?? waiting.first
    }

    private var nextVictim: (any IOSWidgetPreviewClient)? {
        guard !pressureTargets.isEmpty || !waiting.isEmpty else { return nil }
        let candidates = residents.filter {
            !$0.isActive && $0.canSnapshot && !failedSnapshots.contains(ObjectIdentifier($0))
        }
        if let pressure = candidates.first(where: { pressureTargets.contains(ObjectIdentifier($0)) }) {
            return pressure
        }
        guard let nextRequest else { return nil }
        // Background measurement must never displace the visible preview it just loaded.
        if nextRequest.isActive || nextRequest.isVisible { return candidates.first }
        return candidates.first { !$0.isVisible }
    }
}

enum IOSWidgetWebPresentation: Equatable {
    case inline(visible: Bool, streaming: Bool)
    case expanded
    case unmanaged
}

/// A fresh coordinator belongs to each WebView. The timeline card keeps its own
/// measured height across those lifetimes.
@MainActor
protocol IOSWidgetWebContent: View {
    associatedtype Coordinator: AnyObject
    var presentation: IOSWidgetWebPresentation { get }
    var snapshotHTML: String? { get }
    var snapshotHeight: CGFloat? { get }
    func makeCoordinator(onRender: @escaping () -> Void) -> Coordinator
    func makeWebView(coordinator: Coordinator) -> WKWebView
    func updateWebView(_ webView: WKWebView, coordinator: Coordinator)
    static func dismantleWebView(_ webView: WKWebView, coordinator: Coordinator)
    func openPreview()
    func isRevealing(_ coordinator: Coordinator) -> Bool
}

extension IOSWidgetWebContent {
    var presentation: IOSWidgetWebPresentation { .expanded }
    var snapshotHTML: String? { nil }
    var snapshotHeight: CGFloat? { nil }
    func openPreview() {}
    func isRevealing(_ coordinator: Coordinator) -> Bool { false }
    var body: some View { IOSWidgetWebSurface(content: self) }
}

private struct IOSWidgetWebSurface<Content: IOSWidgetWebContent>: UIViewRepresentable {
    let content: Content

    func makeUIView(context: Context) -> IOSWidgetWebHost<Content> {
        IOSWidgetWebHost(content: content)
    }

    func updateUIView(_ host: IOSWidgetWebHost<Content>, context: Context) {
        host.update(content)
    }

    static func dismantleUIView(_ host: IOSWidgetWebHost<Content>, coordinator: ()) {
        host.close()
    }
}

@MainActor
private final class IOSWidgetWebHost<Content: IOSWidgetWebContent>: UIView, IOSWidgetPreviewClient {
    private var content: Content
    private var webView: WKWebView?
    private var coordinator: Content.Coordinator?
    private var rendered = false
    private let placeholder = IOSWidgetPlaceholderButton()
    private let loading = UIActivityIndicatorView(style: .medium)
    private var requested = false
    private var touching = false
    private var pooled: Bool { content.presentation != .unmanaged }

    init(content: Content) {
        self.content = content
        super.init(frame: .zero)
        if case .inline = content.presentation {
            let touches = IOSWidgetTouchObserver()
            touches.cancelsTouchesInView = false
            touches.delaysTouchesEnded = false
            touches.onTouch = { [weak self] down in
                guard let self, touching != down else { return }
                touching = down
                if down, webView != nil { request() } else { IOSWidgetPreviewPool.shared.reconcile() }
            }
            addGestureRecognizer(touches)
        }
        placeholder.imageView?.contentMode = .scaleToFill
        placeholder.contentHorizontalAlignment = .fill
        placeholder.contentVerticalAlignment = .fill
        placeholder.accessibilityLabel = IOSAppLocalization.string("可视化卡片", defaultValue: "可视化卡片")
        placeholder.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            request()
            content.openPreview()
        }, for: .primaryActionTriggered)
        placeholder.onFocus = { [weak self] in self?.request() }
        addSubview(placeholder)
        loading.isUserInteractionEnabled = false
        loading.startAnimating()
        addSubview(loading)
    }

    required init?(coder: NSCoder) { nil }

    var isActive: Bool {
        switch content.presentation {
        case .expanded, .unmanaged: true
        case .inline(_, let streaming):
            streaming || touching || (coordinator.map(content.isRevealing) ?? false) || placeholder.accessibilityElementIsFocused()
        }
    }

    var isVisible: Bool {
        if case .inline(let visible, _) = content.presentation { return visible }
        return true
    }

    var canSnapshot: Bool {
        guard rendered, let webView, !webView.bounds.isEmpty else { return false }
        return content.snapshotHeight.map { abs($0 - webView.bounds.height) < 1.5 } ?? true
    }

    func update(_ newContent: Content) {
        let oldPresentation = content.presentation
        let oldHTML = content.snapshotHTML
        content = newContent
        if let webView, let coordinator {
            if oldHTML != content.snapshotHTML { rendered = false }
            content.updateWebView(webView, coordinator: coordinator)
        }
        let becameVisibleOrActive = oldPresentation != content.presentation && (isVisible || isActive)
        if !requested || becameVisibleOrActive || (oldHTML != content.snapshotHTML && isVisible) {
            request()
        } else if pooled, oldPresentation != content.presentation {
            IOSWidgetPreviewPool.shared.reconcile()
        }
    }

    private func request() {
        requested = true
        if pooled {
            IOSWidgetPreviewPool.shared.request(self)
        } else if webView == nil {
            mount()
        }
    }

    func mount() {
        let coordinator = content.makeCoordinator { [weak self] in
            guard let self else { return }
            if !rendered {
                rendered = true
                placeholder.setImage(nil, for: .normal)
                placeholder.isHidden = true
                loading.stopAnimating()
                if pooled { IOSWidgetPreviewPool.shared.didRender(self) }
            } else if pooled {
                IOSWidgetPreviewPool.shared.reconcile()
            }
        }
        let webView = content.makeWebView(coordinator: coordinator)
        self.coordinator = coordinator
        self.webView = webView
        webView.frame = bounds
        insertSubview(webView, at: 0)
        // A retained snapshot covers the new receiver until it reports real content.
        placeholder.isHidden = placeholder.currentImage == nil
        placeholder.isUserInteractionEnabled = !placeholder.isHidden
        if content.snapshotHTML == nil { loading.stopAnimating() }
        content.updateWebView(webView, coordinator: coordinator)
    }

    func captureSnapshot(_ completion: @escaping @MainActor (UIImage?) -> Void) {
        guard let webView else { completion(nil); return }
        let html = content.snapshotHTML
        webView.takeSnapshot(with: nil) { [weak self, weak webView] image, _ in
            guard let self, let webView, self.webView === webView,
                  content.snapshotHTML == html else { completion(nil); return }
            completion(image)
        }
    }

    func suspend(with image: UIImage) {
        placeholder.setImage(image.withRenderingMode(.alwaysOriginal), for: .normal)
        placeholder.isHidden = false
        placeholder.isUserInteractionEnabled = true
        unmount()
    }

    private func unmount() {
        if let webView, let coordinator {
            Content.dismantleWebView(webView, coordinator: coordinator)
            webView.removeFromSuperview()
        }
        webView = nil
        coordinator = nil
        rendered = false
    }

    func close() {
        unmount()
        if pooled { IOSWidgetPreviewPool.shared.remove(self) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView?.frame = bounds
        placeholder.frame = bounds
        loading.center = CGPoint(x: bounds.midX, y: bounds.midY)
        if pooled && rendered { IOSWidgetPreviewPool.shared.reconcile() }
    }
}

private final class IOSWidgetPlaceholderButton: UIButton {
    var onFocus: (() -> Void)?

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        onFocus?()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === self { onFocus?() }
    }
}

/// Observe the duration of a real touch without recognizing a competing gesture.
/// WebKit links, the card tap, and the enclosing timeline pan keep their normal delivery.
private final class IOSWidgetTouchObserver: UIGestureRecognizer {
    var onTouch: ((Bool) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { onTouch?(true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

    override func reset() {
        super.reset()
        onTouch?(false)
    }
}
