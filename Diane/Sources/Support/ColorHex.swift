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
