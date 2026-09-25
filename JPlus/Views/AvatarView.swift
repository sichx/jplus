import SwiftUI

/// Circular user avatar with an initials fallback while loading or when
/// the avatar URL is missing or unreachable.
struct AvatarView: View {
    let user: JiraUser?
    var size: CGFloat = 24

    var body: some View {
        AsyncImage(url: user?.avatarURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(.tint.opacity(0.2))
                    if let user {
                        Text(user.initials)
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
