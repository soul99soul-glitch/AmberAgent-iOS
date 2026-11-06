import SwiftUI
import UIKit

@MainActor
final class NativeTimelineScrollDriver: NSObject {
    var onFallback: ((NativeTimelineScrollFallbackReason, Bool) -> Void)?

    private weak var scrollView: UIScrollView?
    private var state: NativeTimelineScrollState = .idle
    private var displayLink: CADisplayLink?
    private var lastDisplayLinkTimestamp: CFTimeInterval?
    private var generation: UInt64 = 0
    private var lastViewportMetrics: ViewportMetrics?
    private var wasNearBottomAtLastSample = false
    private var programmaticBottomAnimationCount = 0
    private var isObservingKeyboardWillChange = false
    private var activeKeyboardAnimation: ActiveKeyboardAnimation?
    private var automaticFollowEnabled = true
    private var fallbackReason: NativeTimelineScrollFallbackReason?
    private var horizontalOffsetDriftClampUsed = false

    private struct ActiveKeyboardAnimation {
        let duration: TimeInterval
        let options: UIView.AnimationOptions
        let expiresAt: CFTimeInterval
        let shouldFollowBottom: Bool
    }

    @discardableResult
    func attach(_ scrollView: UIScrollView) -> Bool {
        guard fallbackReason == nil else { return false }
        guard self.scrollView !== scrollView else { return false }
        if self.scrollView != nil {
            generation &+= 1
            cancelProgrammaticMotion()
            stopFrameDriver()
            state = .idle
        }
        self.scrollView = scrollView
        lastViewportMetrics = ViewportMetrics(scrollView)
        wasNearBottomAtLastSample = distanceToBottom(in: scrollView) <= NativeTimelineScrollCore.resumeEpsilon
        horizontalOffsetDriftClampUsed = false
        scrollView.keyboardDismissMode = .interactive
        installKeyboardObserverIfNeeded()
        _ = validateScrollViewHealth()
        return isAttached
    }

    func invalidate() {
        generation &+= 1
        stopFrameDriver()
        state = .idle
        scrollView = nil
        lastViewportMetrics = nil
        wasNearBottomAtLastSample = false
        programmaticBottomAnimationCount = 0
        activeKeyboardAnimation = nil
        if isObservingKeyboardWillChange {
            NotificationCenter.default.removeObserver(
                self,
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
            isObservingKeyboardWillChange = false
        }
        fallbackReason = nil
        horizontalOffsetDriftClampUsed = false
    }

    func setAutomaticFollowEnabled(_ enabled: Bool) {
        guard automaticFollowEnabled != enabled else { return }
        automaticFollowEnabled = enabled
        generation &+= 1
        stopFrameDriver()
        state = .idle
        if !enabled {
            cancelProgrammaticMotion()
        }
    }

    func submit(_ intent: NativeTimelineScrollIntent, now: TimeInterval = CACurrentMediaTime()) {
        guard fallbackReason == nil else { return }
        if !automaticFollowEnabled {
            switch intent {
            case .streamContentGrew, .userDragEnded(isAtBottom: true):
                return
            default:
                break
            }
        }
        generation &+= 1
        let token = generation
        if case .userDragBegan = intent {
            cancelProgrammaticMotion()
        }
        reduceAndPerform(normalizedIntent(intent, token: token), token: token, now: now)
    }

    func handleLayoutMetricsChanged() {
        guard fallbackReason == nil else { return }
        guard let scrollView else { return }
        guard validateScrollViewHealth() else { return }
        guard automaticFollowEnabled else { return }
        let viewportMetrics = ViewportMetrics(scrollView)
        if viewportMetrics != lastViewportMetrics {
            let previousMetrics = lastViewportMetrics
            lastViewportMetrics = viewportMetrics
            let shrinkDelta = max(
                0,
                (previousMetrics?.visibleHeight ?? viewportMetrics.visibleHeight) - viewportMetrics.visibleHeight
            )
            let distanceBeforeShrink = max(0, distanceToBottom(in: scrollView) - shrinkDelta)
            let keyboardAnimation = currentKeyboardAnimation()
            let shouldFollowViewportChange = !isPausedForUser &&
                !isUIKitUserInteracting &&
                (keyboardAnimation?.shouldFollowBottom ?? (
                    isFollowingBottomOrKeyboardFocus ||
                    wasNearBottomAtLastSample ||
                    distanceBeforeShrink <= NativeTimelineScrollCore.resumeEpsilon
                ))
            if shouldFollowViewportChange, keyboardAnimation != nil {
                writeBottomTargetSynchronizedWithKeyboardIfNeeded(animated: false)
            }
            submitViewportChanged(wasNearBottomBeforeChange: shouldFollowViewportChange)
            return
        }
        reduceAndPerform(.layoutSettled(token: nil), token: generation)
    }

    private func submitViewportChanged(
        wasNearBottomBeforeChange: Bool,
        now: TimeInterval = CACurrentMediaTime()
    ) {
        guard fallbackReason == nil else { return }
        generation &+= 1
        let token = generation
        reduceAndPerform(
            .viewportChanged,
            token: token,
            wasNearBottomBeforeViewportChange: wasNearBottomBeforeChange,
            now: now
        )
    }

    func isAtBottomNow() -> Bool {
        guard let distance = distanceToBottomNow() else { return false }
        return distance <= NativeTimelineScrollCore.resumeEpsilon
    }

    /// 拖拽释放（进入惯性）瞬间的磁吸回底：预测落点命中底部容差时，用既有
    /// explicitBottom 动画接管惯性（allowUserInteraction + beginFromCurrentState
    /// 的 0.18s easeOut，Messages 同款手感）。只在用户拖拽后的暂停态生效。
    func attemptMagneticBottomSnapAfterDragRelease() {
        guard fallbackReason == nil, automaticFollowEnabled else { return }
        guard let scrollView else { return }
        guard isPausedForUser else { return }
        let velocityY = scrollView.panGestureRecognizer.velocity(in: nil).y
        guard NativeTimelineMagneticBottomPolicy.shouldSnap(
            releaseVelocityY: velocityY,
            distanceToBottom: distanceToBottom(in: scrollView)
        ) else { return }
        submit(.explicitBottom(source: .streamGrowth, animated: true, keyboardToken: nil))
    }

    func distanceToBottomNow() -> CGFloat? {
        guard let scrollView else { return nil }
        return distanceToBottom(in: scrollView)
    }

    var isAttached: Bool {
        scrollView != nil && fallbackReason == nil
    }

    var isFollowingBottomOrKeyboardFocus: Bool {
        switch state {
        case .followingBottom, .settlingAfterTerminal, .keyboardFocus:
            return true
        case .idle, .pausedForUser:
            return false
        }
    }

    var isPausedForUser: Bool {
        if case .pausedForUser = state {
            return true
        }
        return false
    }

    var isUIKitUserInteracting: Bool {
        guard let scrollView else { return false }
        return scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }

    private func reduceAndPerform(
        _ intent: NativeTimelineScrollIntent,
        token: UInt64,
        wasNearBottomBeforeViewportChange: Bool = false,
        now: TimeInterval = CACurrentMediaTime()
    ) {
        guard validateScrollViewHealth() else { return }
        let result = NativeTimelineScrollCore.reduce(
            state: state,
            intent: intent,
            geometry: sampleGeometry(
                wasNearBottomBeforeViewportChange: wasNearBottomBeforeViewportChange
            ),
            now: now
        )
        state = result.state
        perform(result.actions, token: token)
    }

    private func perform(_ actions: [NativeTimelineScrollAction], token: UInt64) {
        guard fallbackReason == nil else { return }
        for action in actions {
            switch action {
            case let .requestBottomAnchor(animated, _):
                requestBottomAnchor(animated: animated, token: token)
            case let .writeOffsetY(offsetY):
                writeOffsetY(offsetY)
            case .startFrameDriver:
                startFrameDriver()
            case .stopFrameDriver:
                stopFrameDriver()
            case .markKeyboardFocusComplete:
                break
            }
        }
    }

    private func requestBottomAnchor(animated: Bool, token: UInt64) {
        guard let scrollView else { return }
        if currentKeyboardAnimation() == nil {
            scrollView.layoutIfNeeded()
        }
        writeBottomTargetSynchronizedWithKeyboardIfNeeded(animated: animated)
        scheduleBottomConvergence(
            generationToken: token,
            layoutToken: bottomConvergenceLayoutToken(defaultToken: token),
            remainingPasses: 6
        )
    }

    private func scheduleBottomConvergence(generationToken: UInt64, layoutToken: UInt64, remainingPasses: Int) {
        guard remainingPasses > 0 else {
            // 耗尽不交出所有权（契约见 testBottomConvergenceExhaustionKeepsNativeDriverAsOwner），
            // 但未到底时必须留下可观测痕迹，否则"停在略高于底部"在生产不可排查。
            if let scrollView, distanceToBottom(in: scrollView) > NativeTimelineScrollCore.bottomEpsilon {
                NativeTimelineScrollDiagnostics.logBottomConvergenceExhausted(geometry: sampleGeometry())
            }
            return
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.fallbackReason == nil,
                  self.generation == generationToken,
                  let scrollView = self.scrollView else { return }
            if self.currentKeyboardAnimation() == nil {
                scrollView.layoutIfNeeded()
            }
            self.reduceAndPerform(.layoutSettled(token: layoutToken), token: generationToken)
            guard self.canContinueBottomConvergence(
                generationToken: generationToken,
                layoutToken: layoutToken,
                in: scrollView
            ) else { return }
            if self.distanceToBottom(in: scrollView) <= NativeTimelineScrollCore.bottomEpsilon {
                if self.isKeyboardFocus(token: layoutToken) {
                    self.scheduleBottomConvergence(
                        generationToken: generationToken,
                        layoutToken: layoutToken,
                        remainingPasses: remainingPasses - 1
                    )
                }
                return
            }
            self.writeBottomTargetSynchronizedWithKeyboardIfNeeded(animated: false)
            self.scheduleBottomConvergence(
                generationToken: generationToken,
                layoutToken: layoutToken,
                remainingPasses: remainingPasses - 1
            )
        }
    }

    private func writeBottomTargetSynchronizedWithKeyboardIfNeeded(animated: Bool) {
        guard let scrollView else { return }
        let target = bottomTarget(in: scrollView)
        if let keyboardAnimation = currentKeyboardAnimation(),
           !UIAccessibility.isReduceMotionEnabled {
            guard abs(scrollView.contentOffset.y - target) >= NativeTimelineScrollCore.arrivalEpsilon else {
                wasNearBottomAtLastSample = true
                return
            }
            if UIView.inheritedAnimationDuration > 0 {
                writeOffsetY(target)
            } else {
                let remaining = max(0.05, keyboardAnimation.expiresAt - CACurrentMediaTime())
                UIView.animate(
                    withDuration: min(keyboardAnimation.duration, remaining),
                    delay: 0,
                    options: keyboardAnimation.options,
                    animations: { [weak self] in
                        self?.writeOffsetY(target)
                    }
                )
            }
            wasNearBottomAtLastSample = true
            return
        }
        writeBottomTarget(animated: animated)
    }

    private func writeBottomTarget(animated: Bool) {
        guard let scrollView else { return }
        let target = bottomTarget(in: scrollView)
        guard animated else {
            UIView.performWithoutAnimation { [weak self] in
                self?.writeOffsetY(target)
            }
            wasNearBottomAtLastSample = true
            return
        }
        programmaticBottomAnimationCount += 1
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
            animations: { [weak self] in
                self?.writeOffsetY(target)
            },
            completion: { [weak self] _ in
                guard let self else { return }
                self.programmaticBottomAnimationCount = max(0, self.programmaticBottomAnimationCount - 1)
            }
        )
        wasNearBottomAtLastSample = true
    }

    private func installKeyboardObserverIfNeeded() {
        guard !isObservingKeyboardWillChange else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillChangeNotification(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        isObservingKeyboardWillChange = true
    }

    @objc private func handleKeyboardWillChangeNotification(_ notification: Notification) {
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        handleKeyboardWillChangeFrame(duration: duration, curveRaw: curveRaw)
    }

    func handleKeyboardWillChangeFrame(duration: TimeInterval, curveRaw: UInt) {
        guard fallbackReason == nil, automaticFollowEnabled, let scrollView else { return }
        let shouldFollow = !isPausedForUser &&
            !isUIKitUserInteracting &&
            (isFollowingBottomOrKeyboardFocus ||
             wasNearBottomAtLastSample ||
             distanceToBottom(in: scrollView) <= NativeTimelineScrollCore.resumeEpsilon)
        guard duration > 0 else {
            activeKeyboardAnimation = nil
            return
        }
        let curveOptions = UIView.AnimationOptions(rawValue: curveRaw << 16)
        activeKeyboardAnimation = ActiveKeyboardAnimation(
            duration: duration,
            options: curveOptions.union([.beginFromCurrentState, .allowUserInteraction]),
            expiresAt: CACurrentMediaTime() + duration + 0.05,
            shouldFollowBottom: shouldFollow
        )
    }

    private func currentKeyboardAnimation(now: CFTimeInterval = CACurrentMediaTime()) -> ActiveKeyboardAnimation? {
        guard let animation = activeKeyboardAnimation else { return nil }
        guard now < animation.expiresAt else {
            activeKeyboardAnimation = nil
            return nil
        }
        return animation
    }

    private func startFrameDriver() {
        guard displayLink == nil else { return }
        lastDisplayLinkTimestamp = nil
        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopFrameDriver() {
        displayLink?.invalidate()
        displayLink = nil
        lastDisplayLinkTimestamp = nil
    }

    private func cancelProgrammaticMotion() {
        guard programmaticBottomAnimationCount > 0 else { return }
        programmaticBottomAnimationCount = 0
        if let scrollView {
            let currentOrigin = scrollView.layer.presentation()?.bounds.origin ?? scrollView.bounds.origin
            scrollView.layer.removeAnimation(forKey: "bounds")
            scrollView.layer.removeAnimation(forKey: "bounds.origin")
            scrollView.setContentOffset(
                CGPoint(x: 0, y: clampedOffsetY(currentOrigin.y, in: scrollView)),
                animated: false
            )
        }
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        guard validateScrollViewHealth() else { return }
        let now = link.timestamp
        let dt = lastDisplayLinkTimestamp.map { now - $0 } ?? link.duration
        lastDisplayLinkTimestamp = now
        let result = NativeTimelineScrollCore.tick(
            state: state,
            geometry: sampleGeometry(),
            now: now,
            dt: dt
        )
        state = result.state
        perform(result.actions, token: generation)
    }

    private func sampleGeometry(
        wasNearBottomBeforeViewportChange: Bool = false
    ) -> NativeTimelineScrollGeometry {
        guard let scrollView else {
            return NativeTimelineScrollGeometry(
                offsetY: 0,
                contentHeight: 0,
                viewportHeight: 1,
                adjustedInsetTop: 0,
                adjustedInsetBottom: 0,
                distanceToBottom: 0,
                userInteracting: false,
                wasNearBottomBeforeViewportChange: wasNearBottomBeforeViewportChange
            )
        }
        let distance = distanceToBottom(in: scrollView)
        wasNearBottomAtLastSample = distance <= NativeTimelineScrollCore.resumeEpsilon
        return NativeTimelineScrollGeometry(
            offsetY: scrollView.contentOffset.y,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height,
            adjustedInsetTop: scrollView.adjustedContentInset.top,
            adjustedInsetBottom: scrollView.adjustedContentInset.bottom,
            distanceToBottom: distance,
            userInteracting: scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating,
            wasNearBottomBeforeViewportChange: wasNearBottomBeforeViewportChange
        )
    }

    private func writeOffsetY(_ rawOffsetY: CGFloat) {
        guard let scrollView else { return }
        guard rawOffsetY.isFinite else {
            reportFallback(.nonFiniteOffset)
            return
        }
        scrollView.setContentOffset(
            CGPoint(x: 0, y: clampedOffsetY(rawOffsetY, in: scrollView)),
            animated: false
        )
    }

    private func bottomTarget(in scrollView: UIScrollView) -> CGFloat {
        max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + effectiveBottomInset(in: scrollView)
        )
    }

    private func clampedOffsetY(_ offsetY: CGFloat, in scrollView: UIScrollView) -> CGFloat {
        guard offsetY.isFinite else { return scrollView.contentOffset.y }
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(minimumY, bottomTarget(in: scrollView))
        return min(max(offsetY, minimumY), maximumY)
    }

    private func distanceToBottom(in scrollView: UIScrollView) -> CGFloat {
        let visibleHeight = max(
            1,
            scrollView.bounds.height -
                scrollView.adjustedContentInset.top -
                effectiveBottomInset(in: scrollView)
        )
        let visibleMaxY = scrollView.contentOffset.y +
            scrollView.adjustedContentInset.top +
            visibleHeight
        return max(0, scrollView.contentSize.height - visibleMaxY)
    }

    private func effectiveBottomInset(in scrollView: UIScrollView) -> CGFloat {
        scrollView.adjustedContentInset.bottom
    }

    private func isKeyboardFocus(token: UInt64) -> Bool {
        guard case let .keyboardFocus(transaction) = state else { return false }
        return transaction.token == token
    }

    private func bottomConvergenceLayoutToken(defaultToken: UInt64) -> UInt64 {
        guard case let .keyboardFocus(transaction) = state else { return defaultToken }
        return transaction.token
    }

    private func canContinueBottomConvergence(
        generationToken: UInt64,
        layoutToken: UInt64,
        in scrollView: UIScrollView
    ) -> Bool {
        guard fallbackReason == nil, generation == generationToken else { return false }
        guard !(scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating) else { return false }
        switch state {
        case .followingBottom:
            return true
        case let .keyboardFocus(transaction):
            return transaction.token == layoutToken
        case .idle, .pausedForUser, .settlingAfterTerminal:
            return false
        }
    }

    private func normalizedIntent(
        _ intent: NativeTimelineScrollIntent,
        token: UInt64
    ) -> NativeTimelineScrollIntent {
        switch intent {
        case let .explicitBottom(source, animated, _):
            guard source == .composerFocus else { return intent }
            return .explicitBottom(source: source, animated: animated, keyboardToken: token)
        default:
            return intent
        }
    }

    private func validateScrollViewHealth() -> Bool {
        guard let scrollView else { return true }
        if abs(scrollView.contentOffset.x) > 0.5 {
            scrollView.contentOffset.x = 0
            guard !horizontalOffsetDriftClampUsed else {
                reportFallback(.horizontalOffsetDrift)
                return false
            }
            horizontalOffsetDriftClampUsed = true
        }
        return true
    }

    private func reportFallback(_ reason: NativeTimelineScrollFallbackReason) {
        guard fallbackReason == nil else { return }
        let shouldReplayBottom = shouldReplayBottomAfterFallback()
        let geometry = sampleGeometry()
        fallbackReason = reason
        generation &+= 1
        cancelProgrammaticMotion()
        stopFrameDriver()
        state = .idle
        scrollView = nil
        NativeTimelineScrollDiagnostics.logFallback(
            reason: reason,
            geometry: geometry
        )
        onFallback?(reason, shouldReplayBottom)
    }

    private func shouldReplayBottomAfterFallback() -> Bool {
        guard automaticFollowEnabled else { return false }
        if let scrollView,
           scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            return false
        }
        switch state {
        case .followingBottom, .settlingAfterTerminal, .keyboardFocus:
            return true
        case .idle, .pausedForUser:
            return false
        }
    }
}

@MainActor
private struct ViewportMetrics: Equatable {
    let size: CGSize
    let adjustedContentInset: UIEdgeInsets

    var visibleHeight: CGFloat {
        max(1, size.height - adjustedContentInset.top - adjustedContentInset.bottom)
    }

    init(_ scrollView: UIScrollView) {
        size = scrollView.bounds.size
        adjustedContentInset = scrollView.adjustedContentInset
    }
}

/// Evaluates whether a single tap inside a timeline `UIScrollView` should dismiss
/// the software keyboard without swallowing links, citations, controls, or active
/// text selections.
@MainActor
enum NativeTimelineTapDismissPolicy {
    static func shouldAllowTapToDismiss(
        in scrollView: UIScrollView,
        hitView: UIView?,
        locationInHitView: CGPoint
    ) -> Bool {
        guard let hitView else { return true }
        var current: UIView? = hitView
        while let view = current, view !== scrollView {
            if view is UIControl {
                return false
            }
            if let textView = view as? UITextView {
                if textView.isEditable || textView.selectedRange.length > 0 {
                    return false
                }
                let pointInTextView = hitView.convert(locationInHitView, to: textView)
                if hitsInteractiveTextItem(in: textView, at: pointInTextView) {
                    return false
                }
            }
            let className = NSStringFromClass(type(of: view))
            if className.contains("WKWebView") || className.contains("UIButton") {
                return false
            }
            current = view.superview
        }
        return true
    }

    static func hitsInteractiveTextItem(in textView: UITextView, at point: CGPoint) -> Bool {
        guard let attributedText = textView.attributedText, attributedText.length > 0 else {
            return false
        }
        guard textView.bounds.insetBy(dx: -8, dy: -8).contains(point) else {
            return false
        }

        if textView.textLayoutManager == nil {
            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            let containerPoint = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            let numberOfGlyphs = layoutManager.numberOfGlyphs
            if numberOfGlyphs > 0 {
                var fraction: CGFloat = 0
                let glyphIndex = layoutManager.glyphIndex(
                    for: containerPoint,
                    in: textContainer,
                    fractionOfDistanceThroughGlyph: &fraction
                )
                if glyphIndex < numberOfGlyphs {
                    let lineRect = layoutManager.lineFragmentUsedRect(
                        forGlyphAt: glyphIndex,
                        effectiveRange: nil
                    ).insetBy(dx: -10, dy: -10)
                    if lineRect.contains(containerPoint) {
                        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
                        if hasInteractiveAttribute(in: attributedText, at: charIndex) {
                            return true
                        }
                    }
                }
            }
        }

        if let position = textView.closestPosition(to: point) {
            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            for candidate in [offset, offset - 1] where candidate >= 0 && candidate < attributedText.length {
                guard hasInteractiveAttribute(in: attributedText, at: candidate) else { continue }
                if let start = textView.position(from: textView.beginningOfDocument, offset: candidate),
                   let end = textView.position(from: start, offset: 1),
                   let range = textView.textRange(from: start, to: end) {
                    let rect = textView.firstRect(for: range).insetBy(dx: -12, dy: -12)
                    if !rect.isNull, !rect.isEmpty, rect.contains(point) {
                        return true
                    }
                }
            }
        }

        return false
    }

    private static func hasInteractiveAttribute(in attributedText: NSAttributedString, at index: Int) -> Bool {
        guard index >= 0, index < attributedText.length else { return false }
        let attrs = attributedText.attributes(at: index, effectiveRange: nil)
        if attrs[.link] != nil || attrs[.attachment] != nil {
            return true
        }
        return attrs.keys.contains { key in
            let raw = key.rawValue.lowercased()
            return raw.contains("citation") || raw.contains("link")
        }
    }
}

/// Resolves the `UIScrollView` owned by a SwiftUI `ScrollView` and reports native
/// layout metric changes to the shared bottom-follow driver.
struct NativeTimelineScrollViewResolver: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void
    let onMetricsChanged: () -> Void
    var onDismissKeyboard: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onMetricsChanged: onMetricsChanged, onDismissKeyboard: onDismissKeyboard)
    }

    func makeUIView(context: Context) -> UIView {
        let view = ResolverProbeView(frame: .zero)
        view.isHidden = true
        view.onResolveIfNeeded = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator,
                  let scrollView = view.nativeTimelineAncestor(of: UIScrollView.self) else { return }
            onResolve(scrollView)
            coordinator.observe(scrollView)
        }
        view.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.monitorRecentMetrics()
        }
        return view
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onDismissKeyboard = onDismissKeyboard
        DispatchQueue.main.async { [weak view] in
            guard let scrollView = view?.nativeTimelineAncestor(of: UIScrollView.self) else { return }
            onResolve(scrollView)
            context.coordinator.observe(scrollView)
            context.coordinator.monitorRecentMetrics()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let onMetricsChanged: () -> Void
        var onDismissKeyboard: (() -> Void)?
        private weak var observedScrollView: UIScrollView?
        private weak var tapGestureRecognizer: UITapGestureRecognizer?
        private var displayLink: CADisplayLink?
        private var monitoringDeadline: CFTimeInterval?
        private var keyboardFrameObserver: NSObjectProtocol?
        private var pendingCallback = false
        private var lastMetrics: Metrics?
        private var invalidated = false

        // UIScrollView 未承诺这些指标符合 KVO；由布局和键盘事件开启静止窗口采样。
        private let quietInterval: CFTimeInterval = 0.35

        init(
            onMetricsChanged: @escaping () -> Void,
            onDismissKeyboard: (() -> Void)? = nil
        ) {
            self.onMetricsChanged = onMetricsChanged
            self.onDismissKeyboard = onDismissKeyboard
        }

        func invalidate() {
            invalidated = true
            displayLink?.invalidate()
            displayLink = nil
            monitoringDeadline = nil
            if let keyboardFrameObserver {
                NotificationCenter.default.removeObserver(keyboardFrameObserver)
                self.keyboardFrameObserver = nil
            }
            if let tapGestureRecognizer, let observedScrollView {
                observedScrollView.removeGestureRecognizer(tapGestureRecognizer)
            }
            tapGestureRecognizer = nil
            observedScrollView = nil
        }

        func observe(_ scrollView: UIScrollView) {
            guard !invalidated else { return }
            installTapGestureIfNeeded(on: scrollView)
            guard observedScrollView !== scrollView else { return }
            if let keyboardFrameObserver {
                NotificationCenter.default.removeObserver(keyboardFrameObserver)
                self.keyboardFrameObserver = nil
            }
            if let tapGestureRecognizer, let previous = observedScrollView, previous !== scrollView {
                previous.removeGestureRecognizer(tapGestureRecognizer)
                self.tapGestureRecognizer = nil
            }
            displayLink?.invalidate()
            displayLink = nil
            monitoringDeadline = nil
            observedScrollView = scrollView
            installTapGestureIfNeeded(on: scrollView)
            lastMetrics = Metrics(scrollView)
            observeKeyboardFrameChanges()
            scheduleCallback()
        }

        private func installTapGestureIfNeeded(on scrollView: UIScrollView) {
            guard onDismissKeyboard != nil else { return }
            if let existing = tapGestureRecognizer, existing.view === scrollView {
                return
            }
            let recognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(handleTapGesture(_:))
            )
            recognizer.numberOfTapsRequired = 1
            recognizer.numberOfTouchesRequired = 1
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            scrollView.addGestureRecognizer(recognizer)
            tapGestureRecognizer = recognizer
        }

        @objc
        private func handleTapGesture(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onDismissKeyboard?()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let scrollView = observedScrollView else { return true }
            let hitView = touch.view
            let location = hitView.map { touch.location(in: $0) } ?? .zero
            return NativeTimelineTapDismissPolicy.shouldAllowTapToDismiss(
                in: scrollView,
                hitView: hitView,
                locationInHitView: location
            )
        }

        func monitorRecentMetrics() {
            guard !invalidated, observedScrollView != nil else { return }
            monitoringDeadline = CACurrentMediaTime() + quietInterval
            startDisplayLinkIfNeeded()
        }

        private func observeKeyboardFrameChanges() {
            keyboardFrameObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.monitorRecentMetrics()
                }
            }
        }

        private func startDisplayLinkIfNeeded() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc
        private func displayLinkTick(_ link: CADisplayLink) {
            guard let scrollView = observedScrollView else {
                stopDisplayLink()
                return
            }
            let metrics = Metrics(scrollView)
            if metrics != lastMetrics {
                lastMetrics = metrics
                monitoringDeadline = link.timestamp + quietInterval
                if !invalidated {
                    onMetricsChanged()
                }
            }
            if let monitoringDeadline, link.timestamp >= monitoringDeadline {
                stopDisplayLink()
            }
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
            monitoringDeadline = nil
        }

        private func scheduleCallback() {
            guard !invalidated else { return }
            guard !pendingCallback else { return }
            pendingCallback = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pendingCallback = false
                guard !invalidated else { return }
                onMetricsChanged()
            }
        }

        @MainActor
        struct Metrics: Equatable {
            let contentSize: CGSize
            let viewportSize: CGSize
            let adjustedContentInset: UIEdgeInsets

            init(_ scrollView: UIScrollView) {
                contentSize = scrollView.contentSize
                viewportSize = scrollView.bounds.size
                adjustedContentInset = scrollView.adjustedContentInset
            }
        }
    }
}

private final class ResolverProbeView: UIView {
    var onResolveIfNeeded: (() -> Void)?
    var onLayout: (() -> Void)?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        onResolveIfNeeded?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onResolveIfNeeded?()
        onLayout?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onLayout?()
    }
}

private extension UIView {
    func nativeTimelineAncestor<T: UIView>(of type: T.Type) -> T? {
        var current = superview
        while let view = current {
            if let match = view as? T {
                return match
            }
            current = view.superview
        }
        return nil
    }
}

enum NativeTimelineScrollDiagnostics {
    static func logFallbackActivated(reason: NativeTimelineScrollFallbackReason) {
        print("[AA-NATIVE-SCROLL] fallbackActivated reason=\(reason.rawValue)")
    }

    static func logBottomConvergenceExhausted(geometry: NativeTimelineScrollGeometry) {
        print(
            "[AA-NATIVE-SCROLL] bottomConvergenceExhausted " +
                "offsetY=\(String(format: "%.1f", geometry.offsetY)) " +
                "distance=\(String(format: "%.1f", geometry.distanceToBottom)) " +
                "content=\(String(format: "%.1f", geometry.contentHeight)) " +
                "viewport=\(String(format: "%.1f", geometry.viewportHeight))"
        )
    }

    static func logFallback(
        reason: NativeTimelineScrollFallbackReason,
        geometry: NativeTimelineScrollGeometry
    ) {
        print(
            "[AA-NATIVE-SCROLL] fallback reason=\(reason.rawValue) " +
                "offsetY=\(String(format: "%.1f", geometry.offsetY)) " +
                "distance=\(String(format: "%.1f", geometry.distanceToBottom)) " +
                "content=\(String(format: "%.1f", geometry.contentHeight)) " +
                "viewport=\(String(format: "%.1f", geometry.viewportHeight))"
        )
    }
}
