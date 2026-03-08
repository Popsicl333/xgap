import SwiftUI

struct BorderOverlayView: View {
    let color: Color
    let thickness: CGFloat
    private let onTripleTap: () -> Void
    
    @State private var tapTimestamps: [TimeInterval] = []
    
    init(color: Color, thickness: CGFloat = 6, onTripleTap: @escaping () -> Void) {
        self.color = color
        self.thickness = thickness
        self.onTripleTap = onTripleTap
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(color)
                    .frame(height: thickness)
                    .frame(maxWidth: .infinity)
                    .alignmentGuide(.top) { _ in 0 }
                
                Rectangle()
                    .fill(color)
                    .frame(height: thickness)
                    .frame(maxWidth: .infinity)
                    .position(x: geo.size.width / 2, y: geo.size.height - thickness / 2)
                
                Rectangle()
                    .fill(color)
                    .frame(width: thickness)
                    .frame(maxHeight: .infinity)
                    .alignmentGuide(.leading) { _ in 0 }
                
                Rectangle()
                    .fill(color)
                    .frame(width: thickness)
                    .frame(maxHeight: .infinity)
                    .position(x: geo.size.width - thickness / 2, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 1)
                    .onEnded {
                        let now = Date().timeIntervalSinceReferenceDate
                        tapTimestamps.append(now)
                        
                        // Remove old taps beyond 0.8 seconds ago
                        tapTimestamps = tapTimestamps.filter { now - $0 <= 0.8 }
                        
                        if tapTimestamps.count >= 3 {
                            tapTimestamps.removeAll()
                            onTripleTap()
                        }
                    }
            )
        }
    }
}
