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
    private let trackingBadge = UIButton(type: .system)
    private let trackingBox = UIView()
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
            updateTrackingBox(metadataRect: rect)
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
        let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: location)
        let wasTracking = cameraState?.isFocusTracking == true
        camera.focus(at: devicePoint)
        showFocusIndicator(at: location)
        if wasTracking {
            trackingBox.isHidden = true
        } else if cameraState?.isFocusTrackingSupported == true {
            showFocusHint("轻点两下以追踪对焦")
        }
    }

    @objc func handleDoubleTapToTrack(_ gesture: UITapGestureRecognizer) {
        guard !isCapturing, !isSwitching, !isChangingMode, cameraState?.isRunning == true else { return }
        guard cameraState?.isFocusTrackingSupported == true else {
            handleTapToFocus(gesture)
            return
        }
        let location = gesture.location(in: previewView)
        let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: location)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        hideFocusHint()
        trackingBox.frame = CGRect(x: location.x - 45, y: location.y - 45, width: 90, height: 90)
        trackingBox.isHidden = false
        Task {
            do {
                cameraState = try await camera.startFocusTracking(at: devicePoint)
            } catch {
                cameraState = try? await camera.currentState()
                presentError(error)
            }
        }
    }

    @objc func cancelFocusTrackingTapped() {
        UISelectionFeedbackGenerator().selectionChanged()
        trackingBox.isHidden = true
        Task {
            cameraState = try? await camera.stopFocusTracking()
        }
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
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTapToTrack(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        singleTap.require(toFail: doubleTap)
        previewView.addGestureRecognizer(doubleTap)
        previewView.addGestureRecognizer(singleTap)
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
        trackingBox.layer.borderColor = UIColor.systemYellow.cgColor
        trackingBox.layer.borderWidth = 1.5
        trackingBox.layer.cornerRadius = 8
        trackingBox.layer.cornerCurve = .continuous
        trackingBox.isUserInteractionEnabled = false
        trackingBox.isHidden = true
        previewView.addSubview(trackingBox)

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

        NSLayoutConstraint.activate([
            trackingBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            trackingBadge.topAnchor.constraint(equalTo: flashButton.bottomAnchor, constant: 8),
            focusHintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            focusHintLabel.centerYAnchor.constraint(equalTo: trackingBadge.centerYAnchor)
        ])
    }

    func updateFocusTrackingUI() {
        let isTracking = cameraState?.isFocusTracking == true
        trackingBadge.isHidden = !isTracking
        if !isTracking {
            trackingBox.isHidden = true
        }
    }

    func updateTrackingBox(metadataRect: CGRect?) {
        guard cameraState?.isFocusTracking == true else { return }
        guard let metadataRect else {
            trackingBox.isHidden = true
            return
        }
        let rect = previewView.previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
        let wasHidden = trackingBox.isHidden
        trackingBox.isHidden = false
        if wasHidden {
            trackingBox.frame = rect
        } else {
            UIView.animate(
                withDuration: 0.1,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveLinear]
            ) {
                self.trackingBox.frame = rect
            }
        }
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
