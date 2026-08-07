import SwiftUI

/// Top bar, ONE convention (navigation doc rule 1): left the date or the
/// app's name — or ‹ Back once you're deeper; right your avatar on roots;
/// nothing else lives up there.
///
/// This is a plain view, not toolbar content, exactly like the mock's own
/// `.topbar` row — iOS 26 wraps leading toolbar items in glass capsules that
/// squeeze a date title down to "Th…". Root pages hide the system bar and
/// wear this; pushed pages keep the system bar for ‹ Back.
struct DianeTopBar: View {
    let context: SignedInContext
    let title: String
    /// Set only where tapping genuinely navigates — a title that can't do
    /// anything must not look like a button.
    var action: (() -> Void)?
    var chevron = false
    /// The transient Today pill, shown only when you've wandered off.
    var showToday = false
    var onToday: () -> Void = {}
    /// A popover anchored to the TITLE itself (the month/year jump picker) —
    /// attaching it to the bar centred it over the whole width.
    var popover: Binding<Bool>?
    var popoverContent: (() -> AnyView)?
    /// A page-level destination of the page's own, sitting just before the
    /// avatar — Chores puts History here (owner 2026-08-06). Rare by design:
    /// the bar stays title-left, avatar-right everywhere else.
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 8) {
            if let action {
                Button(action: action) { titleLabel }
                    .buttonStyle(.plain)
                    .popover(isPresented: popover ?? .constant(false), arrowEdge: .top) {
                        popoverContent?()
                    }
            } else {
                titleLabel
            }
            if showToday {
                Button("Today", action: onToday)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.mini)
            }
            Spacer(minLength: 8)
            if let trailing { trailing }
            NavigationLink {
                SettingsView(context: context, asPage: true)
            } label: {
                MemberAvatarView(
                    name: context.session.memberName,
                    colorHex: context.session.memberColor,
                    avatar: nil,
                    size: 32
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var titleLabel: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension View {
    /// Root pages own their bar; the system one steps aside.
    func dianeRootChrome() -> some View {
        toolbar(.hidden, for: .navigationBar)
    }
}
