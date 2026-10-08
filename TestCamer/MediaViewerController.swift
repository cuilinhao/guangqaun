import AVFoundation
import AVKit
import ImageIO
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

enum CapturedMedia {
    case photo(data: Data, image: UIImage)
    case livePhoto(photoURL: URL, movieURL: URL, image: UIImage)
    case video(url: URL, thumbnail: UIImage?)

    var thumbnail: UIImage? {
        switch self {
            // 添加实况
        case .photo(_, let image), .livePhoto(_, _, let image):
            return image
        case .video(_, let thumbnail):
            return thumbnail
        }
    }

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }

    var badgeSymbol: String? {
        switch self {
        case .photo: return nil
        case .livePhoto: return "livephoto"
        case .video: return "play.fill"
        }
    }

    func removeTemporaryFiles() {
        switch self {
        case .photo:
            break
        case .livePhoto(let photoURL, let movieURL, _):
            try? FileManager.default.removeItem(at: photoURL)
            try? FileManager.default.removeItem(at: movieURL)
        case .video(let url, _):
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// PHLivePhoto 只能从文件 URL 组装，扩展名需与照片实际编码（HEIC/JPEG）一致。
    static func writeTemporaryPhoto(_ data: Data) throws -> URL {
        let typeID = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
        let ext = typeID.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestCamer-Live-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    nonisolated static func videoThumbnail(for url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cgImage)
    }

    func saveToPhotoLibrary() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CameraError.photoLibraryDenied
        }
        switch self {
        case .photo(let data, _):
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "TestCamer-\(UUID().uuidString).jpg"
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
            }
        case .livePhoto(let photoURL, let movieURL, _):
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: photoURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: nil)
            }
        case .video(let url, _):
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
            }
        }
    }
}

@MainActor
final class MediaViewerController: UIViewController {
    private let media: CapturedMedia
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private var playerController: AVPlayerViewController?
    private var isSaving = false

    init(media: CapturedMedia) {
        self.media = media
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch media {
        case .photo(_, let image):
            showPhoto(image)
        case .livePhoto(let photoURL, let movieURL, let image):
            showLivePhoto(photoURL: photoURL, movieURL: movieURL, placeholder: image)
        case .video(let url, _):
            showVideo(url)
        }
        setupButtons()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playerController?.player?.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        playerController?.player?.pause()
    }
}

private extension MediaViewerController {
    func showPhoto(_ image: UIImage) {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        pin(imageView)
    }

    func showLivePhoto(photoURL: URL, movieURL: URL, placeholder: UIImage) {
        showPhoto(placeholder)

        let liveView = PHLivePhotoView()
        liveView.contentMode = .scaleAspectFit
        liveView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(liveView)
        pin(liveView)

        let badge = UIImageView(image: PHLivePhotoView.livePhotoBadgeImage(options: .overContent))
        badge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badge)
        let hint = UILabel()
        hint.text = "长按照片播放实况"
        hint.textColor = UIColor.white.withAlphaComponent(0.8)
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
            badge.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            hint.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8)
        ])

        let scale = traitCollection.displayScale
        let targetSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        PHLivePhoto.request(
            withResourceFileURLs: [photoURL, movieURL],
            placeholderImage: placeholder,
            targetSize: targetSize,
            contentMode: .aspectFit
        ) { [weak liveView] livePhoto, info in
            if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                print("[Viewer] live photo load failed: \(error.localizedDescription)")
            }
            let isDegraded = info[PHLivePhotoInfoIsDegradedKey] as? Bool ?? false
            DispatchQueue.main.async { [weak liveView] in
                guard let liveView, let livePhoto else { return }
                liveView.livePhoto = livePhoto
                if !isDegraded {
                    liveView.startPlayback(with: .hint)
                }
            }
        }
    }

    func showVideo(_ url: URL) {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(controller)
        view.addSubview(controller.view)
        pin(controller.view)
        controller.didMove(toParent: self)
        playerController = controller
    }

    func pin(_ subview: UIView) {
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: view.topAnchor),
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func setupButtons() {
        var closeConfig = UIButton.Configuration.filled()
        closeConfig.image = UIImage(systemName: "xmark")
        closeConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        closeConfig.cornerStyle = .capsule
        closeConfig.baseForegroundColor = .white
        closeConfig.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
        closeButton.configuration = closeConfig
        closeButton.accessibilityLabel = "关闭"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        var saveConfig = UIButton.Configuration.filled()
        saveConfig.title = media.isVideo ? "保存视频到相册" : "保存到相册"
        saveConfig.cornerStyle = .capsule
        saveConfig.baseForegroundColor = .black
        saveConfig.baseBackgroundColor = .white
        saveConfig.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 28, bottom: 14, trailing: 28)
        saveButton.configuration = saveConfig
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        view.addSubview(saveButton)

        // 视频底部留给系统播放控件，保存按钮放到右上角。
        if media.isVideo {
            NSLayoutConstraint.activate([
                saveButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                saveButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
            ])
        } else {
            NSLayoutConstraint.activate([
                saveButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                saveButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
            ])
        }
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    @objc func closeTapped() {
        dismiss(animated: true)
    }

    @objc func saveTapped() {
        guard !isSaving else { return }
        isSaving = true
        saveButton.isEnabled = false
        Task {
            defer {
                isSaving = false
                saveButton.isEnabled = true
            }
            do {
                try await media.saveToPhotoLibrary()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                presentAlert(title: "已保存", message: savedMessage)
            } catch {
                presentAlert(title: "无法保存", message: error.localizedDescription)
            }
        }
    }

    var savedMessage: String {
        switch media {
        case .photo: return "照片已保存到相册。"
        case .livePhoto: return "实况照片已保存到相册。"
        case .video: return "视频已保存到相册。"
        }
    }

    func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
