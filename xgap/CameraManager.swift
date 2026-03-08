// CameraManager.swift contains the camera pipeline for the app: it requests permission, configures
// and controls an AVCaptureSession, and exposes a SwiftUI-friendly preview view. ContentView drives
// this manager (requesting access, starting/stopping), and xgapApp sets ContentView as the root.
//

//
//  CameraManager.swift
//  xgap
//
//  Created by Assistant on 2/12/26.
//

// MARK: - Imports
// Foundation: core types and concurrency primitives
// AVFoundation: camera session, devices, inputs/outputs
// SwiftUI: for UIViewRepresentable bridging and observation
// Combine: ObservableObject and @Published for UI state updates
// UIKit: UIView hosting for the preview layer

import Foundation
import AVFoundation
import SwiftUI
import Combine
import UIKit

/// CameraManager is responsible for:
/// - Requesting camera permission and reflecting authorization state to the UI
/// - Creating/configuring an AVCaptureSession on a background queue
/// - Starting/stopping the session based on view lifecycle
/// - Exposing a session for preview via CameraPreviewView
///
/// Interactions:
/// - ContentView holds and observes CameraManager.shared, calls request/start/stop.
/// - CameraPreviewView reads manager.session to render the live feed with AVCaptureVideoPreviewLayer.
final class CameraManager: ObservableObject {
    // Singleton instance so multiple views (if any) share the same camera session/state.
    static let shared = CameraManager()

    // Indicates whether the user has granted camera access; drives permission overlay in the UI.
    @Published private(set) var isAuthorized: Bool = false
    // Indicates whether the capture session is currently running; useful for UI state or debugging.
    @Published private(set) var isRunning: Bool = false

    /*
     The shared AVCaptureSession coordinating inputs/outputs.
     Marked nonisolated(unsafe) to allow access from both the main/UI thread (for preview)
     and the background session queue (for configuration/start/stop) without strict concurrency warnings.
     */
    nonisolated(unsafe) let session = AVCaptureSession()
    // Dedicated serial queue for all AVFoundation work to avoid blocking the main thread and to serialize session access.
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")

    // Keep a reference to the active video input (camera) for potential future adjustments (e.g., switching cameras).
    private var videoDeviceInput: AVCaptureDeviceInput?

    // Private init enforces the singleton pattern; use CameraManager.shared to access.
    private init() { }

    /// Requests camera permission if needed and configures the session once authorized.
    /// - Called by ContentView on appear (.task).
    /// - Updates isAuthorized on the main actor so SwiftUI can react immediately.
    /// - Defers heavy session setup to the background session queue.
    func requestAccessAndConfigure() async {
        // Determine current authorization state for video capture.
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            // Already authorized: reflect state to UI and configure the session.
            await MainActor.run { self.isAuthorized = true }
            await configureSessionIfNeeded()
        case .notDetermined:
            // Ask the user for permission asynchronously; resume when a choice is made.
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            await MainActor.run { self.isAuthorized = granted }
            if granted { await configureSessionIfNeeded() }
        default:
            // Denied/Restricted: reflect lack of authorization; skip configuration.
            await MainActor.run { self.isAuthorized = false }
        }
    }

    /// Configures the capture session exactly once by adding a video input and a video data output.
    /// Heavy work is performed on sessionQueue; this method bridges via withCheckedContinuation.
    private func configureSessionIfNeeded() async {
        // Avoid reconfiguration if inputs/outputs are already present.
        guard session.inputs.isEmpty && session.outputs.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Perform session configuration on the dedicated background queue.
            sessionQueue.async {
                // Begin a configuration block to batch changes to the session.
                self.session.beginConfiguration()
                // Choose a quality preset appropriate for live preview.
                self.session.sessionPreset = .high

                // Attempt to locate and add a camera device as the session's video input.
                do {
                    // Prefer the back wide-angle camera; fall back if unavailable.
                    let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                        ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                    guard let device else { throw NSError(domain: "Camera", code: -1, userInfo: [NSLocalizedDescriptionKey: "No camera available"]) }
                    // Wrap the device in an AVCaptureDeviceInput to attach to the session.
                    let input = try AVCaptureDeviceInput(device: device)
                    // Only add the input if supported by the session configuration.
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.videoDeviceInput = input
                    }
                } catch {
                    // Log any errors to help diagnose configuration problems (e.g., no camera on device).
                    print("Camera input error: \(error)")
                }

                // Add a video data output (optional if only preview is needed); useful for future frame processing.
                let videoOutput = AVCaptureVideoDataOutput()
                // Drop late frames to keep latency low and avoid backpressure during processing.
                videoOutput.alwaysDiscardsLateVideoFrames = true
                // Only add the output if supported by the current session configuration.
                if self.session.canAddOutput(videoOutput) {
                    self.session.addOutput(videoOutput)
                }

                // Commit all pending configuration changes to the session.
                self.session.commitConfiguration()
                continuation.resume()
            }
        }
    }

    /// Starts the capture session on the background queue and updates UI state on the main actor.
    func startRunning() {
        // Prevent redundant start calls if the session is already running.
        guard !isRunning else { return }
        // Interact with AVCaptureSession on the dedicated background queue.
        sessionQueue.async {
            // Start the underlying capture session if needed.
            if !self.session.isRunning {
                self.session.startRunning()
            }
            // Reflect the running state back to the UI on the main thread.
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    /// Stops the capture session on the background queue and updates UI state on the main actor.
    func stopRunning() {
        // Prevent redundant stop calls if the session is already stopped.
        guard isRunning else { return }
        // Interact with AVCaptureSession on the dedicated background queue.
        sessionQueue.async {
            // Stop the underlying capture session if it is currently running.
            if self.session.isRunning {
                self.session.stopRunning()
            }
            // Reflect the stopped state back to the UI on the main thread.
            DispatchQueue.main.async { self.isRunning = false }
        }
    }
}

/// CameraPreviewView bridges SwiftUI and AVFoundation by hosting an AVCaptureVideoPreviewLayer
/// inside a UIKit UIView. It reads manager.session (from CameraManager) to display the live feed.
struct CameraPreviewView: UIViewRepresentable {
    // Observe CameraManager so UI can react to state changes if needed (e.g., authorization).
    @ObservedObject var manager: CameraManager

    // Create the underlying UIView and attach an AVCaptureVideoPreviewLayer bound to the session.
    func makeUIView(context: Context) -> UIView {
        // Host view for the preview layer; acts as the container in SwiftUI layouts.
        let view = UIView()
        // Create a preview layer that renders frames from the capture session managed by CameraManager.
        let previewLayer = AVCaptureVideoPreviewLayer(session: manager.session)
        // Fill the container while preserving aspect ratio (common for camera UIs).
        previewLayer.videoGravity = .resizeAspectFill
        // Initialize the layer's frame to match the container's current bounds.
        previewLayer.frame = view.bounds
        // Let the layer redraw when bounds change (e.g., rotation, layout updates).
        previewLayer.needsDisplayOnBoundsChange = true
        // Insert the preview layer into the view's layer hierarchy so it's visible.
        view.layer.addSublayer(previewLayer)
        // Keep a reference to update its frame later in updateUIView.
        context.coordinator.previewLayer = previewLayer
        return view
    }

    // Keep the preview layer sized to the latest view bounds whenever SwiftUI relayouts.
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.previewLayer?.frame = uiView.bounds
    }

    // Create a Coordinator to hold references not managed directly by SwiftUI.
    func makeCoordinator() -> Coordinator { Coordinator() }

    // Coordinator stores the preview layer instance so we can adjust it during updates.
    final class Coordinator {
        // The AVCaptureVideoPreviewLayer used to display the live camera feed.
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

