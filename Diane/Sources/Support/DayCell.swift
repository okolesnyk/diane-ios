import SwiftUI

/// ONE day cell for every page that shows days: the Today page's
/// 7-day strips, and the Calendar's week row and month grid. Same weekday
/// grammar, same selection pill, same dots — a day looks like a day
/// everywhere (owner 2026-08-06: "consistency is key").
struct DayCell: View {
    let date: String
    /// "Wed" — omitted where a shared Sun–Sat header row already names it.
    var weekday: String?
    let isSelected: Bool
    let isToday: Bool
    /// Filler days from a neighbouring month render dim.
    var dim = false
    var hasEvents = false
    var hasChores = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                if let weekday {
                    Text(weekday)
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(isToday ? Color.accentColor : .secondary)
                }
                Text(String(Int(date.suffix(2)) ?? 0))
                    .font(.callout.weight(isSelected ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(
                        isSelected ? .white
                            : isToday ? Color.accentColor
                            : dim ? Color.secondary.opacity(0.5) : .primary
                    )
                    .frame(width: 34, height: 34)
                    .background(
                        isSelected ? Color.accentColor : .clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                HStack(spacing: 3) {
                    if hasEvents { Circle().fill(.blue).frame(width: 4, height: 4) }
                    if hasChores { Circle().fill(.orange).frame(width: 4, height: 4) }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(date)\(isToday ? ", today" : "")\(isSelected ? ", selected" : "")"
                + "\(hasEvents ? ", has events" : "")\(hasChores ? ", has chores" : "")"
        )
    }
}

/// The week strip shared by the day pages: the week containing the
/// selected day, exactly like the Calendar's row. Tapping a day never moves
/// the week; swiping the strip pages a whole week (owner 2026-08-06).
struct DayStrip: View {
    let day: String
    let today: String
    /// Per-day load preview.
    let dots: (String) -> DayLogic.DayDots
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DayLogic.weekDays(containing: day)) { stripDay in
                let d = dots(stripDay.date)
                DayCell(
                    date: stripDay.date,
                    weekday: stripDay.weekdayInitial,
                    isSelected: stripDay.date == day,
                    isToday: stripDay.date == today,
                    hasEvents: d.hasEvents,
                    hasChores: d.hasChores
                ) {
                    onSelect(stripDay.date)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        // Swipe the STRIP (not the page — rows own their swipes) to page
        // weeks. You land on the day nearest to where you came from: the
        // next week's FIRST day, the previous week's LAST (owner 2026-08-08
        // — supersedes "the same weekday stays selected").
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                onSelect(DayLogic.pagedStripTarget(
                    from: day,
                    forward: value.translation.width < 0
                ))
            }
        )
    }
}
