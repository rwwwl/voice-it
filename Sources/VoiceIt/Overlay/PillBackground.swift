import AppKit
import SwiftUI

/// The glass look lives only here, so it can be swapped for native Liquid Glass on macOS 26.
struct PillMaterial: View {
    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow)
            Color(red: 16 / 255, green: 18 / 255, blue: 30 / 255).opacity(0.28)   // dark tint
            // soft diagonal sheen
            LinearGradient(stops: [
                .init(color: .white.opacity(0.20), location: 0),
                .init(color: .white.opacity(0), location: 0.36),
                .init(color: .white.opacity(0), location: 0.72),
                .init(color: .white.opacity(0.07), location: 1),
            ], startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1))
            // thin bright edge: stronger along the top
            Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .clipShape(Capsule())
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)   // night-mode look regardless of the system appearance
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Soft shadow and the warm outer glow, drawn only outside the capsule so they never tint the glass.
struct PillGlow: View {
    var glow: Double   // 0...1, rises with voice level
    var body: some View {
        ZStack {
            Capsule().fill(.black)
                .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 8)
                .shadow(color: Color(red: 1, green: 0.63, blue: 0.43).opacity(0.06 + 0.26 * glow), radius: 6 + 24 * glow)
        }
        .mask(OutsideCapsule().fill(style: FillStyle(eoFill: true)))
    }
}

private struct OutsideCapsule: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect.insetBy(dx: -200, dy: -200))
        p.addPath(Capsule().path(in: rect))
        return p
    }
}
