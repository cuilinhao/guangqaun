//
//  AutoAperture.swift
//
//  自动光圈由 App 选档。iOS 27 的 continuousAutoExposure 基本把光圈停在一档，
//  只在合影、文档、星芒这类曝光信号生效时才换，亮度和远近变化都不会让它动。
//  所以自动模式下由这里按场景亮度和对焦距离选一档，再用"光圈优先"下发：
//  锁 𝑓 值，快门和 ISO 仍由系统自动曝光决定。
//

import AVFoundation

/// 选档规则。近拍部分按系统相机录屏对过；亮度部分（暗光、户外）还没和系统对过，
/// 对照 `[AutoAperture]` 日志里的 ev / dist 再调。
struct AutoAperturePolicy: Sendable {
    /// 普通场景的档位。苹果相机的默认光圈是 ƒ1.8。
    var normalAperture: Float = 1.8
    /// 场景亮度（EV100）低于它时开到最大光圈，少抬 ISO。大致是晚上的室内。
    var lowLightEV: Float = 6
    /// 高于它时收到 brightAperture，景深更深、画质更好。大致是阴天户外、明亮的窗边。
    var brightEV: Float = 11
    var brightAperture: Float = 2.8
    /// 高于它时收到最小光圈，免得快门被逼得过快。大致是晴天户外。
    var veryBrightEV: Float = 14
    /// 贴近到对焦最近端时直接收到 closeUpAperture 补景深，拿远后回到普通档，中间不经过 ƒ2.8。
    /// 照系统相机录屏定的：室内远处和一般近拍都是 ƒ1.8，贴到最近对焦距离（系统此时出现微距图标）
    /// 约 0.4 秒后开始收光圈，0.5 秒内从 ƒ1.8 走到 ƒ4.0；拿远后同样快速回到 ƒ1.8。
    /// 距离是按对焦位置估的，只看相对远近：贴近时估出 0.20m（对焦位置 0），拿远后 0.41~0.51m。
    /// 近于 enter 进入，远于 exit 退出，中间不动，免得来回跳。单位米。
    var closeUpEnterDistance: Float = 0.24
    var closeUpExitDistance: Float = 0.30
    var closeUpAperture: Float = 4.0
    /// 近拍收光圈要求的最低亮度；更暗时宁可景深浅，也不再抬 ISO。
    var closeUpMinEV: Float = 6
    /// 亮度阈值两侧各留的回差（EV）。
    var hysteresisEV: Float = 0.5
    /// 新档位要连续保持 dwell 秒才切换，两次切换至少隔 minInterval 秒。
    var dwell: TimeInterval = 0.4
    var minInterval: TimeInterval = 0.8
    /// 切档后的这段时间光圈还在动、自动曝光还在追，读数不准，不计入。
    var settle: TimeInterval = 0.5
    /// 每次采样的 EV 指数平滑系数，越大跟得越快。
    var smoothing: Float = 0.4
}

/// 根据曝光读数推算的场景亮度和对焦距离决定自动光圈用哪一档。
/// 只做计算不碰设备；调用方保证在同一个队列上使用。
struct AutoApertureController {
    struct Sample {
        /// 场景亮度 EV100，与当前用的光圈无关。
        var ev: Float
        /// 估算的对焦距离（米）；正在对焦时为 nil。
        var distance: Float?
    }

    var policy = AutoAperturePolicy()
    /// 升序；为空表示当前格式不能调光圈，自动光圈不工作。
    private(set) var stops: [Float] = []
    /// 已下发的档位。
    private(set) var target: Float?
    private(set) var ev: Float?
    private(set) var distance: Float?
    private(set) var isCloseUp = false
    private var candidate: (aperture: Float, since: TimeInterval)?
    private var lastChange: TimeInterval = -.infinity

    /// 换镜头、换格式后调用。能调光圈时先停在普通档位，读数稳定后再调整。
    mutating func reset(stops: [Float], now: TimeInterval) {
        self.stops = stops.sorted()
        ev = nil
        distance = nil
        isCloseUp = false
        candidate = nil
        target = self.stops.isEmpty ? nil : snap(policy.normalAperture)
        lastChange = now
    }

    mutating func record(_ sample: Sample, now: TimeInterval) {
        guard !stops.isEmpty, sample.ev.isFinite, now - lastChange >= policy.settle else { return }
        if let ev {
            self.ev = ev + policy.smoothing * (sample.ev - ev)
        } else {
            ev = sample.ev
        }
        guard let newDistance = sample.distance else { return }
        distance = newDistance
        if isCloseUp {
            if newDistance > policy.closeUpExitDistance {
                isCloseUp = false
            }
        } else if newDistance < policy.closeUpEnterDistance {
            isCloseUp = true
        }
    }

    /// 返回需要切到的新档位，不用切时返回 nil。
    mutating func update(now: TimeInterval) -> Float? {
        guard let ev, let current = target else { return nil }
        let wanted = wantedAperture(ev: ev, current: current)
        guard wanted != current else {
            candidate = nil
            return nil
        }
        if candidate?.aperture != wanted {
            candidate = (wanted, now)
        }
        guard let since = candidate?.since, now - since >= policy.dwell,
              now - lastChange >= policy.minInterval else { return nil }
        commit(wanted, now: now)
        return wanted
    }

    /// 从手动切回自动时直接按当前读数选档，不等驻留。
    mutating func chooseNow(_ now: TimeInterval) -> Float? {
        guard !stops.isEmpty else { return nil }
        let value = ev.map { aperture(forEV: $0, closeUp: isCloseUp) } ?? snap(policy.normalAperture)
        commit(value, now: now)
        return value
    }

    /// 亮度越高 𝑓 值越大。结果随 EV 单调不减，回差判断依赖这一点。
    func aperture(forEV ev: Float, closeUp: Bool) -> Float {
        guard let widest = stops.first, let narrowest = stops.last else { return 0 }
        var value: Float
        if ev < policy.lowLightEV {
            value = widest
        } else if ev >= policy.veryBrightEV {
            value = narrowest
        } else if ev >= policy.brightEV {
            value = max(policy.normalAperture, policy.brightAperture)
        } else {
            value = policy.normalAperture
        }
        if closeUp, ev >= policy.closeUpMinEV {
            value = max(value, policy.closeUpAperture)
        }
        return snap(value)
    }

    /// 按曝光档数（𝑓 值的对数）取最近的档位。
    func snap(_ value: Float) -> Float {
        stops.min { abs(log2($0 / value)) < abs(log2($1 / value)) } ?? value
    }

    var logDescription: String {
        let evText = ev.map { String(format: "%.1f", $0) } ?? "-"
        let distanceText = distance.map { $0.isFinite ? String(format: "%.2fm", $0) : "∞" } ?? "-"
        let targetText = target.map { String(format: "ƒ%.2f", $0) } ?? "-"
        return "ev=\(evText) dist≈\(distanceText) closeUp=\(isCloseUp) target=\(targetText)"
    }

    /// 亮度阈值两侧各让出 hysteresisEV：读数落在回差区里时保持现档位。
    private func wantedAperture(ev: Float, current: Float) -> Float {
        let lower = aperture(forEV: ev - policy.hysteresisEV, closeUp: isCloseUp)
        let upper = aperture(forEV: ev + policy.hysteresisEV, closeUp: isCloseUp)
        return min(max(current, lower), upper)
    }

    private mutating func commit(_ value: Float, now: TimeInterval) {
        target = value
        lastChange = now
        candidate = nil
    }
}

extension AutoApertureController.Sample {
    /// EV100 = log2(N²/t) − log2(ISO/100)，再加上自动曝光还没追上的偏差和曝光补偿。
    /// 换光圈后快门和 ISO 会跟着变，这个值不变，所以选档不会被自己的结果牵着走。
    init?(device: AVCaptureDevice) {
        let duration = device.exposureDuration.seconds
        let iso = device.iso
        let aperture = device.lensAperture
        guard duration.isFinite, duration > 0, iso > 0, aperture > 0 else { return nil }
        let settings = log2(Double(aperture * aperture) / duration) - log2(Double(iso) / 100)
        let ev = Float(settings) + device.exposureTargetOffset + device.exposureTargetBias
        // 对焦马达位置近似与屈光度（1/距离）成线性：0 在最近对焦距离，1 在无穷远。
        var distance: Float?
        if !device.isAdjustingFocus, device.minimumFocusDistance > 0 {
            let nearest = Float(device.minimumFocusDistance) / 1000
            let remaining = 1 - device.lensPosition
            distance = remaining > 0.001 ? nearest / remaining : .infinity
        }
        self.init(ev: ev, distance: distance)
    }
}
