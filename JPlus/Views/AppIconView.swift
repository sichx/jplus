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
