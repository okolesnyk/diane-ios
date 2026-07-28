import SwiftUI

/// The avatar disc used everywhere: member photo (a data-URL JPEG from the
/// api) inside a ring of the member's color, falling back to their initial
/// on a tinted disc.
struct MemberAvatarView: View {
    let name: String
    let colorHex: String
    let avatar: String?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            if let image = decodedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(hex: colorHex).opacity(0.25)
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: colorHex))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color(hex: colorHex), lineWidth: size > 36 ? 2.5 : 2))
    }

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private var decodedImage: UIImage? {
        guard let avatar,
              let comma = avatar.firstIndex(of: ","),
              avatar.hasPrefix("data:"),
              let data = Data(base64Encoded: String(avatar[avatar.index(after: comma)...]))
        else { return nil }
        return UIImage(data: data)
    }
}
