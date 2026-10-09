import AVFoundation
import UIKit

@MainActor
final class CameraViewController: UIViewController {
    private let camera = CameraManager()
    private var flashMode: AVCaptureDevice.FlashMode = .off
    private var captureMode: CaptureMode = .photo
    private var cameraState: CameraState? {
        didSet {
            syncApertureFromState()
            updateFocusTrackingUI()
        }
    }
    private var liveAperture: Float = 0
    private var apertureSetting: ApertureSetting = .auto
    private var apertureRequestID = 0
    private var isAperturePanelShown = false
    private var latestMedia: CapturedMedia?
    private var lastZoomFactor: CGFloat = 1
    private var isCapturing = false
    private var isRecording = false
    private var isStarting = false
    private var isSwitching = false
    private var isChangingMode = false
    private var isScreenVisible = false
    private var recordingTimerTask: Task<Void, Never>?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var coordinatedDeviceID: String?

    private let previewView = PreviewView()
    private let dimView = UIView()
    private let statusLabel = UILabel()
    private let recordingLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let flashButton = UIButton(type: .system)
    private let liveButton = UIButton(type: .system)
    private let switchButton = UIButton(type: .system)
    private let thumbnailButton = UIButton(type: .custom)
    private let thumbnailVideoBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private let shutterButton = UIButton(type: .custom)
    private let shutterInner = UIView()
    private var shutterInnerWidth: NSLayoutConstraint?
    private var shutterInnerHeight: NSLayoutConstraint?
    private let modeControl = UISegmentedControl(items: ["照片", "视频"])
    private let cameraControls = UIStackView()
    private let focusIndicator = UIView()
    private let apertureButton = UIButton(type: .system)
    private let apertureIndicator = UIButton(type: .system)
    private let aperturePanel = ApertureControlView()
    /// 追踪期间显示在顶部：「追踪对焦 ×」，目标丢失时换成「目标丢失 ×」。
    private let trackingBadge = UIButton(type: .system)
    /// 顶部的「追踪对焦」开关：打开后轻点主体开始追踪，关着时轻点是普通对焦。
    private let trackingToggle = UIButton(type: .system)
    private var trackingToggleAfterLive: NSLayoutConstraint?
    private var trackingToggleAfterFlash: NSLayoutConstraint?
    private var isTrackingModeOn = UserDefaults.standard.bool(forKey: TrackingUI.modeDefaultsKey) {
        didSet { UserDefaults.standard.set(isTrackingModeOn, forKey: TrackingUI.modeDefaultsKey) }
    }
    /// 系统样式的黄色细线框：锁定中半透明，锁定后不透明。
    private let trackingFrame = TrackingFrameView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    private var trackingPhase: TrackingPhase = .idle
    /// 每次点选或取消都会加一，用来丢弃过期的异步结果。
    private var trackingRequestID = 0
    private var trackingTimeoutTask: Task<Void, Never>?
    private var trackingLostTask: Task<Void, Never>?
    private let focusHintLabel = PaddedLabel()
    private var focusHintTask: Task<Void, Never>?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewView.previewLayer.session = camera.session
        previewView.previewLayer.videoGravity = .resizeAspectFill
        setupUI()
        camera.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleCameraEvent(event)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        updateShutterAppearance(animated: false)
        updateControlAvailability()
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isScreenVisible = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await startCamera() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isScreenVisible = false
        camera.stop()
        cameraState = nil
        updateControlAvailability()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { _ in
            self.updatePreviewOrientation()
        }
    }
}

// MARK: - Camera lifecycle

private extension CameraViewController {
    func startCamera() async {
        guard isScreenVisible, !isStarting, !isCapturing, !isSwitching, !isChangingMode,
              UIApplication.shared.applicationState != .background else { return }
        isStarting = true
        statusLabel.isHidden = false
        statusLabel.text = "正在开启相机…"
        retryButton.isHidden = true
        updateControlAvailability()
        defer {
            isStarting = false
            updateControlAvailability()
        }
        do {
            try await camera.prepare()
            guard isScreenVisible, UIApplication.shared.applicationState != .background else { return }
            cameraState = try await camera.start()
            guard isScreenVisible, UIApplication.shared.applicationState != .background else {
                camera.stop()
                return
            }
            updatePreviewOrientation()
            statusLabel.isHidden = true
        } catch {
            showCameraUnavailable(error)
        }
    }

    @objc func appDidBecomeActive() {
        Task { await startCamera() }
    }

    @objc func appDidEnterBackground() {
        camera.stop()
        cameraState = nil
        updateControlAvailability()
    }

    @objc func retryCameraTapped() {
        Task { await startCamera() }
    }

    func handleCameraEvent(_ event: CameraEvent) {
        guard isScreenVisible, UIApplication.shared.applicationState != .background else { return }
        switch event {
        case .ready(let state):
            cameraState = state
            if state.isRunning, !isCapturing {
                statusLabel.isHidden = true
                retryButton.isHidden = true
            }
            updatePreviewOrientation()
        case .lensApertureChanged(let value):
            liveAperture = value
            updateApertureUI()
            return
        case .focusTrackedObject(let rect):
            handleTrackedObject(metadataRect: rect)
            return
        case .interrupted:
            cameraState = nil
            statusLabel.isHidden = false
            statusLabel.text = "相机暂时被系统中断，恢复后可继续拍摄。"
        case .issue(let message):
            cameraState = nil
            statusLabel.isHidden = false
            statusLabel.text = message
            retryButton.isHidden = false
        }
        updateControlAvailability()
    }

    func showCameraUnavailable(_ error: Error) {
        statusLabel.isHidden = false
        statusLabel.text = error.localizedDescription
        cameraState = nil
        retryButton.isHidden = false
        updateControlAvailability()
        if let cameraError = error as? CameraError, cameraError == .notAuthorized {
            presentSettingsAlert()
        }
    }

    func presentSettingsAlert() {
        let alert = UIAlertController(
            title: "需要相机权限",
            message: "请在设置中允许 TestCamer 访问相机。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "去设置", style: .default) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
        present(alert, animated: true)
    }
}

// MARK: - Actions

private extension CameraViewController {
    var isBusy: Bool {
        isCapturing || isRecording || isStarting || isSwitching || isChangingMode
    }

    @objc func shutterTapped() {
        switch captureMode {
        case .photo:
            capturePhoto()
        case .video:
            if isRecording {
                camera.stopRecording()
            } else {
                startRecording()
            }
        }
    }

    func capturePhoto() {
        guard !isBusy, cameraState?.isRunning == true else { return }
        isCapturing = true
        retryButton.isHidden = true
        updateControlAvailability()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flashScreen()

        let rotation = captureRotationAngle
        let mirrored = cameraState?.isFront == true
        Task {
            defer {
                isCapturing = false
                updateControlAvailability()
            }
            do {
                let photo = try await camera.capturePhoto(
                    flashMode: flashMode,
                    rotationAngle: rotation,
                    mirrored: mirrored
                )
                guard let image = UIImage(data: photo.jpegData) else { throw CameraError.captureFailed }
                if let movieURL = photo.livePhotoMovieURL {
                    do {
                        let photoURL = try CapturedMedia.writeTemporaryPhoto(photo.jpegData)
                        setLatestMedia(.livePhoto(photoURL: photoURL, movieURL: movieURL, image: image))
                    } catch {
                        try? FileManager.default.removeItem(at: movieURL)
                        setLatestMedia(.photo(data: photo.jpegData, image: image))
                    }
                } else {
                    setLatestMedia(.photo(data: photo.jpegData, image: image))
                }
            } catch {
                cameraState = try? await camera.currentState()
                presentError(error)
            }
        }
    }

    func startRecording() {
        guard !isBusy, cameraState?.isRunning == true else { return }
        isRecording = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        updateShutterAppearance()
        startRecordingTimer()
        updateControlAvailability()

        let rotation = captureRotationAngle
        let mirrored = cameraState?.isFront == true
        Task {
            defer {
                isRecording = false
                stopRecordingTimer()
                updateShutterAppearance()
                updateControlAvailability()
            }
            do {
                let url = try await camera.recordVideo(rotationAngle: rotation, mirrored: mirrored)
                let thumbnail = await CapturedMedia.videoThumbnail(for: url)
                setLatestMedia(.video(url: url, thumbnail: thumbnail))
            } catch {
                presentError(error)
            }
        }
    }

    @objc func modeChanged() {
        let newMode: CaptureMode = modeControl.selectedSegmentIndex == 0 ? .photo : .video
        guard newMode != captureMode, !isBusy else {
            modeControl.selectedSegmentIndex = captureMode == .photo ? 0 : 1
            return
        }
        isChangingMode = true
        updateControlAvailability()
        UISelectionFeedbackGenerator().selectionChanged()
        Task {
            defer {
                isChangingMode = false
                updateControlAvailability()
            }
            do {
                cameraState = try await camera.setMode(newMode)
                captureMode = newMode
                lastZoomFactor = cameraState?.zoomFactor ?? 1
                updatePreviewOrientation()
                updateShutterAppearance()
            } catch {
                modeControl.selectedSegmentIndex = captureMode == .photo ? 0 : 1
                cameraState = try? await camera.currentState()
                presentError(error)
            }
        }
    }

    @objc func thumbnailTapped() {
        guard let media = latestMedia, !isCapturing, !isRecording else { return }
        present(MediaViewerController(media: media), animated: true)
    }

    @objc func switchTapped() {
        guard !isBusy else { return }
        isSwitching = true
        updateControlAvailability()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            defer {
                isSwitching = false
                updateControlAvailability()
            }
            do {
                cameraState = try await camera.switchCamera()
                lastZoomFactor = cameraState?.zoomFactor ?? 1
                updatePreviewOrientation()
            } catch {
                cameraState = try? await camera.currentState()
                presentError(error)
            }
        }
    }

    @objc func flashTapped() {
        switch flashMode {
        case .off:
            flashMode = .on
        case .on:
            flashMode = .auto
        default:
            flashMode = .off
        }
        updateFlashButton()
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !isCapturing, !isSwitching, !isChangingMode, cameraState?.isRunning == true else { return }
        if gesture.state == .began {
            lastZoomFactor = cameraState?.zoomFactor ?? 1
        }
        camera.setZoomFactor(lastZoomFactor * gesture.scale)
    }

    @objc func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        guard !isCapturing, !isSwitching, !isChangingMode, cameraState?.isRunning == true else { return }
        let location = gesture.location(in: previewView)
        if isTrackingModeOn, cameraState?.isFocusTrackingSupported == true {
            startTracking(at: location)
        } else {
            tapFocus(at: location)
        }
    }

    /// 普通单击对焦；万一还在追踪，先取消。
    func tapFocus(at location: CGPoint) {
        let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: location)
        resetTrackingUI()
        camera.focus(at: devicePoint)
        showFocusIndicator(at: location)
    }

    /// 轻点开始追踪点下的主体；正在追踪时会换成新目标。
    func startTracking(at location: CGPoint) {
        trackingRequestID += 1
        let requestID = trackingRequestID
        let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: location)
        let side = TrackingUI.tapBoxSide
        let box = CGRect(x: location.x - side / 2, y: location.y - side / 2, width: side, height: side)
        if isAperturePanelShown {
            setAperturePanelShown(false)
        }
        hideFocusHint()
        trackingFrame.setStyle(.locking, animated: false)
        moveTrackingFrame(to: box, duration: 0)
        setTrackingPhase(.locking(requestID: requestID, box: box, startedAt: Date()))
        trackingTimeoutTask?.cancel()
        trackingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: TrackingUI.lockTimeout)
            guard !Task.isCancelled else { return }
            self?.handleLockTimeout(requestID: requestID)
        }
        Task {
            do {
                let state = try await camera.startFocusTracking(at: devicePoint)
                if requestID == trackingRequestID {
                    cameraState = state
                } else if let latest = try? await camera.currentState() {
                    // 等待期间用户已经取消或关掉开关，以相机最新状态为准。
                    cameraState = latest
                }
            } catch {
                if let latest = try? await camera.currentState() {
                    cameraState = latest
                }
                guard requestID == trackingRequestID else { return }
                resetTrackingUI()
                if let cameraError = error as? CameraError, cameraError == .focusTrackingUnsupported {
                    showFocusHint("当前镜头不支持追踪对焦")
                } else {
                    presentError(error)
                }
            }
        }
    }

    /// 等了一段时间系统还没锁定主体（比如点的是一面白墙），退回普通对焦。
    func handleLockTimeout(requestID: Int) {
        guard case .locking(let id, let box, _) = trackingPhase, id == requestID else { return }
        print("[Track] lock timeout, fall back to tap focus")
        let center = CGPoint(x: box.midX, y: box.midY)
        resetTrackingUI()
        camera.focus(at: previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: center))
        showFocusIndicator(at: center)
        showFocusHint("未能锁定目标，请重新点选")
    }

    @objc func cancelFocusTrackingTapped() {
        UISelectionFeedbackGenerator().selectionChanged()
        stopTracking()
    }

    func stopTracking() {
        resetTrackingUI()
        Task {
            if let state = try? await camera.stopFocusTracking() {
                cameraState = state
            }
        }
    }

    @objc func trackingToggleTapped() {
        guard cameraState?.isFocusTrackingSupported == true else { return }
        isTrackingModeOn.toggle()
        UISelectionFeedbackGenerator().selectionChanged()
        if isTrackingModeOn {
            showFocusHint("轻点主体开始追踪对焦")
        } else {
            hideFocusHint()
            if trackingPhase.isActive {
                stopTracking()
            }
        }
        updateControlAvailability()
    }

    @objc func apertureButtonTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        setAperturePanelShown(!isAperturePanelShown)
    }

    func selectAperture(_ setting: ApertureSetting) {
        guard cameraState?.isRunning == true, !isCapturing, !isSwitching, !isChangingMode, !isStarting else {
            updateApertureUI()
            return
        }
        apertureSetting = setting
        updateApertureUI()
        apertureRequestID += 1
        let requestID = apertureRequestID
        Task {
            do {
                let state = try await camera.setAperture(setting)
                guard requestID == apertureRequestID else { return }
                cameraState = state
            } catch {
                guard requestID == apertureRequestID else { return }
                cameraState = try? await camera.currentState()
                presentError(error)
            }
        }
    }

    @objc func liveTapped() {
        guard !isBusy, cameraState?.isRunning == true, cameraState?.isLivePhotoSupported == true else { return }
        let enabled = cameraState?.isLivePhotoEnabled != true
        isChangingMode = true
        updateControlAvailability()
        UISelectionFeedbackGenerator().selectionChanged()
        Task {
            defer {
                isChangingMode = false
                updateControlAvailability()
            }
            do {
                cameraState = try await camera.setLivePhotoEnabled(enabled)
            } catch {
                cameraState = try? await camera.currentState()
                presentError(error)
            }
        }
    }

    func setLatestMedia(_ media: CapturedMedia) {
        latestMedia?.removeTemporaryFiles()
        latestMedia = media
        thumbnailButton.setImage(media.thumbnail, for: .normal)
        thumbnailVideoBadge.image = media.badgeSymbol.flatMap { UIImage(systemName: $0) }
        thumbnailVideoBadge.isHidden = media.badgeSymbol == nil
        thumbnailButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.6,
            initialSpringVelocity: 0.8
        ) {
            self.thumbnailButton.transform = .identity
        }
        updateControlAvailability()
    }
}

// MARK: - UI

private extension CameraViewController {
    func setupUI() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = .black
        previewView.clipsToBounds = true
        view.addSubview(previewView)

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.white.withAlphaComponent(0.7)
        dimView.alpha = 0
        dimView.isUserInteractionEnabled = false
        view.addSubview(dimView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        view.addSubview(statusLabel)

        recordingLabel.translatesAutoresizingMaskIntoConstraints = false
        recordingLabel.textColor = .white
        recordingLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        recordingLabel.textAlignment = .center
        recordingLabel.backgroundColor = .systemRed
        recordingLabel.layer.cornerRadius = 6
        recordingLabel.clipsToBounds = true
        recordingLabel.isHidden = true
        view.addSubview(recordingLabel)

        configureIconButton(flashButton, systemName: "bolt.slash.fill", action: #selector(flashTapped))
        flashButton.accessibilityLabel = "闪光灯"
        view.addSubview(flashButton)
        configureIconButton(liveButton, systemName: "livephoto.slash", action: #selector(liveTapped))
        liveButton.accessibilityLabel = "实况照片"
        view.addSubview(liveButton)
        configureIconButton(trackingToggle, systemName: "dot.viewfinder", action: #selector(trackingToggleTapped))
        trackingToggle.accessibilityLabel = "追踪对焦"
        view.addSubview(trackingToggle)
        configureIconButton(switchButton, systemName: "camera.rotate.fill", action: #selector(switchTapped))
        switchButton.accessibilityLabel = "切换摄像头"

        configureThumbnailButton()
        configureShutterButton()
        configureModeControl()
        configureTextButton(retryButton, title: "重新开启相机", action: #selector(retryCameraTapped))
        retryButton.isHidden = true
        view.addSubview(retryButton)

        cameraControls.axis = .horizontal
        cameraControls.alignment = .center
        cameraControls.distribution = .equalSpacing
        cameraControls.translatesAutoresizingMaskIntoConstraints = false
        cameraControls.addArrangedSubview(thumbnailButton)
        cameraControls.addArrangedSubview(shutterButton)
        cameraControls.addArrangedSubview(switchButton)
        view.addSubview(cameraControls)
        configureApertureControls()

        focusIndicator.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        focusIndicator.layer.borderColor = UIColor.systemYellow.cgColor
        focusIndicator.layer.borderWidth = 1.5
        focusIndicator.alpha = 0
        focusIndicator.isUserInteractionEnabled = false
        previewView.addSubview(focusIndicator)

        previewView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        previewView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:))))
        configureFocusTrackingViews()

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            flashButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            flashButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            flashButton.widthAnchor.constraint(equalToConstant: 48),
            flashButton.heightAnchor.constraint(equalToConstant: 48),

            liveButton.leadingAnchor.constraint(equalTo: flashButton.trailingAnchor, constant: 4),
            liveButton.centerYAnchor.constraint(equalTo: flashButton.centerYAnchor),
            liveButton.widthAnchor.constraint(equalToConstant: 48),
            liveButton.heightAnchor.constraint(equalToConstant: 48),

            recordingLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recordingLabel.centerYAnchor.constraint(equalTo: flashButton.centerYAnchor),
            recordingLabel.widthAnchor.constraint(equalToConstant: 76),
            recordingLabel.heightAnchor.constraint(equalToConstant: 28),

            thumbnailButton.widthAnchor.constraint(equalToConstant: 52),
            thumbnailButton.heightAnchor.constraint(equalToConstant: 52),
            shutterButton.widthAnchor.constraint(equalToConstant: 76),
            shutterButton.heightAnchor.constraint(equalToConstant: 76),
            switchButton.widthAnchor.constraint(equalToConstant: 52),
            switchButton.heightAnchor.constraint(equalToConstant: 52),

            cameraControls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 36),
            cameraControls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -36),
            cameraControls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cameraControls.heightAnchor.constraint(equalToConstant: 84),

            modeControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            modeControl.bottomAnchor.constraint(equalTo: cameraControls.topAnchor, constant: -16),
            modeControl.widthAnchor.constraint(equalToConstant: 160),

            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),

            apertureButton.leadingAnchor.constraint(equalTo: thumbnailButton.trailingAnchor, constant: 10),
            apertureButton.centerYAnchor.constraint(equalTo: cameraControls.centerYAnchor),
            apertureButton.widthAnchor.constraint(equalToConstant: 40),
            apertureButton.heightAnchor.constraint(equalToConstant: 40),

            apertureIndicator.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            apertureIndicator.centerYAnchor.constraint(equalTo: flashButton.centerYAnchor),

            aperturePanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            aperturePanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            aperturePanel.bottomAnchor.constraint(equalTo: modeControl.topAnchor, constant: -12)
        ])
    }

    func configureApertureControls() {
        var buttonConfig = UIButton.Configuration.filled()
        buttonConfig.attributedTitle = AttributedString(
            "ƒ",
            attributes: AttributeContainer([.font: UIFont.italicSystemFont(ofSize: 20)])
        )
        buttonConfig.cornerStyle = .capsule
        buttonConfig.baseForegroundColor = .systemYellow
        buttonConfig.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
        buttonConfig.contentInsets = .zero
        apertureButton.configuration = buttonConfig
        apertureButton.accessibilityLabel = "镜头光圈"
        apertureButton.translatesAutoresizingMaskIntoConstraints = false
        apertureButton.isHidden = true
        apertureButton.addTarget(self, action: #selector(apertureButtonTapped), for: .touchUpInside)
        view.addSubview(apertureButton)

        var indicatorConfig = UIButton.Configuration.plain()
        indicatorConfig.image = UIImage(systemName: "camera.aperture")
        indicatorConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        indicatorConfig.imagePlacement = .bottom
        indicatorConfig.imagePadding = 2
        indicatorConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        apertureIndicator.configuration = indicatorConfig
        apertureIndicator.translatesAutoresizingMaskIntoConstraints = false
        apertureIndicator.isHidden = true
        apertureIndicator.addTarget(self, action: #selector(apertureButtonTapped), for: .touchUpInside)
        view.addSubview(apertureIndicator)

        aperturePanel.translatesAutoresizingMaskIntoConstraints = false
        aperturePanel.isHidden = true
        aperturePanel.alpha = 0
        aperturePanel.onSelect = { [weak self] setting in
            self?.selectAperture(setting)
        }
        aperturePanel.onClose = { [weak self] in
            self?.setAperturePanelShown(false)
        }
        view.addSubview(aperturePanel)
    }

    func configureFocusTrackingViews() {
        trackingFrame.isHidden = true
        previewView.addSubview(trackingFrame)

        var badgeConfig = UIButton.Configuration.filled()
        badgeConfig.attributedTitle = AttributedString(
            "追踪对焦",
            attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14, weight: .semibold)])
        )
        badgeConfig.image = UIImage(systemName: "xmark.circle.fill")
        badgeConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        badgeConfig.imagePlacement = .trailing
        badgeConfig.imagePadding = 6
        badgeConfig.cornerStyle = .capsule
        badgeConfig.baseForegroundColor = .black
        badgeConfig.baseBackgroundColor = .systemYellow
        badgeConfig.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 8)
        trackingBadge.configuration = badgeConfig
        trackingBadge.accessibilityLabel = "取消追踪对焦"
        trackingBadge.translatesAutoresizingMaskIntoConstraints = false
        trackingBadge.isHidden = true
        trackingBadge.addTarget(self, action: #selector(cancelFocusTrackingTapped), for: .touchUpInside)
        view.addSubview(trackingBadge)

        focusHintLabel.textColor = .white
        focusHintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        focusHintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        focusHintLabel.layer.cornerRadius = 6
        focusHintLabel.clipsToBounds = true
        focusHintLabel.alpha = 0
        focusHintLabel.isUserInteractionEnabled = false
        focusHintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(focusHintLabel)

        // 照片模式排在实况后面；视频模式实况隐藏，挪到实况的位置。
        trackingToggleAfterLive = trackingToggle.leadingAnchor.constraint(equalTo: liveButton.trailingAnchor, constant: 4)
        trackingToggleAfterFlash = trackingToggle.leadingAnchor.constraint(equalTo: flashButton.trailingAnchor, constant: 4)
        trackingToggleAfterLive?.isActive = true

        NSLayoutConstraint.activate([
            trackingToggle.centerYAnchor.constraint(equalTo: flashButton.centerYAnchor),
            trackingToggle.widthAnchor.constraint(equalToConstant: 48),
            trackingToggle.heightAnchor.constraint(equalToConstant: 48),
            trackingBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            trackingBadge.topAnchor.constraint(equalTo: flashButton.bottomAnchor, constant: 8),
            focusHintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            focusHintLabel.centerYAnchor.constraint(equalTo: trackingBadge.centerYAnchor)
        ])
    }

    /// 相机重新配置（切换镜头或模式）、停止或被打断后系统那边的追踪已经结束，界面跟着收起。
    func updateFocusTrackingUI() {
        switch trackingPhase {
        case .idle:
            return
        case .locking:
            // 锁定请求还在路上时，状态里可能还没标记追踪；只在相机不可用时收起。
            if cameraState == nil {
                resetTrackingUI()
            }
        case .tracking, .lost:
            if cameraState?.isFocusTracking != true {
                resetTrackingUI()
            }
        }
    }

    /// 系统回调被追踪主体的位置；nil 表示主体不在画面里。
    func handleTrackedObject(metadataRect: CGRect?) {
        let rect = metadataRect.map { trackingDisplayRect(forMetadataRect: $0) }
        switch trackingPhase {
        case .idle:
            return
        case .locking(_, let box, let startedAt):
            // 换目标时系统可能还在报旧主体，只认和点击位置的框有交集的结果。
            guard let rect, rect.intersects(box.insetBy(dx: -24, dy: -24)) else { return }
            let elapsed = Date().timeIntervalSince(startedAt)
            print("[Track] locked after \(Int(elapsed * 1000))ms")
            setTrackingPhase(.tracking)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // 系统锁得很快时也让半透明框停留一下，看得出「锁定中 → 已锁定」。
            trackingFrame.setStyle(.tracking, animated: true, delay: max(0, TrackingUI.minLockingDisplay - elapsed))
            moveTrackingFrame(to: rect, duration: 0.15)
        case .tracking:
            guard let rect else {
                scheduleTrackingLost()
                return
            }
            trackingLostTask?.cancel()
            trackingLostTask = nil
            moveTrackingFrame(to: rect, duration: 0.1)
        case .lost:
            guard let rect else { return }
            trackingFrame.setStyle(.tracking, animated: false)
            moveTrackingFrame(to: rect, duration: 0)
            setTrackingPhase(.tracking)
        }
    }

    func setTrackingPhase(_ phase: TrackingPhase) {
        trackingPhase = phase
        let showsFrame: Bool
        switch phase {
        case .idle, .lost:
            showsFrame = false
            trackingTimeoutTask?.cancel()
            trackingTimeoutTask = nil
            trackingLostTask?.cancel()
            trackingLostTask = nil
        case .locking:
            showsFrame = true
            trackingLostTask?.cancel()
            trackingLostTask = nil
        case .tracking:
            showsFrame = true
            trackingTimeoutTask?.cancel()
            trackingTimeoutTask = nil
        }
        trackingFrame.isHidden = !showsFrame
        // 顶部胶囊在整个追踪期间都在，目标丢失时换文字。
        if case .idle = phase {
            trackingBadge.isHidden = true
        } else {
            hideFocusHint()
            if case .lost = phase {
                updateTrackingBadge(isLost: true)
            } else {
                updateTrackingBadge(isLost: false)
            }
            trackingBadge.isHidden = false
        }
    }

    func updateTrackingBadge(isLost: Bool) {
        trackingBadge.configuration?.attributedTitle = AttributedString(
            isLost ? "目标丢失" : "追踪对焦",
            attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14, weight: .semibold)])
        )
        trackingBadge.accessibilityLabel = isLost ? "目标丢失，取消追踪对焦" : "取消追踪对焦"
    }

    /// 收起追踪界面，并让还在路上的锁定请求作废。
    func resetTrackingUI() {
        trackingRequestID += 1
        setTrackingPhase(.idle)
    }

    /// 系统偶尔会丢一两帧，短暂消失不算丢失，避免提示来回闪。
    func scheduleTrackingLost() {
        guard trackingLostTask == nil else { return }
        trackingLostTask = Task { [weak self] in
            try? await Task.sleep(for: TrackingUI.lostDebounce)
            guard let self, !Task.isCancelled else { return }
            self.trackingLostTask = nil
            if case .tracking = self.trackingPhase {
                self.setTrackingPhase(.lost)
            }
        }
    }

    func moveTrackingFrame(to rect: CGRect, duration: TimeInterval) {
        guard duration > 0, !trackingFrame.isHidden else {
            UIView.performWithoutAnimation {
                trackingFrame.frame = rect
            }
            return
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveLinear]
        ) {
            self.trackingFrame.frame = rect
        }
    }

    /// metadata 坐标转成预览坐标：只保留画面内的部分，主体很小时放大到最小尺寸。
    func trackingDisplayRect(forMetadataRect metadataRect: CGRect) -> CGRect {
        let bounds = previewView.bounds
        var rect = previewView.previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
        let visible = rect.intersection(bounds)
        if !visible.isNull {
            rect = visible
        }
        let minSide = TrackingUI.minFrameSide
        rect = rect.insetBy(dx: min(0, (rect.width - minSide) / 2), dy: min(0, (rect.height - minSide) / 2))
        rect.origin.x = min(max(rect.origin.x, 0), bounds.width - rect.width)
        rect.origin.y = min(max(rect.origin.y, 0), bounds.height - rect.height)
        return rect
    }

    func showFocusHint(_ text: String) {
        focusHintLabel.text = text
        focusHintTask?.cancel()
        UIView.animate(withDuration: 0.2) { self.focusHintLabel.alpha = 1 }
        focusHintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.hideFocusHint()
        }
    }

    func hideFocusHint() {
        focusHintTask?.cancel()
        focusHintTask = nil
        UIView.animate(withDuration: 0.2) { self.focusHintLabel.alpha = 0 }
    }

    func syncApertureFromState() {
        if let state = cameraState {
            apertureSetting = state.aperture
            liveAperture = state.lensAperture
        }
        updateApertureUI()
    }

    func updateApertureUI() {
        let stops = cameraState?.apertureStops ?? []
        let adjustable = !stops.isEmpty
        if !adjustable, isAperturePanelShown {
            setAperturePanelShown(false, animated: false)
        }
        aperturePanel.update(stops: stops, setting: apertureSetting, liveAperture: liveAperture)
        apertureButton.isHidden = !adjustable
        apertureButton.configuration?.baseBackgroundColor = isAperturePanelShown
            ? UIColor.white.withAlphaComponent(0.3)
            : UIColor.black.withAlphaComponent(0.45)

        let displayed: Float
        switch apertureSetting {
        case .manual(let value) where adjustable:
            displayed = value
        default:
            displayed = liveAperture
        }
        let color: UIColor = adjustable ? .systemYellow : .white
        apertureIndicator.isHidden = cameraState == nil || displayed <= 0
        apertureIndicator.isUserInteractionEnabled = adjustable
        apertureIndicator.configuration?.attributedTitle = AttributedString(
            ApertureControlView.format(displayed, stops: stops),
            attributes: AttributeContainer([
                .font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: color
            ])
        )
        apertureIndicator.configuration?.baseForegroundColor = color
        apertureIndicator.accessibilityLabel = "光圈 ƒ\(ApertureControlView.format(displayed, stops: stops))"
    }

    func setAperturePanelShown(_ shown: Bool, animated: Bool = true) {
        guard shown != isAperturePanelShown else { return }
        isAperturePanelShown = shown
        if shown {
            aperturePanel.isHidden = false
            aperturePanel.transform = CGAffineTransform(translationX: 0, y: 24)
        }
        let changes = {
            self.aperturePanel.alpha = shown ? 1 : 0
            self.aperturePanel.transform = shown ? .identity : CGAffineTransform(translationX: 0, y: 24)
        }
        let completion = { (_: Bool) in
            if !self.isAperturePanelShown {
                self.aperturePanel.isHidden = true
            }
        }
        if animated {
            UIView.animate(
                withDuration: 0.32,
                delay: 0,
                usingSpringWithDamping: 0.85,
                initialSpringVelocity: 0.4,
                animations: changes,
                completion: completion
            )
        } else {
            changes()
            completion(true)
        }
        updateControlAvailability()
        updateApertureUI()
    }

    func configureIconButton(_ button: UIButton, systemName: String, action: Selector) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        config.baseForegroundColor = .white
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    func configureTextButton(_ button: UIButton, title: String, action: Selector) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .capsule
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.22)
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    func configureThumbnailButton() {
        thumbnailButton.translatesAutoresizingMaskIntoConstraints = false
        thumbnailButton.accessibilityLabel = "查看最近拍摄"
        thumbnailButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        thumbnailButton.layer.cornerRadius = 26
        thumbnailButton.layer.borderWidth = 2
        thumbnailButton.layer.borderColor = UIColor.white.cgColor
        thumbnailButton.clipsToBounds = true
        thumbnailButton.contentHorizontalAlignment = .fill
        thumbnailButton.contentVerticalAlignment = .fill
        thumbnailButton.imageView?.contentMode = .scaleAspectFill
        thumbnailButton.addTarget(self, action: #selector(thumbnailTapped), for: .touchUpInside)

        thumbnailVideoBadge.translatesAutoresizingMaskIntoConstraints = false
        thumbnailVideoBadge.tintColor = .white
        thumbnailVideoBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        thumbnailVideoBadge.layer.shadowColor = UIColor.black.cgColor
        thumbnailVideoBadge.layer.shadowOpacity = 0.6
        thumbnailVideoBadge.layer.shadowRadius = 2
        thumbnailVideoBadge.layer.shadowOffset = .zero
        thumbnailVideoBadge.isUserInteractionEnabled = false
        thumbnailVideoBadge.isHidden = true
        thumbnailButton.addSubview(thumbnailVideoBadge)
        NSLayoutConstraint.activate([
            thumbnailVideoBadge.centerXAnchor.constraint(equalTo: thumbnailButton.centerXAnchor),
            thumbnailVideoBadge.centerYAnchor.constraint(equalTo: thumbnailButton.centerYAnchor)
        ])
    }

    func configureShutterButton() {
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.backgroundColor = .clear
        shutterButton.layer.cornerRadius = 38
        shutterButton.layer.borderWidth = 5
        shutterButton.layer.borderColor = UIColor.white.cgColor
        shutterButton.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        shutterButton.addTarget(self, action: #selector(shutterHighlightOn), for: [.touchDown, .touchDragEnter])
        shutterButton.addTarget(
            self,
            action: #selector(shutterHighlightOff),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )

        shutterInner.translatesAutoresizingMaskIntoConstraints = false
        shutterInner.isUserInteractionEnabled = false
        shutterButton.addSubview(shutterInner)
        let width = shutterInner.widthAnchor.constraint(equalToConstant: 62)
        let height = shutterInner.heightAnchor.constraint(equalToConstant: 62)
        shutterInnerWidth = width
        shutterInnerHeight = height
        NSLayoutConstraint.activate([
            shutterInner.centerXAnchor.constraint(equalTo: shutterButton.centerXAnchor),
            shutterInner.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            width,
            height
        ])
    }

    func configureModeControl() {
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegmentIndex = 0
        modeControl.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        modeControl.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.9)
        modeControl.setTitleTextAttributes(
            [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 14, weight: .semibold)],
            for: .normal
        )
        modeControl.setTitleTextAttributes(
            [.foregroundColor: UIColor.black, .font: UIFont.systemFont(ofSize: 14, weight: .semibold)],
            for: .selected
        )
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        view.addSubview(modeControl)
    }

    @objc func shutterHighlightOn() {
        UIView.animate(withDuration: 0.08) {
            self.shutterButton.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
    }

    @objc func shutterHighlightOff() {
        UIView.animate(withDuration: 0.12) {
            self.shutterButton.transform = .identity
        }
    }

    func updateShutterAppearance(animated: Bool = true) {
        let size: CGFloat
        let radius: CGFloat
        let color: UIColor
        switch (captureMode, isRecording) {
        case (.photo, _):
            size = 62
            radius = 31
            color = .white
            shutterButton.accessibilityLabel = "拍照"
        case (.video, false):
            size = 62
            radius = 31
            color = .systemRed
            shutterButton.accessibilityLabel = "开始录像"
        case (.video, true):
            size = 30
            radius = 6
            color = .systemRed
            shutterButton.accessibilityLabel = "停止录像"
        }
        shutterInnerWidth?.constant = size
        shutterInnerHeight?.constant = size
        let changes = {
            self.shutterInner.layer.cornerRadius = radius
            self.shutterInner.backgroundColor = color
            self.shutterButton.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: changes)
        } else {
            changes()
        }
    }

    func startRecordingTimer() {
        let start = Date()
        recordingLabel.text = Self.formatDuration(0)
        recordingLabel.isHidden = false
        recordingTimerTask?.cancel()
        recordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.recordingLabel.text = Self.formatDuration(Date().timeIntervalSince(start))
            }
        }
    }

    func stopRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingLabel.isHidden = true
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func updateFlashButton() {
        let supported = captureMode == .photo && cameraState?.hasFlash == true && cameraState?.isFront == false
        flashButton.alpha = supported ? 1 : 0.35
        if !supported {
            flashMode = .off
        }

        let symbol: String
        switch flashMode {
        case .on:
            symbol = "bolt.fill"
        case .auto:
            symbol = "bolt.badge.automatic.fill"
        default:
            symbol = "bolt.slash.fill"
        }
        flashButton.configuration?.image = UIImage(systemName: symbol)
        flashButton.configuration?.baseForegroundColor = flashMode == .off ? .white : .systemYellow
    }

    /// 当前镜头不支持追踪时开关变灰，但保留用户的选择，切回支持的镜头后恢复。
    func updateTrackingToggle(ready: Bool) {
        let supported = cameraState?.isFocusTrackingSupported == true
        let isOn = isTrackingModeOn && supported
        trackingToggle.isEnabled = (ready || isRecording) && supported
        trackingToggle.alpha = supported ? 1 : 0.35
        trackingToggle.configuration?.baseForegroundColor = isOn ? .systemYellow : .white
        trackingToggle.accessibilityValue = isOn ? "已开启" : "已关闭"
        let afterLive = captureMode == .photo
        if trackingToggleAfterLive?.isActive != afterLive {
            trackingToggleAfterLive?.isActive = false
            trackingToggleAfterFlash?.isActive = false
            if afterLive {
                trackingToggleAfterLive?.isActive = true
            } else {
                trackingToggleAfterFlash?.isActive = true
            }
        }
    }

    func updateLiveButton(ready: Bool) {
        let supported = captureMode == .photo && cameraState?.isLivePhotoSupported == true
        let isOn = supported && cameraState?.isLivePhotoEnabled == true
        liveButton.isHidden = captureMode != .photo
        liveButton.isEnabled = ready && supported
        liveButton.alpha = supported ? 1 : 0.35
        liveButton.configuration?.image = UIImage(systemName: isOn ? "livephoto" : "livephoto.slash")
        liveButton.configuration?.baseForegroundColor = isOn ? .systemYellow : .white
        liveButton.accessibilityValue = isOn ? "已开启" : "已关闭"
    }

    func flashScreen() {
        dimView.alpha = 0.85
        UIView.animate(withDuration: 0.25) {
            self.dimView.alpha = 0
        }
    }

    func showFocusIndicator(at point: CGPoint) {
        focusIndicator.center = point
        focusIndicator.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        focusIndicator.alpha = 1
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            self.focusIndicator.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 0.45) {
                self.focusIndicator.alpha = 0
            }
        }
    }

    /// 切换摄像头或模式会重建预览连接，旋转角会回到默认横向，所以要按当前设备重新协调。
    func updatePreviewOrientation() {
        if let deviceID = cameraState?.deviceID, deviceID != coordinatedDeviceID,
           let device = AVCaptureDevice(uniqueID: deviceID) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewView.previewLayer)
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.applyPreviewRotation()
                }
            }
            rotationCoordinator = coordinator
            coordinatedDeviceID = deviceID
        }
        applyPreviewRotation()
        // 新预览连接可能在本轮 run loop 之后才挂到 layer 上。
        DispatchQueue.main.async { [weak self] in
            self?.applyPreviewRotation()
        }
    }

    func applyPreviewRotation() {
        guard let connection = previewView.previewLayer.connection else { return }
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? interfaceRotationAngle
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = cameraState?.isFront == true
        }
    }

    var captureRotationAngle: CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? interfaceRotationAngle
    }

    var interfaceRotationAngle: CGFloat {
        switch view.window?.windowScene?.interfaceOrientation {
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return 270
        case .landscapeLeft:
            return 180
        case .landscapeRight:
            return 0
        default:
            return 90
        }
    }

    func updateControlAvailability() {
        let ready = isScreenVisible && cameraState?.isRunning == true && !isBusy
        let shutterEnabled = ready || isRecording
        shutterButton.isEnabled = shutterEnabled
        shutterButton.alpha = shutterEnabled ? 1 : 0.5
        switchButton.isEnabled = ready
        switchButton.alpha = ready ? 1 : 0.5
        modeControl.isEnabled = ready
        modeControl.alpha = isRecording ? 0 : 1
        let apertureEnabled = ready || isRecording
        apertureButton.isEnabled = apertureEnabled
        apertureButton.alpha = apertureEnabled ? 1 : 0.5
        aperturePanel.isUserInteractionEnabled = apertureEnabled
        updateLiveButton(ready: ready)
        updateTrackingToggle(ready: ready)
        updateFlashButton()
        flashButton.isEnabled = ready && captureMode == .photo
            && cameraState?.hasFlash == true && cameraState?.isFront == false
        thumbnailButton.isEnabled = latestMedia != nil && !isCapturing && !isRecording
    }

    func presentError(_ error: Error) {
        let title = "无法完成操作"
        let message = error.localizedDescription
        guard isScreenVisible,
              UIApplication.shared.applicationState != .background,
              presentedViewController == nil else {
            print("[UI] \(title): \(message)")
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

private enum TrackingPhase {
    case idle
    /// 已发起追踪，等系统锁定主体；`box` 是点击位置的框（预览坐标）。
    case locking(requestID: Int, box: CGRect, startedAt: Date)
    case tracking
    /// 系统仍在追踪，但主体暂时不在画面里。
    case lost

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }
}

private enum TrackingUI {
    /// 「追踪对焦」开关状态存在 UserDefaults 里，下次打开 App 保持。
    static let modeDefaultsKey = "TestCamer.focusTrackingModeOn"
    /// 轻点后、锁定前显示在点击位置的半透明框边长。
    static let tapBoxSide: CGFloat = 90
    /// 超过这个时间还没锁定主体，就退回普通对焦。
    static let lockTimeout: Duration = .seconds(1)
    /// 锁定中的半透明框至少显示这么久，再变成锁定样式。
    static let minLockingDisplay: TimeInterval = 0.2
    /// 主体消失超过这个时间才提示目标丢失。
    static let lostDebounce: Duration = .milliseconds(300)
    /// 追踪框的最小边长，主体很小时框也看得清。
    static let minFrameSide: CGFloat = 44
}

/// 追踪框，样式对齐系统相机：黄色 1pt 细线、6pt 圆角。
/// 锁定中半透明停在点击位置；锁定后变成不透明，并像系统对焦框那样轻轻缩一下。
final class TrackingFrameView: UIView {
    enum Style {
        case locking
        case tracking
    }

    private static let lockingAlpha: CGFloat = 0.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.borderColor = UIColor.systemYellow.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        alpha = Self.lockingAlpha
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStyle(_ style: Style, animated: Bool, delay: TimeInterval = 0) {
        // 只清掉透明度和缩放动画，不打断正在进行的位移动画。
        layer.removeAnimation(forKey: "opacity")
        layer.removeAnimation(forKey: "lockPulse")
        let targetAlpha: CGFloat = style == .locking ? Self.lockingAlpha : 1
        guard animated else {
            alpha = targetAlpha
            return
        }
        UIView.animate(
            withDuration: 0.2,
            delay: delay,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.alpha = targetAlpha
        }
        guard style == .tracking else { return }
        // 缩放只加在 layer 上，不改 transform，外框的 frame 动画不受影响。
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.08
        pulse.toValue = 1.0
        pulse.duration = 0.25
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.beginTime = CACurrentMediaTime() + delay
        pulse.fillMode = .backwards
        layer.add(pulse, forKey: "lockPulse")
    }
}
