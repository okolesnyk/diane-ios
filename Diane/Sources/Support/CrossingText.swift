import SwiftUI

/// A list row's label whose strike DRAWS itself across the text when
/// `crossed` flips, and retracts when it flips back (owner 2026-09-27: the
/// crossing should be seen happening, not just appear).
struct CrossingText: View {
    let text: String
    let crossed: Bool

    var body: some View {
        Text(text)
            .foregroundStyle(crossed ? Color.secondary : Color.primary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: crossed ? proxy.size.width : 0, height: 1.5)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: crossed)
    }
}
