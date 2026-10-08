import UIKit

/// 仿系统相机的"镜头光圈"面板：自动开关 + 推荐档位圆点，支持点按和横向拖动选档。
@MainActor
final class ApertureControlView: UIView {
    var onSelect: ((ApertureSetting) -> Void)?
    var onClose: (() -> Void)?

    private(set) var stops: [Float] = []
    private var setting: ApertureSetting = .auto
    private var liveAperture: Float = 0
    private var dragIndex: Int?

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let autoButton = UIButton(type: .system)
    private let autoLabel = UILabel()
    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []
    private let selection = UISelectionFeedbackGenerator()

    private static let accent = UIColor.systemYellow

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(stops: [Float], setting: ApertureSetting, liveAperture: Float) {
        if stops != self.stops {
            self.stops = stops
            rebuildDots()
        }
        self.setting = setting
        self.liveAperture = liveAperture
        refresh()
    }

    static func format(_ value: Float) -> String {
        let rounded = (value * 100).rounded() / 100
        let isOneDecimal = abs(rounded * 10 - (rounded * 10).rounded()) < 0.001
        return String(format: isOneDecimal ? "%.1f" : "%.2f", rounded)
    }

    static func attributedValue(_ value: Float, size: CGFloat, color: UIColor) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: "ƒ",
            attributes: [
                .font: UIFont.italicSystemFont(ofSize: size * 0.6),
                .foregroundColor: color,
                .baselineOffset: size * 0.3
            ]
        )
        text.append(NSAttributedString(
            string: format(value),
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

    /// 自动模式下高亮离实际叶片位置最近的档位。
    var highlightedIndex: Int? {
        if let dragIndex { return dragIndex }
        return nearestIndex(to: displayedValue)
    }

    func nearestIndex(to value: Float) -> Int? {
        stops.indices.min { abs(stops[$0] - value) < abs(stops[$1] - value) }
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
        dotsStack.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleDotGesture(_:))))
        dotsStack.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDotGesture(_:))))
        addSubview(dotsStack)

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
            dotsStack.widthAnchor.constraint(equalToConstant: 168),
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
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.accessibilityLabel = "ƒ\(Self.format(stop))"
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 14),
                dot.heightAnchor.constraint(equalToConstant: 14)
            ])
            dotsStack.addArrangedSubview(dot)
            return dot
        }
    }

    func refresh() {
        valueLabel.attributedText = Self.attributedValue(displayedValue, size: 30, color: .white)
        autoLabel.textColor = isAuto ? Self.accent : UIColor.white.withAlphaComponent(0.7)
        autoButton.configuration?.baseForegroundColor = isAuto ? .black : .white
        autoButton.configuration?.baseBackgroundColor = isAuto ? Self.accent : UIColor.white.withAlphaComponent(0.12)

        let highlighted = highlightedIndex
        for (index, dot) in dotViews.enumerated() {
            let isOn = index == highlighted
            UIView.animate(withDuration: 0.15) {
                dot.backgroundColor = isOn ? Self.accent : .clear
                dot.layer.borderWidth = isOn ? 0 : 1.5
                dot.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
                dot.transform = isOn ? CGAffineTransform(scaleX: 1.3, y: 1.3) : .identity
            }
        }
    }

    func index(at location: CGPoint) -> Int? {
        guard !dotViews.isEmpty else { return nil }
        return dotViews.indices.min {
            abs(dotViews[$0].frame.midX - location.x) < abs(dotViews[$1].frame.midX - location.x)
        }
    }

    @objc func handleDotGesture(_ gesture: UIGestureRecognizer) {
        guard let index = index(at: gesture.location(in: dotsStack)) else { return }
        switch gesture.state {
        case .began, .changed, .ended:
            let target = ApertureSetting.manual(stops[index])
            let changed = target != setting
            dragIndex = gesture.state == .ended ? nil : index
            if changed {
                selection.selectionChanged()
                setting = target
                onSelect?(target)
            }
            refresh()
        default:
            dragIndex = nil
            refresh()
        }
    }

    @objc func autoTapped() {
        selection.selectionChanged()
        if isAuto, let index = nearestIndex(to: liveAperture) {
            setting = .manual(stops[index])
        } else {
            setting = .auto
        }
        refresh()
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
