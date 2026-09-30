@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// The camera, looking for a pairing code.
///
/// Opened only when the user taps Scan, and closed as soon as a usable code is read: the
/// link goes to the confirmation sheet, which is where anything is actually decided. A code
/// that is not ours says so and scanning continues, because the user is probably pointing
/// at the wrong thing rather than at a broken code.
struct PairingScannerView: View {
    let onScanned: (PairingLink) -> Void
    let onClose: () -> Void

    private enum CameraState {
        case asking, running, denied, restricted, unavailable, failed
    }

    @State private var state: CameraState = .asking
    @State private var hint: LocalizedStringResource = PairingScannerView.defaultHint
    @State private var controller = QRCaptureController()

    static let defaultHint: LocalizedStringResource = "Fill the frame with the code shown by the Life Dashboard integration in Home Assistant. Closer is better."

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch state {
            case .asking:
                ProgressView().tint(.white)
            case .running:
                QRCameraPreview(controller: controller)
                    .ignoresSafeArea()
                // The outline asks for a close code: one that fills most of the frame reads,
                // one in a corner of it does not.
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 40)
                    .allowsHitTesting(false)
                VStack(spacing: 12) {
                    Spacer()
                    Text(hint)
                        .font(.callout)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button("Close", action: onClose)
                        .foregroundColor(.white)
                }
                .padding(24)
            case .denied:
                explanation(
                    "Camera access is needed to scan a code. You can also paste the address and the secret by hand.",
                    showSettings: true
                )
            case .restricted:
                explanation("Camera access is needed to scan a code. You can also paste the address and the secret by hand.")
            case .unavailable:
                explanation("This device has no camera. Paste the address and the secret by hand instead.")
            case .failed:
                explanation("The camera could not be started.")
            }
        }
        .task { await prepare() }
        .onDisappear { controller.stop() }
    }

    private func explanation(_ message: LocalizedStringKey, showSettings: Bool = false) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.7))
            Text(message)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            if showSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(url) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Button("Close", action: onClose)
                .foregroundColor(.white)
        }
        .padding(32)
    }

    /// Asks once, on opening. A refusal gets an explanation and a way to Settings, because iOS
    /// never shows the system prompt a second time.
    private func prepare() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .denied
                return
            }
        case .restricted:
            state = .restricted
            return
        default:
            state = .denied
            return
        }

        controller.onText = { text in handle(text) }
        switch await controller.configure() {
        case .ready:
            state = .running
            controller.start()
        case .noCamera:
            state = .unavailable
        case .failed:
            state = .failed
        }
    }

    private func handle(_ text: String) {
        switch PairingLinks.parse(text) {
        case .link(let link):
            controller.stop()
            onScanned(link)
        case .invalid(let problem):
            hint = problem.message
        case .notAPairingLink:
            hint = "That is not a Life Dashboard pairing code."
        }
    }
}

/// The capture session behind the scanner.
///
/// @unchecked Sendable: the session is configured, started and stopped only on `queue`; codes
/// reach the UI on the main actor, where `onText` and the dedupe state live.
final class QRCaptureController: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    enum Setup: Sendable { case ready, noCamera, failed }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.owen282000.lifedashboard.qrscanner")
    private let output = AVCaptureMetadataOutput()
    private(set) var device: AVCaptureDevice?

    /// Main actor only.
    var onText: (@MainActor (String) -> Void)?
    /// Main actor only. The same unusable code arrives on every frame; it is reported once, and
    /// after a usable one nothing more is.
    private var lastText: String?
    private var handled = false

    func configure() async -> Setup {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.configureOnQueue()) }
        }
    }

    func start() {
        queue.async {
            if self.device != nil, !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureOnQueue() -> Setup {
        if device != nil { return .ready }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return .noCamera
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input),
              session.canAddOutput(output) else { return .failed }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Only valid once the output is part of the session; before that it throws.
        output.metadataObjectTypes = [.qr]
        focus(camera)
        device = camera
        return .ready
    }

    /// Focus close and in the middle, and zoom in when the lens cannot focus as close as a
    /// code on a laptop screen needs to be held (Pro iPhones focus from about 20 cm).
    private func focus(_ camera: AVCaptureDevice) {
        guard (try? camera.lockForConfiguration()) != nil else { return }
        defer { camera.unlockForConfiguration() }
        if camera.isFocusPointOfInterestSupported {
            camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
        }
        if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }
        if camera.isAutoFocusRangeRestrictionSupported {
            camera.autoFocusRangeRestriction = .near
        }
        let zoom = Self.recommendedZoom(
            minimumFocusDistance: Float(camera.minimumFocusDistance),
            fieldOfView: camera.activeFormat.videoFieldOfView,
            maxZoom: Float(camera.activeFormat.videoMaxZoomFactor)
        )
        camera.videoZoomFactor = CGFloat(zoom)
    }

    /// Apple's AVCamBarcode rule: the distance at which a code of `codeSize` millimetres fills
    /// `fill` of the frame, and the zoom that lets the lens focus there. 1 when the lens does not
    /// say how close it focuses.
    static func recommendedZoom(
        minimumFocusDistance: Float,
        fieldOfView: Float,
        maxZoom: Float,
        codeSize: Float = 40,
        fill: Float = 0.78
    ) -> Float {
        guard minimumFocusDistance > 0, fieldOfView > 0 else { return 1 }
        let halfAngle = fieldOfView / 2 * .pi / 180
        let subjectDistance = (codeSize / fill) / tan(halfAngle)
        guard minimumFocusDistance > subjectDistance else { return 1 }
        return min(minimumFocusDistance / subjectDistance, maxZoom)
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let texts = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        guard let text = texts.first else { return }
        // The delegate queue is .main, set in configureOnQueue.
        MainActor.assumeIsolated {
            guard !handled, text != lastText else { return }
            lastText = text
            if case .link = PairingLinks.parse(text) { handled = true }
            onText?(text)
        }
    }
}

/// The preview layer, kept upright when the phone turns.
private struct QRCameraPreview: UIViewRepresentable {
    let controller: QRCaptureController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = controller.session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let device = controller.device {
            view.followRotation(of: device)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass above guarantees the type.
            layer as? AVCaptureVideoPreviewLayer ?? AVCaptureVideoPreviewLayer()
        }

        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        func followRotation(of device: AVCaptureDevice) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            self.coordinator = coordinator
            observation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview,
                options: [.initial, .new]
            ) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                guard let view = self else { return }
                DispatchQueue.main.async {
                    view.previewLayer.connection?.videoRotationAngle = angle
                }
            }
        }
    }
}
