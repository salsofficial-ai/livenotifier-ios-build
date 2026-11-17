import UIKit
import AVFoundation
import CoreImage
import Darwin

final class CameraViewController: UIViewController {

    // MARK: - Capture & Upload State
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.livenotifier.cam.session", qos: .userInitiated)
    private let videoOutputQueue = DispatchQueue(label: "com.livenotifier.cam.video", qos: .userInteractive)
    private let stateLock = NSLock()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var currentDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer!

    private var isConnected = false
    private var qrLockPending = false
    private var facingBack = true
    private var isMirrored = false
    private var torchOn = false
    private var rotDeg = 0
    private var resKey = "res1080_60"
    private var displayZoom: CGFloat = 1.0
    private var pinchStartZoom: CGFloat = 1.0
    private var pinchActive = false

    private var serverBaseURL: URL?
    private var streamSid = String(Int.random(in: 100000...999999))
    private var frameSeq: Int64 = 0
    private var inFlightCount = 0
    private var flipRotationAngle: CGFloat = 0

    private lazy var uploadSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.5
        cfg.timeoutIntervalForResource = 2.5
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg, delegate: LocalTLSDelegate(), delegateQueue: nil)
    }()

    // MARK: - UI Elements
    private let previewContainer = UIView()
    private let focusBox = UIView()
    private var focusTimer: Timer?

    // Front Connect UI
    private let connectOverlay = UIView()
    private let netStatusBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let netStatusLabel = UILabel()
    private let scanFrameView = UIView()
    private let scanBracketLayer = CAShapeLayer()
    private let scanLaserView = UIView()
    private let iconQrView = UIImageView()
    private let iconSyncView = UIView()
    private let iconCrossView = UIImageView()
    private let promptTitleLabel = UILabel()
    private let promptSubLabel = UILabel()
    private let helpButton = UIButton(type: .system)
    private let connectNowButton = UIButton(type: .system)
    private let connectDotView = UIView()

    private var scanStageTimer: Timer?
    private var scanStageIndex = 0
    private var scanWidthConstraint: NSLayoutConstraint!
    private var scanHeightConstraint: NSLayoutConstraint!

    // Connected HUD UI
    private let disconnectBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let disconnectButton = UIButton(type: .system)
    private let dockStack = UIStackView()
    private let zoomHudBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let zoomHudLabel = UILabel()
    private let zoomHudTrack = UIView()
    private let zoomHudFill = UIView()
    private var zoomHudFillWidth: NSLayoutConstraint!
    private var zoomHudHideTimer: Timer?

    private let zoomPillBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let zoomSteps: [CGFloat] = [0.5, 1.0, 1.5, 2.0, 3.0]
    private var zoomButtons: [UIButton] = []

    private let flipButton = UIButton(type: .system)
    private let mirrorButton = UIButton(type: .system)
    private let torchButton = UIButton(type: .system)

    // MARK: - Colors
    private let prismYellow = UIColor(red: 1.0, green: 230.0 / 255.0, blue: 0.0, alpha: 1.0)
    private let matchGreen = UIColor(red: 34.0 / 255.0, green: 197.0 / 255.0, blue: 94.0 / 255.0, alpha: 1.0)

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { isConnected }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if let saved = UserDefaults.standard.string(forKey: "lastServerBaseURL"), let u = URL(string: saved) {
            serverBaseURL = u
        }

        setupPreview()
        setupConnectUI()
        setupConnectedHUD()
        setupGestures()
        startScannerAnimation()
        requestCameraAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewContainer.bounds
        updateBracketPath()
    }

    // MARK: - UI Setup
    private func setupPreview() {
        previewContainer.frame = view.bounds
        previewContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewContainer.backgroundColor = .black
        view.addSubview(previewContainer)

        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = previewContainer.bounds
        previewContainer.layer.addSublayer(previewLayer)

        focusBox.frame = CGRect(x: 0, y: 0, width: 68, height: 68)
        focusBox.layer.borderColor = prismYellow.cgColor
        focusBox.layer.borderWidth = 1.8
        focusBox.layer.cornerRadius = 14
        focusBox.alpha = 0
        focusBox.isUserInteractionEnabled = false
        view.addSubview(focusBox)
    }

    private func setupConnectUI() {
        connectOverlay.frame = view.bounds
        connectOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(connectOverlay)

        let gradient = CAGradientLayer()
        gradient.frame = UIScreen.main.bounds
        gradient.colors = [
            UIColor.black.withAlphaComponent(0.50).cgColor,
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.75).cgColor
        ]
        gradient.locations = [0.0, 0.24, 0.56, 1.0]
        connectOverlay.layer.insertSublayer(gradient, at: 0)

        // Top Network Pill
        netStatusBlur.translatesAutoresizingMaskIntoConstraints = false
        netStatusBlur.layer.cornerRadius = 16
        netStatusBlur.clipsToBounds = true
        netStatusBlur.layer.borderWidth = 1
        netStatusBlur.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        connectOverlay.addSubview(netStatusBlur)

        netStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        netStatusLabel.text = "Finding local network..."
        netStatusLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        netStatusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        netStatusBlur.contentView.addSubview(netStatusLabel)

        // Center Scanner Brackets Frame
        scanFrameView.translatesAutoresizingMaskIntoConstraints = false
        connectOverlay.addSubview(scanFrameView)

        scanBracketLayer.fillColor = UIColor.clear.cgColor
        scanBracketLayer.strokeColor = UIColor.white.cgColor
        scanBracketLayer.lineWidth = 4
        scanBracketLayer.lineCap = .round
        scanBracketLayer.lineJoin = .round
        scanFrameView.layer.addSublayer(scanBracketLayer)

        scanLaserView.backgroundColor = prismYellow
        scanLaserView.layer.cornerRadius = 1
        scanLaserView.layer.shadowColor = prismYellow.cgColor
        scanLaserView.layer.shadowRadius = 8
        scanLaserView.layer.shadowOpacity = 0.8
        scanLaserView.layer.shadowOffset = .zero
        scanFrameView.addSubview(scanLaserView)

        // Stage Icons
        let cfg = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        iconQrView.image = UIImage(systemName: "qrcode", withConfiguration: cfg)
        iconQrView.tintColor = .white
        iconQrView.contentMode = .scaleAspectFit
        iconQrView.translatesAutoresizingMaskIntoConstraints = false
        scanFrameView.addSubview(iconQrView)

        let pcImg = UIImageView(image: UIImage(systemName: "desktopcomputer", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)))
        pcImg.tintColor = .white
        pcImg.translatesAutoresizingMaskIntoConstraints = false
        let phoneImg = UIImageView(image: UIImage(systemName: "iphone", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)))
        phoneImg.tintColor = prismYellow
        phoneImg.translatesAutoresizingMaskIntoConstraints = false
        iconSyncView.translatesAutoresizingMaskIntoConstraints = false
        iconSyncView.addSubview(pcImg)
        iconSyncView.addSubview(phoneImg)
        scanFrameView.addSubview(iconSyncView)

        iconCrossView.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold))
        iconCrossView.tintColor = prismYellow
        iconCrossView.translatesAutoresizingMaskIntoConstraints = false
        scanFrameView.addSubview(iconCrossView)

        // Bottom Prompts + Help + CONNECT NOW
        promptTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        promptTitleLabel.numberOfLines = 3
        promptTitleLabel.textAlignment = .center
        promptTitleLabel.text = "Scan the QR code\nto connect to the PC or the\nremote control."
        promptTitleLabel.textColor = .white
        promptTitleLabel.font = .systemFont(ofSize: 20, weight: .bold)

        promptSubLabel.translatesAutoresizingMaskIntoConstraints = false
        promptSubLabel.textAlignment = .center
        promptSubLabel.text = "Connect both devices to the same WiFi."
        promptSubLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        promptSubLabel.font = .systemFont(ofSize: 13, weight: .regular)

        let helpBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        helpBlur.translatesAutoresizingMaskIntoConstraints = false
        helpBlur.layer.cornerRadius = 19
        helpBlur.clipsToBounds = true
        helpBlur.layer.borderWidth = 1
        helpBlur.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

        helpButton.translatesAutoresizingMaskIntoConstraints = false
        helpButton.setTitle("Help", for: .normal)
        helpButton.setTitleColor(.white, for: .normal)
        helpButton.titleLabel?.font = .systemFont(ofSize: 13.5, weight: .semibold)
        helpButton.addTarget(self, action: #selector(didTapHelp), for: .touchUpInside)
        helpBlur.contentView.addSubview(helpButton)

        let connectBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        connectBlur.translatesAutoresizingMaskIntoConstraints = false
        connectBlur.layer.cornerRadius = 22
        connectBlur.clipsToBounds = true
        connectBlur.backgroundColor = prismYellow.withAlphaComponent(0.14)
        connectBlur.layer.borderWidth = 1
        connectBlur.layer.borderColor = prismYellow.withAlphaComponent(0.55).cgColor

        connectDotView.translatesAutoresizingMaskIntoConstraints = false
        connectDotView.backgroundColor = prismYellow
        connectDotView.layer.cornerRadius = 3.5
        connectDotView.layer.shadowColor = prismYellow.cgColor
        connectDotView.layer.shadowRadius = 6
        connectDotView.layer.shadowOpacity = 0.9
        connectDotView.layer.shadowOffset = .zero

        connectNowButton.translatesAutoresizingMaskIntoConstraints = false
        connectNowButton.setTitle("   CONNECT NOW", for: .normal)
        connectNowButton.setTitleColor(.white, for: .normal)
        connectNowButton.titleLabel?.font = .systemFont(ofSize: 13.5, weight: .heavy)
        connectNowButton.addTarget(self, action: #selector(didTapConnectNow), for: .touchUpInside)
        connectBlur.contentView.addSubview(connectNowButton)
        connectBlur.contentView.addSubview(connectDotView)

        connectOverlay.addSubview(promptTitleLabel)
        connectOverlay.addSubview(promptSubLabel)
        connectOverlay.addSubview(helpBlur)
        connectOverlay.addSubview(connectBlur)

        scanWidthConstraint = scanFrameView.widthAnchor.constraint(equalToConstant: 152)
        scanHeightConstraint = scanFrameView.heightAnchor.constraint(equalToConstant: 152)

        NSLayoutConstraint.activate([
            netStatusBlur.topAnchor.constraint(equalTo: connectOverlay.safeAreaLayoutGuide.topAnchor, constant: 6),
            netStatusBlur.centerXAnchor.constraint(equalTo: connectOverlay.centerXAnchor),
            netStatusLabel.topAnchor.constraint(equalTo: netStatusBlur.topAnchor, constant: 6),
            netStatusLabel.bottomAnchor.constraint(equalTo: netStatusBlur.bottomAnchor, constant: -6),
            netStatusLabel.leadingAnchor.constraint(equalTo: netStatusBlur.leadingAnchor, constant: 14),
            netStatusLabel.trailingAnchor.constraint(equalTo: netStatusBlur.trailingAnchor, constant: -14),

            scanFrameView.centerXAnchor.constraint(equalTo: connectOverlay.centerXAnchor),
            scanFrameView.centerYAnchor.constraint(equalTo: connectOverlay.centerYAnchor, constant: -42),
            scanWidthConstraint,
            scanHeightConstraint,

            iconQrView.centerXAnchor.constraint(equalTo: scanFrameView.centerXAnchor),
            iconQrView.centerYAnchor.constraint(equalTo: scanFrameView.centerYAnchor),
            iconSyncView.centerXAnchor.constraint(equalTo: scanFrameView.centerXAnchor),
            iconSyncView.centerYAnchor.constraint(equalTo: scanFrameView.centerYAnchor),
            iconSyncView.widthAnchor.constraint(equalToConstant: 88),
            iconSyncView.heightAnchor.constraint(equalToConstant: 60),
            pcImg.centerXAnchor.constraint(equalTo: iconSyncView.centerXAnchor, constant: -8),
            pcImg.centerYAnchor.constraint(equalTo: iconSyncView.centerYAnchor),
            phoneImg.trailingAnchor.constraint(equalTo: iconSyncView.trailingAnchor, constant: -4),
            phoneImg.bottomAnchor.constraint(equalTo: iconSyncView.bottomAnchor, constant: -4),
            iconCrossView.centerXAnchor.constraint(equalTo: scanFrameView.centerXAnchor),
            iconCrossView.centerYAnchor.constraint(equalTo: scanFrameView.centerYAnchor),

            connectBlur.bottomAnchor.constraint(equalTo: connectOverlay.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            connectBlur.centerXAnchor.constraint(equalTo: connectOverlay.centerXAnchor),
            connectBlur.heightAnchor.constraint(equalToConstant: 44),
            connectNowButton.topAnchor.constraint(equalTo: connectBlur.topAnchor),
            connectNowButton.bottomAnchor.constraint(equalTo: connectBlur.bottomAnchor),
            connectNowButton.leadingAnchor.constraint(equalTo: connectBlur.leadingAnchor, constant: 22),
            connectNowButton.trailingAnchor.constraint(equalTo: connectBlur.trailingAnchor, constant: -22),
            connectDotView.leadingAnchor.constraint(equalTo: connectBlur.leadingAnchor, constant: 20),
            connectDotView.centerYAnchor.constraint(equalTo: connectBlur.centerYAnchor),
            connectDotView.widthAnchor.constraint(equalToConstant: 7),
            connectDotView.heightAnchor.constraint(equalToConstant: 7),

            helpBlur.bottomAnchor.constraint(equalTo: connectBlur.topAnchor, constant: -14),
            helpBlur.centerXAnchor.constraint(equalTo: connectOverlay.centerXAnchor),
            helpBlur.heightAnchor.constraint(equalToConstant: 38),
            helpButton.topAnchor.constraint(equalTo: helpBlur.topAnchor),
            helpButton.bottomAnchor.constraint(equalTo: helpBlur.bottomAnchor),
            helpButton.leadingAnchor.constraint(equalTo: helpBlur.leadingAnchor, constant: 24),
            helpButton.trailingAnchor.constraint(equalTo: helpBlur.trailingAnchor, constant: -24),

            promptSubLabel.bottomAnchor.constraint(equalTo: helpBlur.topAnchor, constant: -16),
            promptSubLabel.centerXAnchor.constraint(equalTo: connectOverlay.centerXAnchor),

            promptTitleLabel.bottomAnchor.constraint(equalTo: promptSubLabel.topAnchor, constant: -8),
            promptTitleLabel.leadingAnchor.constraint(equalTo: connectOverlay.leadingAnchor, constant: 24),
            promptTitleLabel.trailingAnchor.constraint(equalTo: connectOverlay.trailingAnchor, constant: -24)
        ])

        // Subtle pulse on CONNECT NOW dot & laser sweep
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.9
        pulse.toValue = 1.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        connectDotView.layer.add(pulse, forKey: "pulse")

        startLaserAnimation()
    }

    private func setupConnectedHUD() {
        // Top-right floating disconnect button (no status bar)
        disconnectBlur.translatesAutoresizingMaskIntoConstraints = false
        disconnectBlur.layer.cornerRadius = 23
        disconnectBlur.clipsToBounds = true
        disconnectBlur.layer.borderWidth = 1
        disconnectBlur.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        disconnectBlur.alpha = 0
        disconnectBlur.transform = CGAffineTransform(translationX: 0, y: -10).scaledBy(x: 0.88, y: 0.88)
        view.addSubview(disconnectBlur)

        let powerIcon = UIImage(systemName: "power", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .bold))
        disconnectButton.translatesAutoresizingMaskIntoConstraints = false
        disconnectButton.setImage(powerIcon, for: .normal)
        disconnectButton.tintColor = .white
        disconnectButton.addTarget(self, action: #selector(didTapDisconnect), for: .touchUpInside)
        disconnectBlur.contentView.addSubview(disconnectButton)

        // Bottom Dock
        dockStack.axis = .vertical
        dockStack.alignment = .center
        dockStack.spacing = 14
        dockStack.translatesAutoresizingMaskIntoConstraints = false
        dockStack.alpha = 0
        dockStack.transform = CGAffineTransform(translationX: 0, y: 28).scaledBy(x: 0.96, y: 0.96)
        view.addSubview(dockStack)

        // Floating Pinch Zoom HUD Badge
        zoomHudBlur.translatesAutoresizingMaskIntoConstraints = false
        zoomHudBlur.layer.cornerRadius = 18
        zoomHudBlur.clipsToBounds = true
        zoomHudBlur.layer.borderWidth = 1
        zoomHudBlur.layer.borderColor = prismYellow.withAlphaComponent(0.45).cgColor
        zoomHudBlur.alpha = 0
        zoomHudBlur.transform = CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.9, y: 0.9)

        zoomHudLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomHudLabel.text = "1.0×"
        zoomHudLabel.textColor = prismYellow
        zoomHudLabel.font = .monospacedDigitSystemFont(ofSize: 19, weight: .heavy)
        zoomHudBlur.contentView.addSubview(zoomHudLabel)

        zoomHudTrack.translatesAutoresizingMaskIntoConstraints = false
        zoomHudTrack.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        zoomHudTrack.layer.cornerRadius = 2
        zoomHudTrack.clipsToBounds = true
        zoomHudBlur.contentView.addSubview(zoomHudTrack)

        zoomHudFill.translatesAutoresizingMaskIntoConstraints = false
        zoomHudFill.backgroundColor = prismYellow
        zoomHudFill.layer.cornerRadius = 2
        zoomHudTrack.addSubview(zoomHudFill)
        zoomHudFillWidth = zoomHudFill.widthAnchor.constraint(equalToConstant: 16)

        NSLayoutConstraint.activate([
            zoomHudLabel.topAnchor.constraint(equalTo: zoomHudBlur.contentView.topAnchor, constant: 8),
            zoomHudLabel.centerXAnchor.constraint(equalTo: zoomHudBlur.contentView.centerXAnchor),
            zoomHudTrack.topAnchor.constraint(equalTo: zoomHudLabel.bottomAnchor, constant: 5),
            zoomHudTrack.bottomAnchor.constraint(equalTo: zoomHudBlur.contentView.bottomAnchor, constant: -9),
            zoomHudTrack.leadingAnchor.constraint(equalTo: zoomHudBlur.contentView.leadingAnchor, constant: 18),
            zoomHudTrack.trailingAnchor.constraint(equalTo: zoomHudBlur.contentView.trailingAnchor, constant: -18),
            zoomHudTrack.widthAnchor.constraint(equalToConstant: 112),
            zoomHudTrack.heightAnchor.constraint(equalToConstant: 4),
            zoomHudFill.leadingAnchor.constraint(equalTo: zoomHudTrack.leadingAnchor),
            zoomHudFill.topAnchor.constraint(equalTo: zoomHudTrack.topAnchor),
            zoomHudFill.bottomAnchor.constraint(equalTo: zoomHudTrack.bottomAnchor),
            zoomHudFillWidth
        ])
        dockStack.addArrangedSubview(zoomHudBlur)

        // Zoom Pill Bar (0.5x, 1x, 1.5x, 2x, 3x)
        zoomPillBlur.translatesAutoresizingMaskIntoConstraints = false
        zoomPillBlur.layer.cornerRadius = 21
        zoomPillBlur.clipsToBounds = true
        zoomPillBlur.layer.borderWidth = 1
        zoomPillBlur.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor

        let zoomRow = UIStackView()
        zoomRow.axis = .horizontal
        zoomRow.spacing = 4
        zoomRow.translatesAutoresizingMaskIntoConstraints = false
        zoomPillBlur.contentView.addSubview(zoomRow)
        NSLayoutConstraint.activate([
            zoomRow.topAnchor.constraint(equalTo: zoomPillBlur.topAnchor, constant: 4),
            zoomRow.bottomAnchor.constraint(equalTo: zoomPillBlur.bottomAnchor, constant: -4),
            zoomRow.leadingAnchor.constraint(equalTo: zoomPillBlur.leadingAnchor, constant: 4),
            zoomRow.trailingAnchor.constraint(equalTo: zoomPillBlur.trailingAnchor, constant: -4)
        ])

        for (idx, z) in zoomSteps.enumerated() {
            let btn = UIButton(type: .system)
            btn.tag = idx
            let title = z.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(z))x" : String(format: "%.1fx", z)
            btn.setTitle(title, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
            btn.layer.cornerRadius = 17
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
            btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            btn.addTarget(self, action: #selector(didTapZoomPill(_:)), for: .touchUpInside)
            zoomRow.addArrangedSubview(btn)
            zoomButtons.append(btn)
        }
        dockStack.addArrangedSubview(zoomPillBlur)

        // 3 Circular 58x58 Icon Buttons (Flip, Mirror, Torch)
        let ctrlRow = UIStackView()
        ctrlRow.axis = .horizontal
        ctrlRow.spacing = 22
        ctrlRow.alignment = .center

        let iconCfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let flipWrap = makeCircleIconButton(flipButton, systemName: "arrow.triangle.2.circlepath", config: iconCfg)
        let mirWrap = makeCircleIconButton(mirrorButton, systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right", config: iconCfg)
        let torchWrap = makeCircleIconButton(torchButton, systemName: "bolt.fill", config: iconCfg)

        flipButton.addTarget(self, action: #selector(didTapFlip), for: .touchUpInside)
        mirrorButton.addTarget(self, action: #selector(didTapMirror), for: .touchUpInside)
        torchButton.addTarget(self, action: #selector(didTapTorch), for: .touchUpInside)

        ctrlRow.addArrangedSubview(flipWrap)
        ctrlRow.addArrangedSubview(mirWrap)
        ctrlRow.addArrangedSubview(torchWrap)
        dockStack.addArrangedSubview(ctrlRow)

        NSLayoutConstraint.activate([
            disconnectBlur.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            disconnectBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            disconnectBlur.widthAnchor.constraint(equalToConstant: 46),
            disconnectBlur.heightAnchor.constraint(equalToConstant: 46),
            disconnectButton.topAnchor.constraint(equalTo: disconnectBlur.topAnchor),
            disconnectButton.bottomAnchor.constraint(equalTo: disconnectBlur.bottomAnchor),
            disconnectButton.leadingAnchor.constraint(equalTo: disconnectBlur.leadingAnchor),
            disconnectButton.trailingAnchor.constraint(equalTo: disconnectBlur.trailingAnchor),

            dockStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            dockStack.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        updateZoomPillSelection()
    }

    private func makeCircleIconButton(_ btn: UIButton, systemName: String, config: UIImage.SymbolConfiguration) -> UIVisualEffectView {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 29
        blur.clipsToBounds = true
        blur.layer.borderWidth = 1
        blur.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        blur.widthAnchor.constraint(equalToConstant: 58).isActive = true
        blur.heightAnchor.constraint(equalToConstant: 58).isActive = true

        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(UIImage(systemName: systemName, withConfiguration: config), for: .normal)
        btn.tintColor = .white
        btn.layer.cornerRadius = 29
        blur.contentView.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: blur.topAnchor),
            btn.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            btn.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            btn.trailingAnchor.constraint(equalTo: blur.trailingAnchor)
        ])
        return blur
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapPreview(_:)))
        tap.cancelsTouchesInView = false
        previewContainer.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(didPinchPreview(_:)))
        view.addGestureRecognizer(pinch)
    }

    // MARK: - Scanner Stage Animations
    private func startScannerAnimation() {
        scanStageTimer?.invalidate()
        applyScannerStage(index: scanStageIndex)
        scanStageTimer = Timer.scheduledTimer(withTimeInterval: 1.35, repeats: true) { [weak self] _ in
            guard let self = self, !self.isConnected, !self.qrLockPending else { return }
            self.scanStageIndex = (self.scanStageIndex + 1) % 3
            self.applyScannerStage(index: self.scanStageIndex)
        }
    }

    private func startLaserAnimation() {
        scanLaserView.layer.removeAllAnimations()
        scanLaserView.frame = CGRect(x: 18, y: 24, width: 116, height: 2)
        let anim = CABasicAnimation(keyPath: "position.y")
        anim.fromValue = 26
        anim.toValue = 194
        anim.duration = 2.0
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scanLaserView.layer.add(anim, forKey: "laserSweep")
    }

    private func applyScannerStage(index: Int) {
        let targetSize: CGFloat = (index == 0) ? 152 : 236
        let stroke: UIColor = (index == 0) ? .white : prismYellow
        scanWidthConstraint.constant = targetSize
        scanHeightConstraint.constant = targetSize
        scanLaserView.frame = CGRect(x: 18, y: 24, width: targetSize - 36, height: 2)

        UIView.animate(withDuration: 0.48, delay: 0, usingSpringWithDamping: 0.84, initialSpringVelocity: 0.4) {
            self.connectOverlay.layoutIfNeeded()
            self.iconQrView.alpha = (index == 0) ? 1 : 0
            self.iconSyncView.alpha = (index == 1) ? 1 : 0
            self.iconCrossView.alpha = (index == 2) ? 1 : 0
        }
        scanBracketLayer.strokeColor = stroke.cgColor
        updateBracketPath(size: targetSize)
    }

    private func updateBracketPath(size: CGFloat? = nil) {
        let s = size ?? scanFrameView.bounds.width
        guard s > 20 else { return }
        let arm: CGFloat = 28
        let r: CGFloat = 14
        let p = UIBezierPath()
        // Top-Left
        p.move(to: CGPoint(x: 0, y: arm))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), controlPoint: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: arm, y: 0))
        // Top-Right
        p.move(to: CGPoint(x: s - arm, y: 0))
        p.addLine(to: CGPoint(x: s - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: s, y: r), controlPoint: CGPoint(x: s, y: 0))
        p.addLine(to: CGPoint(x: s, y: arm))
        // Bottom-Right
        p.move(to: CGPoint(x: s, y: s - arm))
        p.addLine(to: CGPoint(x: s, y: s - r))
        p.addQuadCurve(to: CGPoint(x: s - r, y: s), controlPoint: CGPoint(x: s, y: s))
        p.addLine(to: CGPoint(x: s - arm, y: s))
        // Bottom-Left
        p.move(to: CGPoint(x: arm, y: s))
        p.addLine(to: CGPoint(x: r, y: s))
        p.addQuadCurve(to: CGPoint(x: 0, y: s - r), controlPoint: CGPoint(x: 0, y: s))
        p.addLine(to: CGPoint(x: 0, y: s - arm))
        scanBracketLayer.path = p.cgPath
        scanBracketLayer.frame = CGRect(x: 0, y: 0, width: s, height: s)
    }

    // MARK: - Camera Setup & Switching
    private func requestCameraAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession(back: true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession(back: true)
                    } else {
                        self?.showPermissionAlert()
                    }
                }
            }
        default:
            showPermissionAlert()
        }
    }

    private func showPermissionAlert() {
        let alert = UIAlertController(
            title: "ต้องอนุญาตใช้กล้อง",
            message: "กรุณาเปิดสิทธิ์ใช้งานกล้องในการตั้งค่า iPhone เพื่อสแกน QR และถ่ายภาพส่งเข้าคอม",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "ไปที่ตั้งค่า", style: .default) { _ in
            if let u = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(u)
            }
        })
        alert.addAction(UIAlertAction(title: "ปิด", style: .cancel))
        present(alert, animated: true)
    }

    private var wideBaseZoomFactor: CGFloat {
        guard let dev = currentDevice else { return 1.0 }
        if dev.deviceType == .builtInTripleCamera || dev.deviceType == .builtInDualWideCamera,
           let first = dev.virtualDeviceSwitchOverVideoZoomFactors.first {
            return CGFloat(first.doubleValue)
        }
        return 1.0
    }

    private func discoverCamera(back: Bool) -> AVCaptureDevice? {
        if back {
            let types: [AVCaptureDevice.DeviceType] = [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInUltraWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera
            ]
            return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices.first
        } else {
            let types: [AVCaptureDevice.DeviceType] = [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .front).devices.first
        }
    }

    private func configureSession(back: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
            } else {
                self.session.sessionPreset = .hd1280x720
            }

            if let old = self.currentInput {
                self.session.removeInput(old)
                self.currentInput = nil
            }

            guard let device = self.discoverCamera(back: back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                return
            }

            self.session.addInput(input)
            self.currentInput = input
            self.currentDevice = device
            self.facingBack = back

            if !self.session.outputs.contains(self.videoOutput) {
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                }
            }

            if let conn = self.videoOutput.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                } else {
                    if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
                }
                conn.isVideoMirrored = false
            }

            if !self.session.outputs.contains(self.metadataOutput) {
                if self.session.canAddOutput(self.metadataOutput) {
                    self.session.addOutput(self.metadataOutput)
                    self.metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
                    if self.metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                        self.metadataOutput.metadataObjectTypes = [.qr]
                    }
                }
            }

            self.configure60FPSFormat(device: device)
            self.session.commitConfiguration()

            if !self.session.isRunning {
                self.session.startRunning()
            }

            DispatchQueue.main.async {
                self.applyHardwareZoom(self.displayZoom, showHud: false)
                if !self.facingBack { self.torchOn = false; self.updateControlButtonStates() }
            }
        }
    }

    private func configure60FPSFormat(device: AVCaptureDevice) {
        let desiredW: Int32 = (resKey == "res720") ? 1280 : 1920
        var bestFormat: AVCaptureDevice.Format?
        for fmt in device.formats {
            let desc = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard desc.width == desiredW else { continue }
            let has60 = fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 59.0 }
            if has60 {
                bestFormat = fmt
                break
            }
        }
        do {
            try device.lockForConfiguration()
            if let fmt = bestFormat {
                device.activeFormat = fmt
                let fps60 = CMTime(value: 1, timescale: 60)
                device.activeVideoMinFrameDuration = fps60
                device.activeVideoMaxFrameDuration = fps60
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch {}
    }

    private func applyHardwareZoom(_ targetDisplayZoom: CGFloat, showHud: Bool, keepHudOpen: Bool = false) {
        let clamped = max(0.5, min(4.0, (targetDisplayZoom * 100).rounded() / 100))
        displayZoom = clamped
        updateZoomPillSelection()
        if showHud {
            showZoomHud(clamped, keepOpen: keepHudOpen)
        }

        sessionQueue.async { [weak self] in
            guard let self = self, let dev = self.currentDevice else { return }
            let base = self.wideBaseZoomFactor
            let minDev = dev.minAvailableVideoZoomFactor
            let maxDev = min(dev.activeFormat.videoMaxZoomFactor, base * 4.0)
            let desiredFactor = clamped * base
            let finalFactor = max(minDev, min(maxDev, desiredFactor))
            do {
                try dev.lockForConfiguration()
                dev.videoZoomFactor = finalFactor
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    private func applyHardwareTorch(_ on: Bool) {
        guard facingBack, let dev = currentDevice, dev.hasTorch else {
            torchOn = false
            updateControlButtonStates()
            return
        }
        sessionQueue.async { [weak self] in
            do {
                try dev.lockForConfiguration()
                dev.torchMode = on ? .on : .off
                dev.unlockForConfiguration()
                DispatchQueue.main.async {
                    self?.torchOn = on
                    self?.updateControlButtonStates()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.torchOn = false
                    self?.updateControlButtonStates()
                }
            }
        }
    }

    // MARK: - Actions & Gestures
    @objc private func didTapZoomPill(_ sender: UIButton) {
        let z = zoomSteps[sender.tag]
        UISelectionFeedbackGenerator().selectionChanged()
        applyHardwareZoom(z, showHud: true, keepHudOpen: false)
    }

    @objc private func didTapFlip() {
        UISelectionFeedbackGenerator().selectionChanged()
        flipRotationAngle += .pi
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.5) {
            self.flipButton.imageView?.transform = CGAffineTransform(rotationAngle: self.flipRotationAngle)
        }
        let nextBack = !facingBack
        if !nextBack && displayZoom < 1.0 { displayZoom = 1.0 }
        configureSession(back: nextBack)
    }

    @objc private func didTapMirror() {
        UISelectionFeedbackGenerator().selectionChanged()
        isMirrored.toggle()
        updateControlButtonStates()
        UIView.animate(withDuration: 0.24, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3) {
            self.previewContainer.transform = self.isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        }
    }

    @objc private func didTapTorch() {
        UISelectionFeedbackGenerator().selectionChanged()
        if !facingBack {
            torchOn = false
            updateControlButtonStates()
            return
        }
        applyHardwareTorch(!torchOn)
    }

    @objc private func didTapDisconnect() {
        UISelectionFeedbackGenerator().selectionChanged()
        exitConnectedMode()
    }

    @objc private func didTapHelp() {
        let hostText = serverBaseURL?.host ?? "ยังไม่ได้เชื่อมต่อ"
        let alert = UIAlertController(
            title: "LiveNotifier Cam (Native iOS)",
            message: "เชื่อมต่อ Wi-Fi เดียวกับคอมแล้วส่องกล้องไปที่ QR Code บนหน้าจอคอม (สถานะ: \(hostText)) หรือกดปุ่ม CONNECT NOW เพื่อค้นหาเครื่องคอมในวง Wi-Fi อัตโนมัติ",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "ค้นหาและเชื่อมต่อทันที", style: .default) { [weak self] _ in
            self?.didTapConnectNow()
        })
        alert.addAction(UIAlertAction(title: "ปิด", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func didTapConnectNow() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        netStatusLabel.text = "Searching PC on WiFi..."
        discoverLocalPC { [weak self] foundURL in
            guard let self = self else { return }
            if let url = foundURL {
                self.lockAndConnect(baseURL: url)
            } else {
                self.netStatusLabel.text = "Finding local network..."
                let alert = UIAlertController(
                    title: "ไม่พบโปรแกรมบนคอมพิวเตอร์",
                    message: "ตรวจสอบว่าเปิดโปรแกรม LiveNotifier บนคอมอยู่ และเชื่อม Wi-Fi วงเดียวกัน หรือส่อง QR Code บนหน้าจอคอม",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "ตกลง", style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    @objc private func didTapPreview(_ gesture: UITapGestureRecognizer) {
        let pt = gesture.location(in: view)
        focusBox.center = pt
        focusBox.alpha = 1
        focusBox.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        UIView.animate(withDuration: 0.22) {
            self.focusBox.transform = .identity
        }
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.2) { self?.focusBox.alpha = 0 }
        }

        let devPoint = previewLayer.captureDevicePointConverted(fromLayerPoint: gesture.location(in: previewContainer))
        sessionQueue.async { [weak self] in
            guard let dev = self?.currentDevice else { return }
            do {
                try dev.lockForConfiguration()
                if dev.isFocusPointOfInterestSupported {
                    dev.focusPointOfInterest = devPoint
                    dev.focusMode = .continuousAutoFocus
                }
                if dev.isExposurePointOfInterestSupported {
                    dev.exposurePointOfInterest = devPoint
                    dev.exposureMode = .continuousAutoExposure
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    @objc private func didPinchPreview(_ gesture: UIPinchGestureRecognizer) {
        guard isConnected else { return }
        switch gesture.state {
        case .began:
            pinchActive = true
            pinchStartZoom = displayZoom
            showZoomHud(displayZoom, keepOpen: true)
        case .changed:
            let nextZ = pinchStartZoom * gesture.scale
            applyHardwareZoom(nextZ, showHud: true, keepHudOpen: true)
        case .ended, .cancelled, .failed:
            pinchActive = false
            showZoomHud(displayZoom, keepOpen: false)
        default:
            break
        }
    }

    // MARK: - HUD Transitions & Visual Feedback
    private func showZoomHud(_ z: CGFloat, keepOpen: Bool) {
        let clamped = max(0.5, min(4.0, z))
        zoomHudLabel.text = String(format: "%.1f×", clamped)
        let ratio = (clamped - 0.5) / 3.5
        zoomHudFillWidth.constant = max(5, 112 * ratio)
        zoomHudHideTimer?.invalidate()

        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
            self.zoomHudBlur.alpha = 1
            self.zoomHudBlur.transform = .identity
        }
        if !keepOpen {
            zoomHudHideTimer = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: false) { [weak self] _ in
                guard let self = self, !self.pinchActive else { return }
                UIView.animate(withDuration: 0.24) {
                    self.zoomHudBlur.alpha = 0
                    self.zoomHudBlur.transform = CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.9, y: 0.9)
                }
            }
        }
    }

    private func updateZoomPillSelection() {
        var bestIdx = -1
        var bestDiff: CGFloat = 99
        for (i, z) in zoomSteps.enumerated() {
            let d = abs(z - displayZoom)
            if d < bestDiff { bestDiff = d; bestIdx = i }
        }
        for (i, btn) in zoomButtons.enumerated() {
            let active = (i == bestIdx && bestDiff < 0.26)
            UIView.animate(withDuration: 0.18) {
                btn.backgroundColor = active ? self.prismYellow : .clear
                btn.setTitleColor(active ? .black : UIColor.white.withAlphaComponent(0.86), for: .normal)
            }
        }
    }

    private func updateControlButtonStates() {
        mirrorButton.backgroundColor = isMirrored ? prismYellow : .clear
        mirrorButton.tintColor = isMirrored ? .black : .white
        torchButton.backgroundColor = torchOn ? prismYellow : .clear
        torchButton.tintColor = torchOn ? .black : .white
    }

    private func lockAndConnect(baseURL: URL) {
        guard !isConnected, !qrLockPending else { return }
        qrLockPending = true
        serverBaseURL = baseURL
        UserDefaults.standard.set(baseURL.absoluteString, forKey: "lastServerBaseURL")

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        scanBracketLayer.strokeColor = matchGreen.cgColor
        netStatusLabel.text = "Connected!"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.enterConnectedMode()
        }
    }

    private func enterConnectedMode() {
        qrLockPending = false
        isConnected = true
        stateLock.lock()
        frameSeq = 0
        streamSid = String(Int.random(in: 100000...999999))
        stateLock.unlock()

        setNeedsUpdateOfHomeIndicatorAutoHidden()
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.3) {
            self.connectOverlay.alpha = 0
            self.connectOverlay.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
            self.disconnectBlur.alpha = 1
            self.disconnectBlur.transform = .identity
            self.dockStack.alpha = 1
            self.dockStack.transform = .identity
        }
    }

    private func exitConnectedMode() {
        isConnected = false
        qrLockPending = false
        if torchOn { applyHardwareTorch(false) }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        netStatusLabel.text = "Finding local network..."
        scanBracketLayer.strokeColor = UIColor.white.cgColor
        applyScannerStage(index: 0)

        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.2) {
            self.connectOverlay.alpha = 1
            self.connectOverlay.transform = .identity
            self.disconnectBlur.alpha = 0
            self.disconnectBlur.transform = CGAffineTransform(translationX: 0, y: -10).scaledBy(x: 0.88, y: 0.88)
            self.dockStack.alpha = 0
            self.dockStack.transform = CGAffineTransform(translationX: 0, y: 28).scaledBy(x: 0.96, y: 0.96)
            self.zoomHudBlur.alpha = 0
        }
    }

    // MARK: - Networking & LAN Auto-Discovery
    private func resolveReachableServer(fromScannedString raw: String, completion: @escaping (URL?) -> Void) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed), let host = comps.host, !host.isEmpty else {
            completion(nil)
            return
        }
        let httpCandidate = URL(string: "http://\(host):47828")!
        probeStatus(baseURL: httpCandidate) { ok in
            if ok {
                completion(httpCandidate)
            } else {
                let port = comps.port ?? 47829
                let scheme = comps.scheme ?? "https"
                completion(URL(string: "\(scheme)://\(host):\(port)"))
            }
        }
    }

    private func probeStatus(baseURL: URL, timeout: TimeInterval = 0.55, completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        uploadSession.dataTask(with: req) { data, resp, _ in
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["ready"] as? Bool) == true else {
                completion(false)
                return
            }
            completion(true)
        }.resume()
    }

    private func localWiFiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            if name == "en0" || name.hasPrefix("en") {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                return String(cString: hostname)
            }
        }
        return nil
    }

    private func discoverLocalPC(completion: @escaping (URL?) -> Void) {
        if let saved = serverBaseURL {
            probeStatus(baseURL: saved, timeout: 0.45) { [weak self] ok in
                if ok {
                    DispatchQueue.main.async { completion(saved) }
                } else {
                    self?.scanSubnet(completion: completion)
                }
            }
        } else {
            scanSubnet(completion: completion)
        }
    }

    private func scanSubnet(completion: @escaping (URL?) -> Void) {
        guard let myIP = localWiFiIPv4() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let parts = myIP.split(separator: ".")
        guard parts.count == 4 else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
        let myHostByte = Int(parts[3]) ?? -1

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let lock = NSLock()
            var winner: URL?
            let group = DispatchGroup()
            let sem = DispatchSemaphore(value: 40)

            for i in 1...254 where i != myHostByte {
                lock.lock()
                let done = (winner != nil)
                lock.unlock()
                if done { break }

                sem.wait()
                lock.lock()
                let doneAfterWait = (winner != nil)
                lock.unlock()
                if doneAfterWait { sem.signal(); break }

                group.enter()
                let candidate = URL(string: "http://\(prefix)\(i):47828")!
                self.probeStatus(baseURL: candidate, timeout: 0.48) { ok in
                    if ok {
                        lock.lock()
                        if winner == nil { winner = candidate }
                        lock.unlock()
                    }
                    sem.signal()
                    group.leave()
                }
            }

            group.wait()
            DispatchQueue.main.async { completion(winner) }
        }
    }

    private func handleRemoteCommand(_ cmd: String) {
        switch cmd {
        case "flip":
            didTapFlip()
        case "mirror":
            didTapMirror()
        case "torch":
            didTapTorch()
        case "rotate":
            rotDeg = (rotDeg + 90) % 360
        case "zoom":
            let idx = zoomSteps.firstIndex { abs($0 - displayZoom) < 0.2 } ?? 1
            let nextZ = zoomSteps[(idx + 1) % zoomSteps.count]
            applyHardwareZoom(nextZ, showHud: true, keepHudOpen: false)
        case "res720", "res1080", "res1080_60", "res1440", "res2160":
            resKey = cmd
            sessionQueue.async { [weak self] in
                guard let self = self, let dev = self.currentDevice else { return }
                self.configure60FPSFormat(device: dev)
            }
        default:
            break
        }
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate (Hardware QR Scanner)
extension CameraViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !isConnected, !qrLockPending,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue, !value.isEmpty else { return }

        resolveReachableServer(fromScannedString: value) { [weak self] url in
            guard let self = self, let url = url else { return }
            DispatchQueue.main.async {
                self.lockAndConnect(baseURL: url)
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (60 FPS Upload)
extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isConnected, let baseURL = serverBaseURL else { return }

        stateLock.lock()
        if inFlightCount >= 3 {
            stateLock.unlock()
            return
        }
        inFlightCount += 1
        frameSeq += 1
        let seqNow = frameSeq
        let sidNow = streamSid
        let mirNow = isMirrored
        let rotNow = rotDeg
        let facingStr = facingBack ? "environment" : "user"
        stateLock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            stateLock.lock(); inFlightCount = max(0, inFlightCount - 1); stateLock.unlock()
            return
        }

        var ciImg = CIImage(cvPixelBuffer: pixelBuffer)
        let origW = ciImg.extent.width
        let origH = ciImg.extent.height
        let maxDim: CGFloat = (resKey == "res720") ? 720 : 1080
        let scale = min(1.0, maxDim / max(origW, origH))
        if scale < 0.99 {
            ciImg = ciImg.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        if mirNow {
            ciImg = ciImg.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -ciImg.extent.width, y: 0))
        }
        if rotNow == 90 || rotNow == 180 || rotNow == 270 {
            let rad = CGFloat(rotNow) * .pi / 180.0
            ciImg = ciImg.transformed(by: CGAffineTransform(rotationAngle: rad))
        }
        let ex = ciImg.extent
        if ex.origin.x != 0 || ex.origin.y != 0 {
            ciImg = ciImg.transformed(by: CGAffineTransform(translationX: -ex.origin.x, y: -ex.origin.y))
        }

        let w = Int(ciImg.extent.width)
        let h = Int(ciImg.extent.height)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let jpegData = ciContext.jpegRepresentation(
            of: ciImg,
            colorSpace: cs,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.84]
        ) else {
            stateLock.lock(); inFlightCount = max(0, inFlightCount - 1); stateLock.unlock()
            return
        }

        var comps = URLComponents(url: baseURL.appendingPathComponent("api/frame"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "w", value: "\(w)"),
            URLQueryItem(name: "h", value: "\(h)"),
            URLQueryItem(name: "facing", value: facingStr),
            URLQueryItem(name: "seq", value: "\(seqNow)"),
            URLQueryItem(name: "sid", value: sidNow)
        ]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.httpBody = jpegData
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")

        uploadSession.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            self.stateLock.lock()
            self.inFlightCount = max(0, self.inFlightCount - 1)
            self.stateLock.unlock()

            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cmd = obj["cmd"] as? String, !cmd.isEmpty {
                DispatchQueue.main.async {
                    self.handleRemoteCommand(cmd)
                }
            }
        }.resume()
    }
}

// MARK: - Local Self-Signed HTTPS Fallback Trust
private final class LocalTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
