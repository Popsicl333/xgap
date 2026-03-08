// New ContentView with border overlay and triple-tap detection
import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var vm: LineFollowerViewModel
    @State private var announcedStart = false
    
    var body: some View {
        ZStack {
            CameraPreview(session: vm.captureSession, videoOrientation: vm.videoOrientation)
                .ignoresSafeArea()
            
            BorderOverlayView(color: vm.isRunning ? .green : .red, thickness: 10) {
                // Single tap fallback toggles running
                vm.toggleRunning()
            }
            .highPriorityGesture(
                TapGesture(count: 3)
                    .onEnded {
                        // Triple tap: toggle running and announce
                        let willRun = !vm.isRunning
                        vm.toggleRunning()
                        if willRun {
                            vm.guidanceText = "Start scanning"
                            vm.speak("Start scanning")
                        } else {
                            vm.guidanceText = "STOP"
                            vm.speak("STOP")
                        }
                    }
            )
            
            if let bbox = vm.detectedLineBoundingBox {
                // Draw a bounding box over the detected line (expects normalized coords; adapt mapping if needed)
                GeometryReader { geo in
                    let rect = CGRect(x: bbox.minX * geo.size.width,
                                      y: (1 - bbox.maxY) * geo.size.height,
                                      width: bbox.width * geo.size.width,
                                      height: bbox.height * geo.size.height)
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 4)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .animation(.easeInOut(duration: 0.2), value: rect)
                }
            }
            
            VStack {
                if let guidance = vm.guidanceText {
                    Text(guidance)
                        .padding()
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                }
                Spacer()
            }
        }
        .onAppear {
            vm.refreshVideoOrientation()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(LineFollowerViewModel())
}
