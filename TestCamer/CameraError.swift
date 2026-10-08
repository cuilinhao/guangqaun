import Foundation

enum CameraError: LocalizedError, Equatable, Sendable {
    case notAuthorized
    case unavailable
    case configurationFailed
    case captureFailed
    case photoLibraryDenied
    case busy
    case interrupted
    case captureTimedOut
    case recordingFailed
    case apertureUnsupported
    case livePhotoUnsupported

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "未获得相机权限，请在设置中开启。"
        case .unavailable:
            return "当前没有可用相机，请使用真机并确认相机未被占用。"
        case .configurationFailed:
            return "相机初始化失败，请退出后重试。"
        case .captureFailed:
            return "拍照失败，请重试。"
        case .photoLibraryDenied:
            return "未获得相册写入权限，照片无法保存。"
        case .busy:
            return "照片正在处理中，请稍候。"
        case .interrupted:
            return "相机被系统中断，回到 App 后可重试。"
        case .captureTimedOut:
            return "本次拍摄等待超时，请重新拍摄。"
        case .recordingFailed:
            return "视频录制失败，请重试。"
        case .apertureUnsupported:
            return "当前镜头或拍摄格式不支持调节光圈。"
        case .livePhotoUnsupported:
            return "当前镜头或模式不支持实况照片。"
        }
    }
}
