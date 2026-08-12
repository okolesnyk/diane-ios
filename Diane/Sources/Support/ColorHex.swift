import SwiftUI

extension Color {
    /// Member colors arrive as "#RRGGBB" (server-validated); anything else
    /// falls back to gray rather than crashing a family's kiosk remote.
    init(hex: String) {
        var value: UInt64 = 0
        let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard text.count == 6, Scanner(string: text).scanHexInt64(&value) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Color {
    /// "#rrggbb" for the wire (members.color); nil when the picked color has
    /// no RGB reading. sRGB-clamped — the server validates ^#[0-9a-fA-F]{6}$.
    var hexString: String? {
        guard let components = UIColor(self).cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
        )?.components, components.count >= 3 else { return nil }
        let r = Int((max(0, min(1, components[0])) * 255).rounded())
        let g = Int((max(0, min(1, components[1])) * 255).rounded())
        let b = Int((max(0, min(1, components[2])) * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
