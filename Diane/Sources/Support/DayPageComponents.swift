import SwiftUI

/// Shared M9e day-page furniture: the mode banners, the locked-circle look,
/// and the hard-stop diagonal band tint (the web calendar's exact ideology —
/// solid for one owner, N hard bands for shared, never a smooth blend).

/// "Planning ahead" / "The record" — every non-today day opens with one.
struct DayModeNote: View {
    let phase: DayLogic.DayPhase

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

/// The member-wash strength: 10% carries on white but vanishes on black,
/// so dark mode runs hotter while keeping the same hue (owner 2026-08-08).
func washOpacity(_ scheme: ColorScheme) -> Double {
    scheme == .dark ? 0.28 : 0.1
}

/// The member wash with HARD color stops per owner (owner-ruled shape).
func bandedTint(_ colors: [Color], opacity: Double = 0.1) -> AnyShapeStyle? {
    guard !colors.isEmpty else { return nil }
    if colors.count == 1 { return AnyShapeStyle(colors[0].opacity(opacity)) }
    let n = colors.count
    var stops: [Gradient.Stop] = []
    for (index, color) in colors.enumerated() {
        stops.append(.init(color: color, location: CGFloat(index) / CGFloat(n)))
        stops.append(.init(color: color, location: CGFloat(index + 1) / CGFloat(n)))
    }
    return AnyShapeStyle(
        LinearGradient(gradient: Gradient(stops: stops), startPoint: .topLeading, endPoint: .bottomTrailing)
            .opacity(opacity)
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
    /// An unowned chore: dashed but LIVE — tap it to do it and keep the
    /// stars. Colorless, exactly like the Today page's pool language.
    var pool = false
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
        return locked || pool ? "circle.dashed" : "circle"
    }
}

/// The dashed hint between the day's dated business and the anytimers
/// folded under the bold Today section (owner 2026-08-10) — a whisper of
/// separation, not a full section break.
struct AnytimeHintRow: View {
    var body: some View {
        AnytimeHintLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(.quaternary)
            .frame(height: 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }
}

private struct AnytimeHintLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
