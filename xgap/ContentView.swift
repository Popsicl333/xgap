// ContentView.swift defines the main UI screen that displays the live camera preview
// and an overlay explaining permission state. It observes CameraManager to drive behavior.
// This is a legacy implementation.
//
//  ContentView.swift
//  xgap
//
//  Created by Daniel Hong on 2/12/26.
//

// MARK: - Imports
// SwiftUI: Declarative UI framework
// AVFoundation: Camera-related types referenced by the preview view
import SwiftUI
import AVFoundation
import Combine

/// ContentView is the app's primary screen. It:
/// - Observes CameraManager.shared for authorization/running state
/// - Shows CameraPreviewView to render the live camera feed
/// - Requests permission/configures the session on appear, and stops it on disappear
struct LegacyContentView: View {
    // Own a single, observable instance of CameraManager for this view lifecycle.
    // Using the shared singleton ensures consistent session/state across the app.
    @StateObject private var camera = CameraManager.shared
    
    // Define the view hierarchy and behavior.
    var body: some View {
        ZStack {
            // Render the live camera feed using a SwiftUI wrapper around AVCaptureVideoPreviewLayer.
            CameraPreviewView(manager: camera)
                // Make the preview extend under system safe areas for a full-bleed look.
                .ignoresSafeArea()

            // If camera permission isn't granted, show an explanatory overlay.
            if !camera.isAuthorized {
                // Vertical stack with icon and text guiding the user to enable camera access.
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48))
                    Text("Camera access is required")
                        .font(.headline)
                    Text("Please grant permission in Settings to show the camera feed.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                // Inner padding for readability and touch-friendly spacing.
                .padding()
                // Translucent material background for contrast over the live preview.
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                // Outer padding to avoid screen edges.
                .padding()
            }
        }
        // On appear, request permission, configure, and start the session if authorized.
        .task {
            // Ask the manager to handle authorization and one-time session setup.
            await camera.requestAccessAndConfigure()
            // If authorized, begin running the capture session so the preview displays frames.
            if camera.isAuthorized {
                camera.startRunning()
            }
        }
        // On disappear, stop the session to conserve resources.
        .onDisappear {
            camera.stopRunning()
        }
    }
}

// MARK: - Xcode Preview
// Preview for design-time layout inspection (no live camera content in canvas).
#Preview {
    LegacyContentView()
}

