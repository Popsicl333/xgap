import SwiftUI
import UIKit
import AVFoundation
import Vision
import CoreML
import Combine

final class LineFollowerViewModel: NSObject, ObservableObject {
    @Published var isRunning: Bool = false {
        didSet {
            borderColor = isRunning ? .green : .red
            videoOutputDelegate.setIsRunning(isRunning)
        }
    }

    @Published var borderColor: Color = .red
    @Published var guidanceText: String? = nil
    @Published var detectedLineBoundingBox: CGRect? = nil
    @Published var videoOrientation: AVCaptureVideoOrientation = .landscapeRight
    @Published var isLandscapeFlipped: Bool = false

    private let speechSynth = AVSpeechSynthesizer()
    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let detectionQueue = DispatchQueue(label: "LineDetectionQueue")
    private let sessionQueue = DispatchQueue(label: "CameraSessionQueue")
    private var lastGuidanceSpokenAt: Date? = nil
    nonisolated(unsafe) private var videoOutputDelegate: VideoOutputDelegate!

    override init() {
        super.init()
        let delegate = VideoOutputDelegate(
            onDetection: { [weak self] boundingBox, guidance in
                self?.handleDetection(boundingBox: boundingBox, guidance: guidance)
            },
            onNoDetection: { [weak self] in
                self?.handleNoDetection()
            }
        )
        videoOutputDelegate = delegate
        delegate.setIsRunning(isRunning)
        delegate.setImageOrientation(currentImageOrientation(from: .landscapeRight))
        videoOutput.setSampleBufferDelegate(delegate, queue: detectionQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        startOrientationUpdates()
        refreshVideoOrientation()

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.captureSession.beginConfiguration()

            // Set 1280x720 if available
            if self.captureSession.canSetSessionPreset(.hd1280x720) {
                self.captureSession.sessionPreset = .hd1280x720
            } else {
                self.captureSession.sessionPreset = .high
            }

            // Select back wide angle camera
            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: device)
            else {
                self.captureSession.commitConfiguration()
                return
            }

            if self.captureSession.canAddInput(input) {
                self.captureSession.addInput(input)
            }

            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
                self.applyVideoOrientation()
            }

            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func toggleRunning() {
        isRunning.toggle()
        if !isRunning {
            stopSpeech()
            DispatchQueue.main.async {
                self.guidanceText = nil
                self.detectedLineBoundingBox = nil
            }
        }
    }

    private func stopSpeech() {
        speechSynth.stopSpeaking(at: .immediate)
    }

    func speak(_ text: String) {
        let now = Date()
        if let last = lastGuidanceSpokenAt, now.timeIntervalSince(last) < 0.7 {
            return
        }
        lastGuidanceSpokenAt = now

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        speechSynth.speak(utterance)
    }

    private func startOrientationUpdates() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    @objc private func handleDeviceOrientationDidChange() {
        refreshVideoOrientation()
    }

    @MainActor
    func refreshVideoOrientation() {
        let interfaceOrientation = currentInterfaceOrientation() ?? .landscapeRight
        let captureOrientation = captureVideoOrientation(from: interfaceOrientation)
        if videoOrientation != captureOrientation {
            videoOrientation = captureOrientation
        }
        isLandscapeFlipped = interfaceOrientation == .landscapeLeft
        videoOutputDelegate.setImageOrientation(currentImageOrientation(from: interfaceOrientation))
        sessionQueue.async { [weak self] in
            self?.applyVideoOrientation()
        }
    }

    private func applyVideoOrientation() {
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoOrientationSupported
        else { return }

        connection.videoOrientation = videoOrientation
    }

    @MainActor
    private func currentInterfaceOrientation() -> UIInterfaceOrientation? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .interfaceOrientation
    }

    private func captureVideoOrientation(from interfaceOrientation: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
        switch interfaceOrientation {
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .landscapeRight
        }
    }

    private func currentImageOrientation(from interfaceOrientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        // Back camera mapping for Vision to match the on-screen orientation.
        switch interfaceOrientation {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeLeft:
            return .down
        case .landscapeRight:
            return .up
        default:
            return .right
        }
    }
}

@MainActor
private extension LineFollowerViewModel {
    func handleDetection(boundingBox: CGRect, guidance: String?) {
        let adjustedBox = isLandscapeFlipped
            ? CGRect(x: 1 - boundingBox.maxX,
                     y: boundingBox.minY,
                     width: boundingBox.width,
                     height: boundingBox.height)
            : boundingBox
        let adjustedGuidance: String?
        if isLandscapeFlipped {
            if guidance == "left" {
                adjustedGuidance = "right"
            } else if guidance == "right" {
                adjustedGuidance = "left"
            } else {
                adjustedGuidance = guidance
            }
        } else {
            adjustedGuidance = guidance
        }

        detectedLineBoundingBox = adjustedBox
        guidanceText = adjustedGuidance

        if let speakText = adjustedGuidance {
            speak(speakText)
        }
    }

    func handleNoDetection() {
        guidanceText = nil
        detectedLineBoundingBox = nil
    }
}

private final class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let model: VNCoreMLModel?
    private let isRunningLock = NSLock()
    private var isRunningSnapshot: Bool = false
    private let imageOrientationLock = NSLock()
    private var imageOrientationSnapshot: CGImagePropertyOrientation = .right
    private let onDetection: (CGRect, String?) -> Void
    private let onNoDetection: () -> Void

    init(onDetection: @escaping (CGRect, String?) -> Void,
         onNoDetection: @escaping () -> Void) {
        self.onDetection = onDetection
        self.onNoDetection = onNoDetection
        self.model = VideoOutputDelegate.loadModel()
        super.init()
    }

    func setIsRunning(_ value: Bool) {
        isRunningLock.lock()
        isRunningSnapshot = value
        isRunningLock.unlock()
    }

    func setImageOrientation(_ value: CGImagePropertyOrientation) {
        imageOrientationLock.lock()
        imageOrientationSnapshot = value
        imageOrientationLock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRunningThreadSafe() else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let model = model else { return }

        let orientation = imageOrientationThreadSafe()
        let request = VNCoreMLRequest(model: model) { [weak self] request, error in
            guard let self = self else { return }
            guard error == nil else { return }
            guard let results = request.results as? [VNRecognizedObjectObservation] else { return }

            let lineObservations = results.filter { $0.labels.contains(where: { $0.identifier == "line" }) }
            guard let topLineObservation = lineObservations.max(by: { $0.confidence < $1.confidence }) else {
                Task { @MainActor in
                    self.onNoDetection()
                }
                return
            }

            let boundingBox = topLineObservation.boundingBox
            let centerX = boundingBox.midX
            let deviation = centerX - 0.5

            var guidance: String? = nil
            if abs(deviation) < 0.05 {
                guidance = nil
            } else if deviation < 0 {
                guidance = "left"
            } else {
                guidance = "right"
            }

            Task { @MainActor in
                self.onDetection(boundingBox, guidance)
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation,
                                            options: [:])
        try? handler.perform([request])
    }

    private func isRunningThreadSafe() -> Bool {
        isRunningLock.lock()
        let value = isRunningSnapshot
        isRunningLock.unlock()
        return value
    }

    private func imageOrientationThreadSafe() -> CGImagePropertyOrientation {
        imageOrientationLock.lock()
        let value = imageOrientationSnapshot
        imageOrientationLock.unlock()
        return value
    }

    private static func loadModel() -> VNCoreMLModel? {
        // Attempt to locate the compiled Core ML model in the main bundle.
        // The new model file is "xgap_white_line 1.mlmodel".
        let modelResourceNames = ["xgap_white_line 1", "xgap_white_line_1"]
        for name in modelResourceNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
                continue
            }
            guard let coreMLModel = try? MLModel(contentsOf: url) else {
                continue
            }
            return try? VNCoreMLModel(for: coreMLModel)
        }
        return nil
    }

    
}

import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let videoOrientation: AVCaptureVideoOrientation

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        if let connection = uiView.videoPreviewLayer.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
