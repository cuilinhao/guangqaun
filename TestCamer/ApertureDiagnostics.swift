//
//  ApertureDiagnostics.swift
//
//  光圈排查日志（临时）：PGY 和 Fdemo 用同一份代码、同一种格式打印，
//  同一场景下对比两边的曝光状态和曝光信号。排查完删除这个文件和调用处。
//

import AVFoundation

enum ApertureDiagnostics {
    /// 一行描述当前设备的曝光相关状态。
    static func describe(_ device: AVCaptureDevice, session: AVCaptureSession?, photoOutput: AVCapturePhotoOutput?) -> String {
        guard #available(iOS 27.0, *) else { return "iOS < 27" }
        let format = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let photo = photoOutput.map {
            "\($0.maxPhotoDimensions.width)x\($0.maxPhotoDimensions.height)/q\($0.maxPhotoQualityPrioritization.rawValue)"
        } ?? "-"
        let hdr = format.isVideoHDRSupported ? (device.isVideoHDREnabled ? "on" : "off") : "n/a"
        return [
            "device=\(device.deviceType.rawValue)",
            "preset=\(session?.sessionPreset.rawValue ?? "-")",
            "format=\(dims.width)x\(dims.height)",
            "photo=\(photo)",
            "fps=\(fps(device.activeVideoMaxFrameDuration))~\(fps(device.activeVideoMinFrameDuration))",
            "maxExp=\(exposureText(device.activeMaxExposureDuration))",
            "exp=\(exposureText(device.exposureDuration)) iso=\(Int(device.iso))",
            "bias=\(device.exposureTargetBias) offset=\(String(format: "%.2f", device.exposureTargetOffset))",
            "zoom=\(String(format: "%.2f", device.videoZoomFactor))",
            "color=\(device.activeColorSpace.rawValue) hdr=\(hdr)",
            "mode=\(device.exposureMode.rawValue) autoAperture=\(device.automaticallyAdjustsLensAperture) rate=\(device.autoExposureLensApertureRateLimit)",
            "lens=ƒ\(String(format: "%.2f", device.lensAperture)) default=ƒ\(format.defaultLensAperture) range=ƒ\(format.minLensAperture)~ƒ\(format.maxLensAperture)",
            "autoSignals=\(device.automaticallyEnablesExposureSignals)",
            "supported=[\(names(device.supportedExposureSignals))]",
            "enabled=[\(names(device.enabledExposureSignals))]",
            "active=[\(names(device.activeExposureSignals))]",
            "faceAE=\(device.isFaceDrivenAutoExposureEnabled)",
            "focus=\(device.focusMode.rawValue)/\(String(format: "%.2f", device.lensPosition))",
        ].joined(separator: " ")
    }

    /// 观察光圈（变化超过 0.05 才打）和生效的曝光信号，每次变化打一行。返回的观察者需要持有。
    static func observe(_ device: AVCaptureDevice, tag: String) -> [NSKeyValueObservation] {
        guard #available(iOS 27.0, *) else { return [] }
        final class Last: @unchecked Sendable {
            var aperture: Float = -1
        }
        let last = Last()
        let aperture = device.observe(\.lensAperture, options: [.initial, .new]) { device, _ in
            let value = device.lensAperture
            guard abs(value - last.aperture) >= 0.05 else { return }
            print("[Aperture] \(tag) lens ƒ\(String(format: "%.2f", last.aperture)) → ƒ\(String(format: "%.2f", value)) exp=\(ApertureDiagnostics.exposureText(device.exposureDuration)) iso=\(Int(device.iso)) active=[\(ApertureDiagnostics.names(device.activeExposureSignals))]")
            last.aperture = value
        }
        let signals = device.observe(\.activeExposureSignals, options: [.initial, .new]) { device, _ in
            print("[Aperture] \(tag) active=[\(ApertureDiagnostics.names(device.activeExposureSignals))] lens=ƒ\(String(format: "%.2f", device.lensAperture)) exp=\(ApertureDiagnostics.exposureText(device.exposureDuration)) iso=\(Int(device.iso))")
        }
        return [aperture, signals]
    }

    @available(iOS 27.0, *)
    static func names(_ signals: Set<AVCaptureDeviceExposureSignal>) -> String {
        signals
            .map { $0.rawValue.replacingOccurrences(of: "AVCaptureDeviceExposureSignal", with: "") }
            .sorted()
            .joined(separator: ",")
    }

    private static func exposureText(_ time: CMTime) -> String {
        let seconds = time.seconds
        guard seconds.isFinite, seconds > 0 else { return "-" }
        return seconds >= 1 ? String(format: "%.1fs", seconds) : "1/\(Int((1 / seconds).rounded()))"
    }

    private static func fps(_ duration: CMTime) -> String {
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return "-" }
        return String(format: "%.0f", 1 / seconds)
    }
}
