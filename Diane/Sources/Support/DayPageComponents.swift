import SwiftUI

/// Shared M9e day-page furniture: the mode banners, the locked-circle look,
/// and the hard-stop diagonal band tint (the web calendar's exact ideology —
/// solid for one owner, N hard bands for shared, never a smooth blend).

/// "Planning ahead" / "The record" — every non-today day opens with one.
struct DayModeNote: View {
    let phase: MyDayLogic.DayPhase

    var body: some View {
        // Past only: it explains why the circles are locked. The future's
        // "planning ahead" note is gone — the owner doesn't need telling.
        if phase == .past {
            Text("The record — read-only")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .listRowSeparator(.hidden)
        }
    }
}

/// The 10% member wash with HARD color stops per owner (owner-ruled shape).
func bandedTint(_ colors: [Color]) -> AnyShapeStyle? {
    guard !colors.isEmpty else { return nil }
    if colors.count == 1 { return AnyShapeStyle(colors[0].opacity(0.1)) }
    let n = colors.count
    var stops: [Gradient.Stop] = []
    for (index, color) in colors.enumerated() {
        stops.append(.init(color: color, location: CGFloat(index) / CGFloat(n)))
        stops.append(.init(color: color, location: CGFloat(index + 1) / CGFloat(n)))
    }
    return AnyShapeStyle(
        LinearGradient(gradient: Gradient(stops: stops), startPoint: .topLeading, endPoint: .bottomTrailing)
            .opacity(0.1)
    )
}

/// A check circle that LOOKS locked when it is locked (dashed, faded) —
/// a disabled circle must never be pixel-identical to a live one.
struct CheckCircle: View {
    let completed: Bool
    let late: Bool
    let locked: Bool
    let inFlight: Bool
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if inFlight {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(completed ? .green : late ? .red : .secondary)
                    .opacity(locked ? 0.55 : 1)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .disabled(locked || inFlight)
        .accessibilityLabel(completed ? "Completed" : locked ? "Locked" : "Not completed")
    }

    private var symbol: String {
        if completed { return "checkmark.circle.fill" }
        return locked ? "circle.dashed" : "circle"
    }
}
