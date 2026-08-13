import DianeKit
import SwiftUI

/// The Lists module root (design pass rev 3): every list as a full-width row
/// — type glyph, name, badge — plus the ghost row that makes a new one.
/// Family-wide and admin-free: whoever holds the phone adds milk.
struct ListsView: View {
    let context: SignedInContext
    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState

    @State private var lists: Loadable<[Components.Schemas.List]> = .loading
    @State private var creating = false
    @State private var confirmingDelete: Components.Schemas.List?

    var body: some View {
        Group {
            switch lists {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ContentUnavailableView(
                    "Couldn't reach your home server",
                    systemImage: "wifi.exclamationmark"
                )
            case .loaded(let rows):
                listBody(rows)
            }
        }
        .task(id: signals.version(of: [.lists])) { await load() }
        .sheet(isPresented: $creating) {
            NewListSheet(context: context) { Task { await load() } }
        }
        .alert(
            "Delete \(confirmingDelete?.name ?? "")?",
            isPresented: .init(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            presenting: confirmingDelete
        ) { list in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await delete(list) } }
        } message: { list in
            Text(ListsLogic.badge(type: list._type, itemCount: list.itemCount, checkedCount: list.checkedCount) == "Empty"
                ? "It's empty — nothing else goes."
                : "Its items go with it. The grocery library keeps everything it learned.")
        }
    }

    private func listBody(_ rows: [Components.Schemas.List]) -> some View {
        List {
            ForEach(rows, id: \.id) { list in
                NavigationLink {
                    destination(list)
                } label: {
                    row(list)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { confirmingDelete = list }
                }
            }
            Button {
                creating = true
            } label: {
                Label("New list", systemImage: "plus")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func destination(_ list: Components.Schemas.List) -> some View {
        switch list._type {
        case .grocery:
            GroceryListView(context: context, listID: list.id, listName: list.name)
        case .checklist:
            TodoListView(context: context, listID: list.id, listName: list.name, isChecklist: true)
        case .plain:
            TodoListView(context: context, listID: list.id, listName: list.name, isChecklist: false)
        }
    }

    private func row(_ list: Components.Schemas.List) -> some View {
        HStack(spacing: 12) {
            Image(systemName: glyph(list._type))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint(list._type))
                .frame(width: 36, height: 36)
                .background(tint(list._type).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(list.name).font(.body.weight(.semibold))
                Text(ListsLogic.badge(
                    type: list._type,
                    itemCount: list.itemCount,
                    checkedCount: list.checkedCount
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func glyph(_ type: Components.Schemas.ListType) -> String {
        switch type {
        case .grocery: "cart"
        case .checklist: "checklist"
        case .plain: "list.bullet"
        }
    }

    private func tint(_ type: Components.Schemas.ListType) -> Color {
        switch type {
        case .grocery: Color(hex: "#2da44e")
        case .checklist: Color(hex: "#7c3aed")
        case .plain: .accentColor
        }
    }

    private func load() async {
        do {
            switch try await context.client.api.listLists(.init()) {
            case .ok(let ok): lists = .loaded(try ok.body.json.lists)
            case .unauthorized: appState.handleUnauthorized()
            default: if case .loading = lists { lists = .failed("Couldn\u{2019}t reach your home server.") }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            if case .loading = lists { lists = .failed("Couldn\u{2019}t reach your home server.") }
        }
    }

    private func delete(_ list: Components.Schemas.List) async {
        _ = try? await context.client.api.deleteList(.init(path: .init(id: list.id)))
        await load()
    }
}

/// The new-list sheet: pick a shape, name it (forms are sheets, house rule).
private struct NewListSheet: View {
    let context: SignedInContext
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var type: Components.Schemas.ListType = .grocery
    @State private var name = ""
    @State private var busy = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $type) {
                    Text("Grocery").tag(Components.Schemas.ListType.grocery)
                    Text("Checklist").tag(Components.Schemas.ListType.checklist)
                    Text("List").tag(Components.Schemas.ListType.plain)
                }
                .pickerStyle(.segmented)
                TextField("Name", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await create() } }
            }
            .navigationTitle("New list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            .onAppear { nameFocused = true }
        }
        .presentationDetents([.medium])
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        let body = Components.Schemas.ListCreate(_type: type, name: trimmed)
        if case .created? = try? await context.client.api.createList(.init(body: .json(body))) {
            onCreated()
            dismiss()
        }
    }
}

/// Chip rows that wrap — the hint chips under the grocery add field.
struct FlowLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? max(x - spacing, 0) : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
