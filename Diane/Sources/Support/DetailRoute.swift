import DianeKit
import SwiftUI

/// What a row drills into. Nav rule 2: chore, event, member, app all PUSH —
/// so every page that lists rows pushes the same destinations and you can
/// open a chore or an event from anywhere (owner 2026-08-06).
enum DetailRoute: Hashable {
    case chore(Components.Schemas.ChoreOccurrence)
    case event(Components.Schemas.EventOccurrence)

    static func == (lhs: DetailRoute, rhs: DetailRoute) -> Bool {
        switch (lhs, rhs) {
        case (.chore(let l), .chore(let r)): l.id == r.id
        case (.event(let l), .event(let r)): l.id == r.id
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .chore(let occurrence):
            hasher.combine("chore")
            hasher.combine(occurrence.id)
        case .event(let occurrence):
            hasher.combine("event")
            hasher.combine(occurrence.id)
        }
    }
}

extension View {
    /// Mount the shared drill-downs on any page's NavigationStack.
    func dianeDetailDestinations(
        context: SignedInContext,
        members: [Components.Schemas.Member],
        onChanged: @escaping () -> Void
    ) -> some View {
        navigationDestination(for: DetailRoute.self) { route in
            switch route {
            case .chore(let occurrence):
                ChoreDetailView(
                    context: context,
                    occurrence: occurrence,
                    members: members,
                    onChanged: onChanged,
                    asPage: true
                )
            case .event(let occurrence):
                EventDetailView(
                    context: context,
                    occurrence: occurrence,
                    members: members,
                    onChanged: onChanged,
                    asPage: true
                )
            }
        }
    }
}

/// A row body that drills in when tapped. A plain Button, not a
/// NavigationLink: List stamps a disclosure chevron on links, and the
/// design's rows end in stars/facepiles, not chevrons. Kept separate from
/// the check circle so tapping the circle still completes.
struct DetailRow<Label: View>: View {
    let route: DetailRoute
    let open: (DetailRoute) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { open(route) } label: { label() }
            .buttonStyle(.plain)
    }
}
