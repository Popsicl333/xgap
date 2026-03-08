// xgapApp.swift defines the app's entry point. It creates a window scene and sets ContentView
// as the root view, which in turn interacts with CameraManager to display the camera feed.
//

// MARK: - Imports
// SwiftUI: App lifecycle and window scene management
import SwiftUI
import UIKit

/// xgapApp is the application entry point.
/// - It declares the app lifecycle using SwiftUI's App protocol.
/// - It hosts ContentView in a WindowGroup so the UI can render.
/// - ContentView then observes CameraManager to manage camera permission and preview.
@main
struct xgapApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            // Set ContentView as the root view for this window scene.
            // ContentView will create/observe CameraManager and show the preview.
            ContentView()
                .environmentObject(LineFollowerViewModel())
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }
}
