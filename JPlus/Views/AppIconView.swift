import AppKit
import SwiftUI

/// The app's own icon, for in-app branding (sign-in screens, loading).
struct AppIconView: View {
    var size: CGFloat = 72

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Flat, single-colour "J" from the app icon, for quiet in-app branding.
/// Fill it with any style, e.g. `.foregroundStyle(.secondary)`.
nonisolated struct JPlusMark: Shape {
    // Geometry from Design/jplus-icon.svg (1024 canvas): a round-capped
    // stroke 124 wide along a stem and a half-circle hook.
    private static let strokeWidth: CGFloat = 124
    private static let bounds = CGRect(x: 284, y: 194, width: 424, height: 614)

    func path(in rect: CGRect) -> Path {
        var centerline = Path()
        centerline.move(to: CGPoint(x: 646, y: 256))
        centerline.addLine(to: CGPoint(x: 646, y: 596))
        // Half circle (radius 150, centre 496,596) down and round to the left,
        // as two cubic curves.
        let k: CGFloat = 0.5523 * 150
        centerline.addCurve(to: CGPoint(x: 496, y: 746),
                            control1: CGPoint(x: 646, y: 596 + k),
                            control2: CGPoint(x: 496 + k, y: 746))
        centerline.addCurve(to: CGPoint(x: 346, y: 596),
                            control1: CGPoint(x: 496 - k, y: 746),
                            control2: CGPoint(x: 346, y: 596 + k))
        let outline = centerline.strokedPath(StrokeStyle(lineWidth: Self.strokeWidth, lineCap: .round))

        let scale = min(rect.width / Self.bounds.width, rect.height / Self.bounds.height)
        let size = CGSize(width: Self.bounds.width * scale, height: Self.bounds.height * scale)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        let transform = CGAffineTransform(translationX: -Self.bounds.minX, y: -Self.bounds.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
        return outline.applying(transform)
    }
}
