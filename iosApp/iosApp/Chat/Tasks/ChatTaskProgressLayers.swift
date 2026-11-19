import SwiftUI
import UIKit

/// Progress decoration stays in the presentation layer: its clock must not
/// invalidate the enclosing, eagerly laid-out conversation every animation tick.
struct ChatTaskWaveLayers: UIViewRepresentable {
    let tint: Color
    let paused: Bool

    func makeUIView(context: Context) -> ChatTaskWaveLayerView { ChatTaskWaveLayerView() }
    func updateUIView(_ view: ChatTaskWaveLayerView, context: Context) {
        view.tintColor = UIColor(tint)
        view.setAnimationPaused(paused)
    }
}

final class ChatTaskWaveLayerView: ChatTaskProgressLayerView {
    private let dots = (0..<3).map { _ in CAShapeLayer() }
    private let epoch = Date().timeIntervalSinceReferenceDate

    override init(frame: CGRect) {
        super.init(frame: frame)
        for dot in dots { layer.addSublayer(dot) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            dot.bounds = CGRect(x: 0, y: 0, width: 5.2, height: 5.2)
            dot.contentsScale = traitCollection.displayScale
            dot.position = CGPoint(x: 2.6 + CGFloat(index) * 8.7, y: bounds.midY)
            dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.fillColor = tintColor.resolvedColor(with: traitCollection).cgColor
            guard dot.animation(forKey: "wave") == nil else { continue }
            let duration = 2 * Double.pi / 4.6
            let samples = (0...60).map { step in
                ChatTaskProgressDot.waveMetrics(at: epoch + Double(step) / 60 * duration,
                    dotIndex: index, isLive: true, reduceMotion: false)
            }
            let position = CAKeyframeAnimation(keyPath: "transform.translation.y")
            position.values = samples.map { $0.offsetY }
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = samples.map { $0.opacity }
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = samples.map { $0.scale }
            let group = CAAnimationGroup()
            group.animations = [position, opacity, scale]
            group.duration = duration
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .linear)
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            dot.add(group, forKey: "wave")
        }
        CATransaction.commit()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsLayout()
    }
}

struct ChatTaskShimmerLayers: UIViewRepresentable {
    let accent: Color
    let paused: Bool

    func makeUIView(context: Context) -> ChatTaskShimmerLayerView { ChatTaskShimmerLayerView() }
    func updateUIView(_ view: ChatTaskShimmerLayerView, context: Context) {
        view.tintColor = UIColor(accent)
        view.setAnimationPaused(paused)
    }
}

final class ChatTaskShimmerLayerView: ChatTaskProgressLayerView {
    private let band = CAGradientLayer()
    private var animatedWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.locations = [0, 0.35, 0.5, 0.65, 1]
        layer.addSublayer(band)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = max(bounds.width * 0.42, 28)
        band.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height + 4)
        band.contentsScale = traitCollection.displayScale
        band.position.y = bounds.midY
        let accent = tintColor.resolvedColor(with: traitCollection)
        band.colors = [UIColor.clear.cgColor, accent.withAlphaComponent(0.55).cgColor,
            UIColor.white.withAlphaComponent(0.82).cgColor, accent.withAlphaComponent(0.55).cgColor,
            UIColor.clear.cgColor]
        if animatedWidth != bounds.width || band.animation(forKey: "sweep") == nil {
            animatedWidth = bounds.width
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = -width / 2
            sweep.toValue = bounds.width + width * 1.5
            sweep.duration = 1.8
            sweep.repeatCount = .infinity
            sweep.timingFunction = CAMediaTimingFunction(name: .linear)
            sweep.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            sweep.beginTime = band.convertTime(CACurrentMediaTime(), from: nil) -
                Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8)
            band.add(sweep, forKey: "sweep")
        }
        CATransaction.commit()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsLayout()
    }
}

class ChatTaskProgressLayerView: UIView {
    private var animationPaused = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setAnimationPaused(_ paused: Bool) {
        guard paused != animationPaused else { return }
        animationPaused = paused
        if paused {
            let time = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = time
        } else {
            let time = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - time
        }
    }
}
