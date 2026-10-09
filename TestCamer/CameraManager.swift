import Foundation
@preconcurrency import AVFoundation

enum CaptureMode: Sendable, Equatable {
    case photo
    case video
}

enum ApertureSetting: Sendable, Equatable {
    case auto
    case manual(Float)
}

struct CameraState: Sendable {
    let deviceID: String
    let isFront: Bool
    let hasFlash: Bool
    let zoomFactor: CGFloat
    let isRunning: Bool
    let mode: CaptureMode
    let isRecording: Bool
    let lensAperture: Float
    /// 为空表示当前镜头是固定光圈。
    let apertureStops: [Float]
    let aperture: ApertureSetting
    let isLivePhotoSupported: Bool
    let isLivePhotoEnabled: Bool
    let isFocusTrackingSupported: Bool
    let isFocusTracking: Bool
}

enum CameraEvent: Sendable {
    case ready(CameraState)
    case lensApertureChanged(Float)
    /// 被跟踪物体在 metadata output 坐标系中的归一化边框；物体离开画面时为 nil。
    case focusTrackedObject(CGRect?)
    case interrupted
    case issue(String)
}

struct CapturedPhoto: Sendable {
    let jpegData: Data
    /// 仅实况照片有值，是与照片配对的 .mov 临时文件。
    var livePhotoMovieURL: URL?
}

/// 相机会话只在 `sessionQueue` 上改配置；UI 通过不可变快照和事件接收状态。
final class CameraManager: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate,
    AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.testcamer.session", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var isFocusTracking = false
    /// 关掉后只用框中心点选主体，用来对比把整个框传给系统是否让追踪更准。
    private let usesFocusRectForTracking = true
    /// 关掉后曝光只在开始追踪时设一次，用来排查曝光跟随是否干扰追踪。
    private let exposureFollowsTrackedSubject = true
    private var trackingStartedAt: CFAbsoluteTime = 0
    /// nil 表示本次追踪还没收到过 metadata；只在主体出现、消失时打日志。
    private var trackedSubjectPresent: Bool?
    private var lastExposureUpdate: CFAbsoluteTime = 0
    private var lastExposurePoint = CGPoint(x: 0.5, y: 0.5)
    private var deviceInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var mode: CaptureMode = .photo
    private var recordingContinuation: CheckedContinuation<URL, Error>?
    private var position: AVCaptureDevice.Position = .back
    private var isConfigured = false
    private var wantsToRun = false
    private var eventHandler: (@Sendable (CameraEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var aperture: ApertureSetting = .auto
    private var apertureObservation: NSKeyValueObservation?
    private var livePhotoEnabled = false

    private final class PendingCapture {
        let id: Int64
        let continuation: CheckedContinuation<CapturedPhoto, Error>
        var result: Result<CapturedPhoto, Error>?
        var livePhotoMovieURL: URL?

        init(id: Int64, continuation: CheckedContinuation<CapturedPhoto, Error>) {
            self.id = id
            self.continuation = continuation
        }
    }

    private var pendingCapture: PendingCapture?

    override init() {
        super.init()
        installSessionObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func setEventHandler(_ handler: @escaping @Sendable (CameraEvent) -> Void) {
        sessionQueue.async { [self] in
            eventHandler = handler
        }
    }

    func prepare() async throws {
        guard await requestAccess() else { throw CameraError.notAuthorized }
        try await onSessionQueue { [self] in
            if !isConfigured {
                try configureSession(for: position)
            }
        }
    }

    func start() async throws -> CameraState {
        try await onSessionQueue { [self] in
            guard isConfigured else { throw CameraError.configurationFailed }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                throw CameraError.notAuthorized
            }
            wantsToRun = true
            guard !session.isInterrupted else { throw CameraError.interrupted }
            if !session.isRunning {
                session.startRunning()
            }
            guard session.isRunning else { throw CameraError.unavailable }
            return makeState()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            wantsToRun = false
            endFocusTrackingIfNeeded(reason: "session stop")
            if let pending = pendingCapture {
                finishCapture(id: pending.id, result: .failure(CameraError.interrupted))
            }
            if movieOutput.isRecording {
                movieOutput.stopRecording()
            }
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func currentState() async throws -> CameraState {
        try await onSessionQueue { [self] in makeState() }
    }

    func switchCamera() async throws -> CameraState {
        try await onSessionQueue { [self] in
            guard pendingCapture == nil, !movieOutput.isRecording else { throw CameraError.busy }
            let previous = position
            let next: AVCaptureDevice.Position = previous == .back ? .front : .back
            let restart = wantsToRun
            if session.isRunning {
                session.stopRunning()
            }
            do {
                try configureSession(for: next)
            } catch {
                try? configureSession(for: previous)
                if restart, isConfigured {
                    session.startRunning()
                }
                throw error
            }
            if restart {
                session.startRunning()
            }
            return makeState()
        }
    }

    func setMode(_ newMode: CaptureMode) async throws -> CameraState {
        if newMode == .video {
            _ = await requestMicrophoneAccess()
        }
        return try await onSessionQueue { [self] in
            guard pendingCapture == nil, !movieOutput.isRecording else { throw CameraError.busy }
            guard newMode != mode else { return makeState() }
            let previous = mode
            mode = newMode
            do {
                try configureSession(for: position)
            } catch {
                mode = previous
                try? configureSession(for: position)
                throw error
            }
            if wantsToRun, !session.isRunning {
                session.startRunning()
            }
            return makeState()
        }
    }

    /// 返回录制完成的临时 .mov 文件；调用 `stopRecording()` 或会话中断都会结束录制。
    func recordVideo(rotationAngle: CGFloat, mirrored: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                guard mode == .video, recordingContinuation == nil, !movieOutput.isRecording else {
                    continuation.resume(throwing: CameraError.busy)
                    return
                }
                guard session.isRunning, !session.isInterrupted,
                      let connection = movieOutput.connection(with: .video) else {
                    continuation.resume(throwing: CameraError.unavailable)
                    return
                }
                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = mirrored
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TestCamer-\(UUID().uuidString).mov")
                recordingContinuation = continuation
                movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    func stopRecording() {
        sessionQueue.async { [self] in
            if movieOutput.isRecording {
                movieOutput.stopRecording()
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let succeeded: Bool
        if let error {
            let finished = (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
            succeeded = finished == true
        } else {
            succeeded = true
        }
        sessionQueue.async { [self] in
            guard let continuation = recordingContinuation else { return }
            recordingContinuation = nil
            if succeeded {
                continuation.resume(returning: outputFileURL)
            } else {
                try? FileManager.default.removeItem(at: outputFileURL)
                continuation.resume(throwing: error ?? CameraError.recordingFailed)
            }
        }
    }

    func setZoomFactor(_ factor: CGFloat) {
        sessionQueue.async { [self] in
            guard pendingCapture == nil, let device = deviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let minZoom = device.minAvailableVideoZoomFactor
                let maxZoom = min(device.maxAvailableVideoZoomFactor, 8)
                device.videoZoomFactor = min(max(factor, minZoom), maxZoom)
                eventHandler?(.ready(makeState()))
            } catch {
                print("[Camera] zoom rejected: \(error.localizedDescription)")
            }
        }
    }

    /// 实况照片的声音来自麦克风，所以开启时在照片模式下也挂上音频输入。
    func setLivePhotoEnabled(_ enabled: Bool) async throws -> CameraState {
        if enabled {
            _ = await requestMicrophoneAccess()
        }
        return try await onSessionQueue { [self] in
            guard pendingCapture == nil, !movieOutput.isRecording else { throw CameraError.busy }
            guard !enabled || photoOutput.isLivePhotoCaptureSupported else { throw CameraError.livePhotoUnsupported }
            livePhotoEnabled = enabled
            session.beginConfiguration()
            updateAudioInput()
            session.commitConfiguration()
            return makeState()
        }
    }

    /// 手动光圈走"光圈优先"：锁定 𝑓 值，快门和 ISO 仍由自动曝光维持画面亮度。
    func setAperture(_ setting: ApertureSetting) async throws -> CameraState {
        try await onSessionQueue { [self] in
            guard pendingCapture == nil, let device = deviceInput?.device else { throw CameraError.busy }
            guard !apertureStops(for: device).isEmpty else { throw CameraError.apertureUnsupported }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let previous = aperture
            aperture = setting
            guard applyExposureMode(to: device) else {
                aperture = previous
                _ = applyExposureMode(to: device)
                throw CameraError.apertureUnsupported
            }
            return makeState()
        }
    }

    /// 点选追踪：只把点交给系统，对焦区域用系统按这个点给的默认大小。
    func startFocusTracking(at devicePoint: CGPoint) async throws -> CameraState {
        try await startFocusTracking(in: CGRect(origin: devicePoint, size: .zero))
    }

    /// 框选追踪：系统只跟踪 focusPointOfInterest 处的主体，所以用框中心选主体；
    /// 支持 focusRectOfInterest 时把整个框也传进去，作为主体范围的提示。
    /// 正在追踪时再调用会换成新目标。主体移动、离开再回到画面都会继续跟踪。
    func startFocusTracking(in deviceRect: CGRect) async throws -> CameraState {
        try await onSessionQueue { [self] in
            guard pendingCapture == nil, let device = deviceInput?.device else { throw CameraError.busy }
            guard #available(iOS 27.0, *), supportsFocusTracking(device),
                  device.isFocusPointOfInterestSupported else { throw CameraError.focusTrackingUnsupported }
            let box = deviceRect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            // 点选时传进来的是零尺寸矩形，求交集可能得到 null，中心点要从原矩形取。
            let source = box.isNull ? deviceRect.standardized : box
            let center = CGPoint(x: min(max(source.midX, 0), 1), y: min(max(source.midY, 0), 1))
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let isRetarget = isFocusTracking
            if isRetarget {
                // 不先停掉旧的追踪，系统会继续跟原来的主体。
                device.isContinuousAutoFocusTrackingEnabled = false
                device.focusMode = .continuousAutoFocus
            }
            // 跟踪期间 focusPointOfInterest 不会更新，主体区域变化时重设对焦会把目标拉回起点。
            device.isSubjectAreaChangeMonitoringEnabled = false
            device.isContinuousAutoFocusTrackingEnabled = true
            let region = applyFocusRegion(box, center: center, to: device)
            device.focusMode = .continuousAutoFocus
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = center
                _ = applyExposureMode(to: device)
            }
            isFocusTracking = true
            trackingStartedAt = CFAbsoluteTimeGetCurrent()
            trackedSubjectPresent = nil
            lastExposureUpdate = trackingStartedAt
            lastExposurePoint = center
            print("[Track] start\(isRetarget ? " (retarget)" : "") box=\(box.isNull ? "none" : box.trackLogDescription) focus=\(region) exposureFollows=\(exposureFollowsTrackedSubject)")
            return makeState()
        }
    }

    func stopFocusTracking() async throws -> CameraState {
        try await onSessionQueue { [self] in
            if let device = deviceInput?.device {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if isFocusTracking {
                    print("[Track] stop (user cancel)")
                }
                resetFocusAfterTracking(on: device)
            }
            return makeState()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard #available(iOS 27.0, *), isFocusTracking else { return }
        let tracked = metadataObjects.first { $0.type == .focusTrackedObject }
        let bounds = tracked?.bounds
        logTrackedSubjectChange(bounds)
        if let bounds {
            followExposure(to: bounds)
        }
        eventHandler?(.focusTrackedObject(bounds))
    }

    /// 只在主体首次出现、丢失、回来时打日志，避免每帧刷屏。
    @available(iOS 27.0, *)
    private func logTrackedSubjectChange(_ bounds: CGRect?) {
        let present = bounds != nil
        guard present != trackedSubjectPresent else { return }
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - trackingStartedAt) * 1000)
        let acquired = deviceInput?.device.isContinuousAutoFocusTrackingSubjectAcquired ?? false
        let event: String
        switch (trackedSubjectPresent, present) {
        case (nil, true):
            event = "first subject"
        case (nil, false):
            event = "no subject yet"
        case (_, true):
            event = "subject back"
        case (_, false):
            event = "subject lost"
        }
        print("[Track] \(event) at +\(elapsed)ms bounds=\(bounds?.trackLogDescription ?? "nil") acquired=\(acquired)")
        trackedSubjectPresent = present
    }

    /// 追踪期间让测光点跟着主体走；限频并忽略小幅移动，避免亮度来回闪。
    private func followExposure(to bounds: CGRect) {
        guard exposureFollowsTrackedSubject, pendingCapture == nil,
              let device = deviceInput?.device, device.isExposurePointOfInterestSupported else { return }
        let point = CGPoint(x: min(max(bounds.midX, 0), 1), y: min(max(bounds.midY, 0), 1))
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastExposureUpdate >= 0.3,
              hypot(point.x - lastExposurePoint.x, point.y - lastExposurePoint.y) >= 0.03 else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.exposurePointOfInterest = point
            _ = applyExposureMode(to: device)
            lastExposureUpdate = now
            lastExposurePoint = point
            print("[Track] exposure -> \(String(format: "(%.3f, %.3f)", point.x, point.y))")
        } catch {
            print("[Track] exposure rejected: \(error.localizedDescription)")
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [self] in
            guard pendingCapture == nil, let device = deviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let wasTracking = isFocusTracking
                disableFocusTracking(on: device)
                if wasTracking {
                    print("[Track] stop (tap to focus)")
                    eventHandler?(.ready(makeState()))
                }
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    if !applyManualAperture(to: device), device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
            } catch {
                print("[Camera] focus rejected: \(error.localizedDescription)")
            }
        }
    }

    func capturePhoto(
        flashMode: AVCaptureDevice.FlashMode,
        rotationAngle: CGFloat,
        mirrored: Bool
    ) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                guard pendingCapture == nil else {
                    continuation.resume(throwing: CameraError.busy)
                    return
                }
                guard session.isRunning, !session.isInterrupted,
                      let connection = photoOutput.connection(with: .video) else {
                    continuation.resume(throwing: CameraError.unavailable)
                    return
                }

                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = mirrored
                }

                let settings = AVCapturePhotoSettings()
                if deviceInput?.device.hasFlash == true,
                   photoOutput.supportedFlashModes.contains(flashMode) {
                    settings.flashMode = flashMode
                } else {
                    settings.flashMode = .off
                }
                settings.photoQualityPrioritization = .quality
                if isLivePhotoActive {
                    settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("TestCamer-Live-\(UUID().uuidString).mov")
                    if let dimensions = livePhotoDimensions() {
                        settings.maxPhotoDimensions = dimensions
                    }
                } else if photoOutput.maxPhotoDimensions.width > 0 {
                    settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                }

                let id = settings.uniqueID
                pendingCapture = PendingCapture(id: id, continuation: continuation)
                photoOutput.capturePhoto(with: settings, delegate: self)

                sessionQueue.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self, self.pendingCapture?.id == id else { return }
                    if self.session.isRunning {
                        self.session.stopRunning()
                    }
                    self.finishCapture(id: id, result: .failure(CameraError.captureTimedOut))
                    if self.wantsToRun, !self.session.isInterrupted {
                        self.session.startRunning()
                        self.eventHandler?(.ready(self.makeState()))
                    }
                }
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let id = photo.resolvedSettings.uniqueID
        let data = error == nil ? photo.fileDataRepresentation() : nil
        sessionQueue.async { [self] in
            guard let pending = pendingCapture, pending.id == id else { return }
            if let error {
                pending.result = .failure(error)
            } else if let data {
                pending.result = .success(CapturedPhoto(jpegData: data))
            } else {
                pending.result = .failure(CameraError.captureFailed)
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        let id = resolvedSettings.uniqueID
        sessionQueue.async { [self] in
            guard error == nil, let pending = pendingCapture, pending.id == id else {
                try? FileManager.default.removeItem(at: outputFileURL)
                if let error {
                    print("[Camera] live photo movie failed: \(error.localizedDescription)")
                }
                return
            }
            pending.livePhotoMovieURL = outputFileURL
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        sessionQueue.async { [self] in
            let id = resolvedSettings.uniqueID
            guard let pending = pendingCapture, pending.id == id else { return }
            if let error {
                finishCapture(id: id, result: .failure(error))
            } else {
                finishCapture(id: id, result: pending.result ?? .failure(CameraError.captureFailed))
            }
        }
    }

    private func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private func onSessionQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureSession(for target: AVCaptureDevice.Position) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        isConfigured = false
        let device: AVCaptureDevice
        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.sessionPreset = mode == .photo ? .photo : .high

            if let deviceInput {
                session.removeInput(deviceInput)
                self.deviceInput = nil
            }
            if !session.outputs.contains(photoOutput) {
                guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed }
                session.addOutput(photoOutput)
            }
            photoOutput.maxPhotoQualityPrioritization = .quality

            guard let camera = camera(for: target),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
                throw CameraError.unavailable
            }
            session.addInput(input)
            deviceInput = input
            device = camera

            try configureMovieRecording()
            updateAudioInput()
            photoOutput.isLivePhotoCaptureEnabled = mode == .photo && photoOutput.isLivePhotoCaptureSupported
            if !session.outputs.contains(metadataOutput), session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
            }
        }

        try selectApertureCapableVideoFormat(for: device)
        updateMetadataObjectTypes(for: device)

        // activeFormat 跟随 sessionPreset 变化，需等提交配置后再选照片尺寸。
        if let preferred = preferredPhotoDimensions(for: device) {
            photoOutput.maxPhotoDimensions = preferred
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if isFocusTracking {
            print("[Track] stop (camera reconfigured)")
        }
        disableFocusTracking(on: device)
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        _ = applyExposureMode(to: device)
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        observeLensAperture(of: device)

        position = target
        isConfigured = true
        print("[Camera] configured \(device.localizedName), mode=\(mode), photo=\(photoOutput.maxPhotoDimensions.width)x\(photoOutput.maxPhotoDimensions.height), apertures=\(apertureStops(for: device)), apertureRange=\(apertureRangeDescription(for: device)), focusTracking=\(supportsFocusTracking(device))")
    }

    private func apertureRangeDescription(for device: AVCaptureDevice) -> String {
        guard #available(iOS 27.0, *) else { return "n/a (iOS < 27), current=ƒ\(device.lensAperture)" }
        let format = device.activeFormat
        return "ƒ\(format.minLensAperture)~ƒ\(format.maxLensAperture), current=ƒ\(device.lensAperture)"
    }

    private func supportsFocusTracking(_ device: AVCaptureDevice) -> Bool {
        guard #available(iOS 27.0, *) else { return false }
        return device.activeFormat.isContinuousAutoFocusTrackingSupported
            && metadataOutput.metadataObjectTypes.contains(.focusTrackedObject)
    }

    /// 不订阅 focusTrackedObject 时系统不会启动跟踪；该类型随 activeFormat 出现或消失，须在格式确定后再设置。
    private func updateMetadataObjectTypes(for device: AVCaptureDevice) {
        guard #available(iOS 27.0, *), session.outputs.contains(metadataOutput) else { return }
        let available = device.activeFormat.isContinuousAutoFocusTrackingSupported
            && metadataOutput.availableMetadataObjectTypes.contains(.focusTrackedObject)
        metadataOutput.metadataObjectTypes = available ? [.focusTrackedObject] : []
    }

    /// 调用方需已持有 `lockForConfiguration`。
    private func disableFocusTracking(on device: AVCaptureDevice) {
        isFocusTracking = false
        guard #available(iOS 27.0, *), device.isContinuousAutoFocusTrackingEnabled else { return }
        device.isContinuousAutoFocusTrackingEnabled = false
    }

    /// 调用方需已持有 `lockForConfiguration`。
    private func resetFocusAfterTracking(on device: AVCaptureDevice) {
        disableFocusTracking(on: device)
        let center = CGPoint(x: 0.5, y: 0.5)
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = center
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = center
            _ = applyExposureMode(to: device)
        }
    }

    /// 离开相机页、进后台或被系统打断时结束追踪，回来后界面和设备状态一致。
    private func endFocusTrackingIfNeeded(reason: String) {
        guard isFocusTracking else { return }
        print("[Track] stop (\(reason))")
        guard let device = deviceInput?.device else {
            isFocusTracking = false
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            resetFocusAfterTracking(on: device)
        } catch {
            isFocusTracking = false
            print("[Track] stop rejected: \(error.localizedDescription)")
        }
    }

    /// 调用方需已持有 `lockForConfiguration`；返回实际设置的对焦区域，写进日志方便对比。
    private func applyFocusRegion(_ box: CGRect, center: CGPoint, to device: AVCaptureDevice) -> String {
        if usesFocusRectForTracking, !box.isNull, !box.isEmpty {
            if #available(iOS 26.0, *), device.isFocusRectOfInterestSupported {
                let minSize = device.minFocusRectOfInterestSize
                let size = CGSize(
                    width: min(max(box.width, minSize.width), 1),
                    height: min(max(box.height, minSize.height), 1)
                )
                let origin = CGPoint(
                    x: min(max(center.x - size.width / 2, 0), 1 - size.width),
                    y: min(max(center.y - size.height / 2, 0), 1 - size.height)
                )
                let region = CGRect(origin: origin, size: size)
                device.focusRectOfInterest = region
                let minText = String(format: "%.3f×%.3f", minSize.width, minSize.height)
                return "rect \(region.trackLogDescription) min=\(minText)"
            }
        }
        device.focusPointOfInterest = center
        return "point " + String(format: "(%.3f, %.3f)", center.x, center.y)
    }

    /// 视频预设选出的格式不一定带可变光圈；此时换成尺寸最接近、支持光圈且能跑 30fps 的格式。
    private func selectApertureCapableVideoFormat(for device: AVCaptureDevice) throws {
        guard mode == .video, #available(iOS 27.0, *), apertureStops(for: device).isEmpty else { return }
        let current = device.activeFormat
        let subtype = CMFormatDescriptionGetMediaSubType(current.formatDescription)
        let currentDims = CMVideoFormatDescriptionGetDimensions(current.formatDescription)
        let currentArea = Int64(currentDims.width) * Int64(currentDims.height)
        func areaDistance(_ format: AVCaptureDevice.Format) -> Int64 {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return abs(Int64(dims.width) * Int64(dims.height) - currentArea)
        }
        let candidates = device.formats.filter { format in
            format.recommendedLensApertureStops.count > 1
                && CMFormatDescriptionGetMediaSubType(format.formatDescription) == subtype
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        func rank(_ format: AVCaptureDevice.Format) -> (Int, Int64) {
            (format.isContinuousAutoFocusTrackingSupported ? 0 : 1, areaDistance(format))
        }
        guard let best = candidates.min(by: { rank($0) < rank($1) }) else {
            print("[Camera] no aperture-capable video format on \(device.localizedName)")
            return
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = best
        let frameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        print("[Camera] switched to aperture-capable video format \(dims.width)x\(dims.height)")
    }

    private func apertureStops(for device: AVCaptureDevice) -> [Float] {
        guard #available(iOS 27.0, *) else { return [] }
        let stops = device.activeFormat.recommendedLensApertureStops
        return stops.count > 1 ? stops : []
    }

    /// 调用方需已持有 `lockForConfiguration`；返回 false 表示当前格式不接受该光圈设置。
    private func applyExposureMode(to device: AVCaptureDevice) -> Bool {
        if case .manual = aperture, applyManualAperture(to: device) {
            return true
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        return aperture == .auto
    }

    private func applyManualAperture(to device: AVCaptureDevice) -> Bool {
        guard #available(iOS 27.0, *), case .manual(let value) = aperture,
              !apertureStops(for: device).isEmpty else { return false }
        let format = device.activeFormat
        let target = min(max(value, format.minLensAperture), format.maxLensAperture)
        guard format.supportsExposureModeCustom(
            lensAperture: target,
            duration: AVCaptureDevice.autoExposureDuration,
            iso: AVCaptureDevice.autoISO
        ) else { return false }
        device.setExposureModeCustom(
            lensAperture: target,
            duration: AVCaptureDevice.autoExposureDuration,
            iso: AVCaptureDevice.autoISO,
            completionHandler: nil
        )
        return true
    }

    private func observeLensAperture(of device: AVCaptureDevice) {
        apertureObservation = device.observe(\.lensAperture, options: [.new]) { [weak self] device, _ in
            guard let self else { return }
            let value = device.lensAperture
            self.sessionQueue.async {
                guard self.deviceInput?.device.uniqueID == device.uniqueID else { return }
                self.eventHandler?(.lensApertureChanged(value))
            }
        }
    }

    private func configureMovieRecording() throws {
        guard mode == .video else {
            if session.outputs.contains(movieOutput) {
                session.removeOutput(movieOutput)
            }
            return
        }

        if !session.outputs.contains(movieOutput) {
            guard session.canAddOutput(movieOutput) else { throw CameraError.configurationFailed }
            session.addOutput(movieOutput)
        }
        if let connection = movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
    }

    /// 需在 begin/commitConfiguration 之间调用。
    private func updateAudioInput() {
        let wantsAudio = mode == .video || (mode == .photo && livePhotoEnabled)
        guard wantsAudio else {
            if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            return
        }
        if audioInput == nil,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let microphone = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
    }

    private func camera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    private func preferredPhotoDimensions(for device: AVCaptureDevice) -> CMVideoDimensions? {
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions.sorted {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        return dimensions.last
    }

    private func makeState() -> CameraState {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        return CameraState(
            deviceID: deviceInput?.device.uniqueID ?? "",
            isFront: position == .front,
            hasFlash: deviceInput?.device.hasFlash ?? false,
            zoomFactor: deviceInput?.device.videoZoomFactor ?? 1,
            isRunning: session.isRunning && !session.isInterrupted,
            mode: mode,
            isRecording: movieOutput.isRecording,
            lensAperture: deviceInput?.device.lensAperture ?? 0,
            apertureStops: deviceInput.map { apertureStops(for: $0.device) } ?? [],
            aperture: aperture,
            isLivePhotoSupported: mode == .photo && photoOutput.isLivePhotoCaptureSupported,
            isLivePhotoEnabled: isLivePhotoActive,
            isFocusTrackingSupported: deviceInput.map { supportsFocusTracking($0.device) } ?? false,
            isFocusTracking: isFocusTracking
        )
    }

    private func finishCapture(id: Int64, result: Result<CapturedPhoto, Error>) {
        guard let pending = pendingCapture, pending.id == id else { return }
        pendingCapture = nil
        let movieURL = pending.livePhotoMovieURL
        if case .failure = result, let movieURL {
            try? FileManager.default.removeItem(at: movieURL)
        }
        pending.continuation.resume(with: result.map { photo in
            var photo = photo
            photo.livePhotoMovieURL = movieURL
            return photo
        })
    }

    private var isLivePhotoActive: Bool {
        mode == .photo && livePhotoEnabled && photoOutput.isLivePhotoCaptureEnabled
    }

    /// 实况照片不一定支持 48MP 输出，限制在 12MP 以内以保证照片与视频能配对生成。
    private func livePhotoDimensions() -> CMVideoDimensions? {
        guard let device = deviceInput?.device else { return nil }
        let limit = Int64(4032 * 3024)
        return device.activeFormat.supportedMaxPhotoDimensions
            .filter { Int64($0.width) * Int64($0.height) <= limit
                && $0.width <= photoOutput.maxPhotoDimensions.width
                && $0.height <= photoOutput.maxPhotoDimensions.height }
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
    }

    private func installSessionObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                if let pending = self.pendingCapture {
                    self.finishCapture(id: pending.id, result: .failure(CameraError.interrupted))
                }
                self.endFocusTrackingIfNeeded(reason: "interrupted")
                self.eventHandler?(.interrupted)
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                guard self.wantsToRun else { return }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.eventHandler?(.ready(self.makeState()))
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let reset = error?.code == AVError.Code.mediaServicesWereReset.rawValue
            let message = error?.localizedDescription ?? CameraError.unavailable.localizedDescription
            self.sessionQueue.async {
                print("[Camera] runtime error: \(message)")
                if let pending = self.pendingCapture {
                    self.finishCapture(id: pending.id, result: .failure(CameraError.interrupted))
                }
                if reset, self.wantsToRun {
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    self.eventHandler?(.ready(self.makeState()))
                } else {
                    self.eventHandler?(.issue(message))
                }
            }
        })
        observers.append(center.addObserver(
            forName: .AVCaptureDeviceSubjectAreaDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                guard self.pendingCapture == nil, !self.isFocusTracking,
                      let device = self.deviceInput?.device else { return }
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    _ = self.applyExposureMode(to: device)
                } catch {
                    print("[Camera] restore focus rejected: \(error.localizedDescription)")
                }
            }
        })
    }
}

extension CGRect {
    /// `[Track]` 日志里的归一化矩形，保留三位小数方便对比。
    var trackLogDescription: String {
        String(format: "(%.3f, %.3f, %.3f×%.3f)", origin.x, origin.y, width, height)
    }
}
