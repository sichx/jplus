import SwiftUI

/// Circular avatar with an initials fallback while loading or when the
/// avatar URL is missing or unreachable.
struct AvatarView: View {
    let url: URL?
    let initials: String?
    var size: CGFloat = 24

    init(user: JiraUser?, size: CGFloat = 24) {
        self.url = user?.avatarURL
        self.initials = user?.initials
        self.size = size
    }

    init(url: URL?, initials: String?, size: CGFloat = 24) {
        self.url = url
        self.initials = initials
        self.size = size
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(.tint.opacity(0.2))
                    if let initials, !initials.isEmpty {
                        Text(initials)
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.tint)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
