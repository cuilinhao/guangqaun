import UIKit

/// 仿系统相机的"镜头光圈"面板：自动开关 + 推荐档位刻度，点按跳到档位，拖动按 0.01 连续调节。
@MainActor
final class ApertureControlView: UIView {
    var onSelect: ((ApertureSetting) -> Void)?
    var onClose: (() -> Void)?

    private(set) var stops: [Float] = []
    private var setting: ApertureSetting = .auto
    private var liveAperture: Float = 0
    private var isDragging = false

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let autoButton = UIButton(type: .system)
    private let autoLabel = UILabel()
    private let dotsStack = UIStackView()
    private let trackLine = UIView()
    private let thumbView = UIView()
    private var dotViews: [UIView] = []
    private let selection = UISelectionFeedbackGenerator()
    private let stopImpact = UIImpactFeedbackGenerator(style: .medium)

    private static let accent = UIColor.systemYellow
    private static let step: Float = 0.01
    /// 拖到刻度点附近这个距离内时吸附到正好的档位。
    private static let snapDistance: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dotsStack.layoutIfNeeded()
        layoutTrack()
        positionThumb(animated: false)
    }

    func update(stops: [Float], setting: ApertureSetting, liveAperture: Float) {
        if stops != self.stops {
            self.stops = stops
            rebuildDots()
        }
        // 拖动中相机回传的结果会落后于手指，忽略以免滑块回跳。
        if !isDragging {
            self.setting = setting
        }
        self.liveAperture = liveAperture
        refresh(animated: true)
    }

    /// 档位值用系统相机的写法（1.48 / 1.8 / 4.0），档位之间的值固定两位小数。
    static func format(_ value: Float, stops: [Float]) -> String {
        if let stop = stops.first(where: { abs($0 - value) < 0.005 }) {
            let isOneDecimal = abs(stop * 10 - (stop * 10).rounded()) < 0.001
            return String(format: isOneDecimal ? "%.1f" : "%.2f", stop)
        }
        return String(format: "%.2f", value)
    }

    static func attributedValue(_ value: Float, stops: [Float], size: CGFloat, color: UIColor) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: "ƒ",
            attributes: [
                .font: UIFont.italicSystemFont(ofSize: size * 0.6),
                .foregroundColor: color,
                .baselineOffset: size * 0.3
            ]
        )
        text.append(NSAttributedString(
            string: format(value, stops: stops),
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
                .foregroundColor: color
            ]
        ))
        return text
    }
}

private extension ApertureControlView {
    var isAuto: Bool { setting == .auto }

    var displayedValue: Float {
        switch setting {
        case .auto: return liveAperture
        case .manual(let value): return value
        }
    }

    var dotCenters: [CGFloat] {
        dotViews.map(\.center.x)
    }

    func nearestIndex(to value: Float) -> Int? {
        stops.indices.min { abs(stops[$0] - value) < abs(stops[$1] - value) }
    }

    /// 刻度点等距排列而档位值不等距，所以在相邻两个档位之间做分段线性映射。
    func xPosition(for value: Float) -> CGFloat? {
        let centers = dotCenters
        guard let first = stops.first, let last = stops.last, centers.count == stops.count else { return nil }
        if value <= first { return centers[0] }
        if value >= last { return centers[centers.count - 1] }
        for i in 0..<(stops.count - 1) where value <= stops[i + 1] {
            let t = CGFloat((value - stops[i]) / (stops[i + 1] - stops[i]))
            return centers[i] + t * (centers[i + 1] - centers[i])
        }
        return centers[centers.count - 1]
    }

    func value(at x: CGFloat) -> Float? {
        let centers = dotCenters
        guard centers.count == stops.count, let firstX = centers.first, let lastX = centers.last else { return nil }
        if let snap = centers.indices.first(where: { abs(centers[$0] - x) <= Self.snapDistance }) {
            return stops[snap]
        }
        if x <= firstX { return stops[0] }
        if x >= lastX { return stops[stops.count - 1] }
        for i in 0..<(centers.count - 1) where x <= centers[i + 1] {
            let t = Float((x - centers[i]) / (centers[i + 1] - centers[i]))
            let raw = stops[i] + t * (stops[i + 1] - stops[i])
            return (raw / Self.step).rounded() * Self.step
        }
        return stops[stops.count - 1]
    }

    func setup() {
        backgroundColor = UIColor(white: 0.13, alpha: 0.96)
        layer.cornerRadius = 40
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor

        titleLabel.text = "镜头光圈"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        valueLabel.textAlignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        configureRoundButton(closeButton, image: UIImage(systemName: "chevron.left"), title: nil)
        closeButton.accessibilityLabel = "收起光圈"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)

        configureRoundButton(autoButton, image: nil, title: "A")
        autoButton.accessibilityLabel = "自动光圈"
        autoButton.addTarget(self, action: #selector(autoTapped), for: .touchUpInside)
        addSubview(autoButton)

        autoLabel.text = "自动"
        autoLabel.font = .systemFont(ofSize: 14, weight: .medium)
        autoLabel.isUserInteractionEnabled = true
        autoLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(autoLabelTapped)))
        autoLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(autoLabel)

        dotsStack.axis = .horizontal
        dotsStack.alignment = .center
        dotsStack.distribution = .equalCentering
        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        dotsStack.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        addSubview(dotsStack)

        trackLine.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        trackLine.isUserInteractionEnabled = false
        dotsStack.addSubview(trackLine)

        thumbView.backgroundColor = Self.accent
        thumbView.layer.cornerRadius = 9
        thumbView.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        thumbView.isUserInteractionEnabled = false
        thumbView.isHidden = true
        dotsStack.addSubview(thumbView)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            autoButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            autoButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            autoButton.widthAnchor.constraint(equalToConstant: 36),
            autoButton.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),

            dotsStack.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 24),
            dotsStack.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 10),
            dotsStack.heightAnchor.constraint(equalToConstant: 40),
            dotsStack.widthAnchor.constraint(equalToConstant: 200),
            dotsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

            autoLabel.trailingAnchor.constraint(equalTo: dotsStack.leadingAnchor, constant: -18),
            autoLabel.centerYAnchor.constraint(equalTo: dotsStack.centerYAnchor)
        ])
    }

    func configureRoundButton(_ button: UIButton, image: UIImage?, title: String?) {
        var config = UIButton.Configuration.filled()
        config.image = image
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if let title {
            config.attributedTitle = AttributedString(
                title,
                attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 16, weight: .semibold)])
            )
        }
        config.cornerStyle = .capsule
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.12)
        config.contentInsets = .zero
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    func rebuildDots() {
        dotViews.forEach { $0.removeFromSuperview() }
        dotViews = stops.map { stop in
            let dot = UIView()
            dot.isUserInteractionEnabled = false
            dot.layer.cornerRadius = 7
            dot.layer.borderWidth = 1.5
            dot.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
            dot.backgroundColor = UIColor(white: 0.13, alpha: 1)
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.accessibilityLabel = "ƒ\(Self.format(stop, stops: stops))"
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 14),
                dot.heightAnchor.constraint(equalToConstant: 14)
            ])
            dotsStack.addArrangedSubview(dot)
            return dot
        }
        dotsStack.bringSubviewToFront(thumbView)
        setNeedsLayout()
    }

    func layoutTrack() {
        guard let first = dotCenters.first, let last = dotCenters.last else {
            trackLine.frame = .zero
            return
        }
        trackLine.frame = CGRect(x: first, y: dotsStack.bounds.midY - 0.75, width: last - first, height: 1.5)
        dotsStack.sendSubviewToBack(trackLine)
    }

    func positionThumb(animated: Bool) {
        guard let x = xPosition(for: displayedValue) else {
            thumbView.isHidden = true
            return
        }
        thumbView.isHidden = false
        let center = CGPoint(x: x, y: dotsStack.bounds.midY)
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.thumbView.center = center
            }
        } else {
            thumbView.center = center
        }
    }

    func refresh(animated: Bool) {
        valueLabel.attributedText = Self.attributedValue(displayedValue, stops: stops, size: 30, color: .white)
        autoLabel.textColor = isAuto ? Self.accent : UIColor.white.withAlphaComponent(0.7)
        autoButton.configuration?.baseForegroundColor = isAuto ? .black : .white
        autoButton.configuration?.baseBackgroundColor = isAuto ? Self.accent : UIColor.white.withAlphaComponent(0.12)
        thumbView.alpha = isAuto ? 0.55 : 1
        positionThumb(animated: animated)
    }

    func apply(_ value: Float) {
        let target = ApertureSetting.manual(value)
        guard target != setting else { return }
        let previous = displayedValue
        setting = target
        if stops.contains(value) {
            stopImpact.impactOccurred(intensity: 0.7)
        } else if Int((previous * 10).rounded(.down)) != Int((value * 10).rounded(.down)) {
            selection.selectionChanged()
        }
        onSelect?(target)
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: dotsStack).x
        guard let index = dotCenters.indices.min(by: { abs(dotCenters[$0] - x) < abs(dotCenters[$1] - x) }) else { return }
        apply(stops[index])
        refresh(animated: true)
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            isDragging = true
            if let value = value(at: gesture.location(in: dotsStack).x) {
                apply(value)
            }
            refresh(animated: false)
        case .ended:
            if let value = value(at: gesture.location(in: dotsStack).x) {
                apply(value)
            }
            isDragging = false
            refresh(animated: false)
        default:
            isDragging = false
            refresh(animated: true)
        }
    }

    @objc func autoTapped() {
        selection.selectionChanged()
        if isAuto, let index = nearestIndex(to: liveAperture) {
            setting = .manual(stops[index])
        } else {
            setting = .auto
        }
        refresh(animated: true)
        onSelect?(setting)
    }

    @objc func autoLabelTapped() {
        guard !isAuto else { return }
        autoTapped()
    }

    @objc func closeTapped() {
        onClose?()
    }
}
