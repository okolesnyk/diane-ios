import DianeKit
import SwiftUI

/// Checklist and plain list — the same to-do rows (owner-settled): the add
/// field on TOP like the shopping lists, tap toggles, done sinks to the
/// bottom, hold-and-drag moves a row anywhere, swipe left deletes. The
/// checklist adds the slim "N of M done" line and the Reset arrow up top;
/// a plain list skips the status bar. Reset confirms in a centered alert.
struct TodoListView: View {
    let context: SignedInContext
    let listID: String
    let listName: String
    let isChecklist: Bool

    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState

    @State private var items: Loadable<[Components.Schemas.ListItem]> = .loading
    @State private var draft = ""
    @State private var confirmingReset = false
    @FocusState private var addFocused: Bool

    var body: some View {
        Group {
            switch items {
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
        .navigationTitle(listName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isChecklist {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        confirmingReset = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Reset checklist")
                }
            }
        }
        .task(id: signals.version(of: [.lists])) { await load() }
        .alert("Reset \(listName)?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset") { Task { await reset() } }
        } message: {
            Text("Uncheck every item. The list itself stays.")
        }
    }

    private func listBody(_ rows: [Components.Schemas.ListItem]) -> some View {
        let ordered = ListsLogic.todoOrder(rows)
        let done = rows.filter(\.checked).count
        return List {
            if isChecklist, !rows.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("\(done) of \(rows.count)").font(.title3.weight(.bold))
                            Text("done").font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(done), total: Double(max(rows.count, 1)))
                            .tint(.green)
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                TextField("Add an item", text: $draft)
                    .focused($addFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await add() } }
            }
            Section {
                ForEach(ordered, id: \.id) { item in
                    row(item)
                }
                .onMove { source, destination in
                    Task { await move(ordered, from: source, to: destination) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ item: Components.Schemas.ListItem) -> some View {
        Button {
            Task { await toggle(item) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(item.checked ? Color.green : Color(.tertiaryLabel))
                Text(item.name)
                    .strikethrough(item.checked)
                    .foregroundStyle(item.checked ? Color.secondary : Color.primary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { Task { await delete(item) } }
        }
    }

    // MARK: - Data

    private func load() async {
        do {
            switch try await context.client.api.getList(.init(path: .init(id: listID))) {
            case .ok(let ok): items = .loaded(try ok.body.json.items)
            case .unauthorized: appState.handleUnauthorized()
            default: if case .loading = items { items = .failed("Couldn\u{2019}t reach your home server.") }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            if case .loading = items { items = .failed("Couldn\u{2019}t reach your home server.") }
        }
    }

    private func add() async {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        draft = ""
        _ = try? await context.client.api.addListItem(.init(
            path: .init(id: listID),
            body: .json(.init(name: trimmed))
        ))
        await load()
        addFocused = true
    }

    private func toggle(_ item: Components.Schemas.ListItem) async {
        _ = try? await context.client.api.updateListItem(.init(
            path: .init(id: listID, itemId: item.id),
            body: .json(.init(checked: !item.checked))
        ))
        await load()
    }

    /// The drag lands in DISPLAYED terms; the server stores it as the manual
    /// order (done rows still render at the bottom afterwards).
    private func move(
        _ displayed: [Components.Schemas.ListItem],
        from source: IndexSet,
        to destination: Int
    ) async {
        let ids = ListsLogic.movedIds(displayed, from: source, to: destination)
        _ = try? await context.client.api.orderListItems(.init(
            path: .init(id: listID),
            body: .json(.init(itemIds: ids))
        ))
        await load()
    }

    private func delete(_ item: Components.Schemas.ListItem) async {
        _ = try? await context.client.api.deleteListItem(
            .init(path: .init(id: listID, itemId: item.id))
        )
        await load()
    }

    private func reset() async {
        _ = try? await context.client.api.resetList(.init(path: .init(id: listID)))
        await load()
    }
}
