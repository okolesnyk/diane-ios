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

    private let rowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

    var body: some View {
        Group {
            switch items {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't reach the server", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
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
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("\(done) of \(rows.count)").font(.title3.weight(.bold))
                    Text("done").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    ProgressView(value: Double(done), total: Double(max(rows.count, 1)))
                        .tint(.green)
                        .frame(maxWidth: 140)
                }
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
            }
            TextField("Add an item", text: $draft)
                .focused($addFocused)
                .submitLabel(.done)
                .onSubmit { Task { await add() } }
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
            if ordered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
                    Text("Nothing here yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .listRowSeparator(.hidden)
            }
            ForEach(ordered, id: \.id) { item in
                row(item)
            }
            .onMove { source, destination in
                Task { await move(ordered, from: source, to: destination) }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 8, for: .scrollContent)
        .fontDesign(.rounded)
        .refreshable { await load() }
    }

    /// The day pages' row anatomy: hierarchical circle in a 44pt frame, and
    /// done = the whole row goes gray (owner 2026-08-08).
    private func row(_ item: Components.Schemas.ListItem) -> some View {
        Button {
            Task { await toggle(item) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(item.checked ? Color.green : Color.secondary)
                    .frame(width: 44, height: 44)
                Text(item.name)
                    .strikethrough(item.checked, color: .secondary)
                    .foregroundStyle(item.checked ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .grayscale(item.checked ? 1 : 0)
        .opacity(item.checked ? 0.6 : 1)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
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
