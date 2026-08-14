import DianeKit
import SwiftUI

/// One grocery list (design pass rev 3 + history model, owner 2026-08-12):
/// the add field lives at the top and never pushes a page — typing filters
/// the library into colored hint chips (tap = added; checkmark chip =
/// already active; Enter adds anything unknown straight under Other, one
/// step). Rows group by category and walk the aisles; tapping a row crosses
/// it into HISTORY at the bottom — nothing is deleted at checkout. History
/// rows resurrect by tap or by re-adding the name (the server dedupes).
/// The amount pill edits through a centered alert; swiping left refiles
/// (teaching the library) or deletes for real. The book opens the library.
struct GroceryListView: View {
    let context: SignedInContext
    let listID: String
    let listName: String

    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState

    @State private var items: Loadable<[Components.Schemas.ListItem]> = .loading
    @State private var categories: [Components.Schemas.GroceryCategory] = []
    @State private var library: [Components.Schemas.GroceryLibraryItem] = []
    @State private var query = ""
    @State private var amountEditing: Components.Schemas.ListItem?
    @State private var amountDraft = ""
    @State private var refiling: Components.Schemas.ListItem?
    @FocusState private var addFocused: Bool

    private let rowInsets = EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)
    private let furnitureInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

    var body: some View {
        GeometryReader { geo in
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
                    listBody(rows, screenHeight: geo.size.height)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { OfflinePill(center: context.offline) }
        .navigationTitle(listName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    LibraryView(context: context)
                } label: {
                    Image(systemName: "book")
                }
                .accessibilityLabel("Library")
            }
        }
        .task(id: signals.version(of: [.lists])) { await load() }
        // Amount: free text on a pill, edited in a centered alert (house rule).
        .alert("Amount", isPresented: .init(
            get: { amountEditing != nil },
            set: { if !$0 { amountEditing = nil } }
        ), presenting: amountEditing) { item in
            TextField("2 · 1 kg · 3 packs", text: $amountDraft)
            Button("Cancel", role: .cancel) {}
            Button("Set") { Task { await setAmount(item, to: amountDraft) } }
        } message: { item in
            Text(item.name)
        }
        .sheet(item: $refiling) { item in
            CategoryPickSheet(categories: categories, selected: item.categoryId) { categoryID in
                Task { await refile(item, to: categoryID) }
            }
        }
    }

    // MARK: - Body

    private func listBody(_ rows: [Components.Schemas.ListItem], screenHeight: CGFloat) -> some View {
        let groups = ListsLogic.grouped(items: rows, categories: categories)
        let history = rows.filter(\.checked)
        return List {
            addSection(rows)
            if rows.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
                    Text("Type above to add the first item")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .listRowSeparator(.hidden)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items, id: \.id) { item in
                        itemRow(item)
                    }
                } header: {
                    categoryHeader(group.category)
                }
            }
            if !history.isEmpty {
                // History sits LOW (owner 2026-08-12, reference app): its top
                // never rises above ~30%-from-the-bottom. A short list gets
                // this clear runway; a long list pushes history further down.
                Color.clear
                    .frame(height: historyRunway(groups: groups, screenHeight: screenHeight))
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                historySection(history)
            }
        }
        .listStyle(.plain)
        // Tight sections: with one item per aisle the default chrome ate
        // half the screen (owner 2026-08-12, on device; "smaller" pass 2).
        .listSectionSpacing(2)
        // List's own row-height floor (~44pt, larger with bigger text
        // settings) otherwise swallows the rows' shorter minHeight.
        .environment(\.defaultMinListRowHeight, 34)
        .contentMargins(.top, 8, for: .scrollContent)
        .fontDesign(.rounded)
        .refreshable { await load() }
    }

    @ViewBuilder
    private func addSection(_ rows: [Components.Schemas.ListItem]) -> some View {
        // Only ACTIVE rows count as "on the list" — a history match must
        // stay a live chip so tapping it resurrects (the server dedupes).
        let hints = ListsLogic.hints(
            query: query,
            library: library,
            listNames: rows.filter { !$0.checked }.map(\.name)
        )
        let exact = ListsLogic.exactMatch(query: query, library: library)
        TextField("Add or search", text: $query)
            .focused($addFocused)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit { Task { await addFromEnter() } }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
            .listRowInsets(furnitureInsets)
            .listRowSeparator(.hidden)
        if !hints.isEmpty || (exact == nil && !query.trimmingCharacters(in: .whitespaces).isEmpty) {
            FlowLayout(spacing: 8) {
                ForEach(hints) { hint in
                    hintChip(hint)
                }
                if exact == nil, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    addChip()
                }
            }
            .listRowInsets(furnitureInsets)
            .listRowSeparator(.hidden)
        }
    }

    private func hintChip(_ hint: ListsLogic.Hint) -> some View {
        let color = categories.first { $0.id == hint.entry.categoryId }?.color ?? "#9a9fa8"
        return Button {
            guard !hint.onList else { return }
            Task { await add(entry: hint.entry) }
        } label: {
            // Already on the list: neutral and quiet, never a faded color
            // chip — white on washed-out pink was unreadable (owner
            // 2026-08-12, on device).
            if hint.onList {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                    Text(hint.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text(hint.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Color(hex: color), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .buttonStyle(.plain)
        .disabled(hint.onList)
    }

    private func addChip() -> some View {
        Button {
            Task { await addFromEnter() }
        } label: {
            Text("+ Add \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4]))
                        .foregroundStyle(.tertiary)
                )
        }
        .buttonStyle(.plain)
    }

    /// Text-only and tiny — the category color now rides every ROW as its
    /// trailing line (owner 2026-08-12), so the header dot went with it.
    private func categoryHeader(_ category: Components.Schemas.GroceryCategory) -> some View {
        Text(category.name)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
    }

    /// Whole-row tap crosses into history (owner-settled: the row IS the
    /// checkbox — groceries have no detail to open). Each row wears its
    /// category color as a full-height bar hugging the LEFT screen edge —
    /// the reference app's language (owner 2026-08-12, screenshot).
    private func itemRow(_ item: Components.Schemas.ListItem) -> some View {
        Button {
            Task { await setChecked(item, to: true) }
        } label: {
            HStack(spacing: 11) {
                Text(item.name)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Button {
                    amountDraft = item.amount
                    amountEditing = item
                } label: {
                    amountPill(item.amount)
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .listRowInsets(rowInsets)
        // The bar lives on the row BACKGROUND, so it spans the row's full
        // height and sits at the true edge, outside the content insets.
        .listRowBackground(edgeBar(item))
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { Task { await delete(item) } }
            Button("Category") { refiling = item }.tint(Color(hex: "#5352d1"))
        }
    }

    /// The empty runway that keeps HISTORY's top edge at or below the
    /// 70%-of-screen line. Estimated from the standard row metrics (add
    /// field 56, header ~24, row ~38.5) — exact enough at default type
    /// sizes; Dynamic Type users simply get a shorter runway.
    private func historyRunway(
        groups: [ListsLogic.CategoryGroup],
        screenHeight: CGFloat
    ) -> CGFloat {
        let activeRows = groups.reduce(0) { $0 + $1.items.count }
        let estimated = 56.0 + CGFloat(groups.count) * 24.0 + CGFloat(activeRows) * 38.5
        return max(0, screenHeight * 0.7 - estimated)
    }

    /// Full-height category bar at the leading screen edge.
    private func edgeBar(_ item: Components.Schemas.ListItem) -> some View {
        let color = categories.first { $0.id == item.categoryId }?.color ?? "#9a9fa8"
        return HStack(spacing: 0) {
            Color(hex: color).frame(width: 5)
            Color.clear
        }
    }

    private func amountPill(_ amount: String) -> some View {
        Group {
            if amount.isEmpty {
                Text("+ amt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(
                        Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                            .foregroundStyle(.quaternary)
                    )
            } else {
                Text(amount)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        }
    }

    /// Crossed rows are HISTORY, not a cart (owner 2026-08-12): everything
    /// that was ever on the list waits here. The zone reads clearly apart
    /// from the live list — gray panel rows, no color bars, like the
    /// reference app's bottom strip. Tapping one puts it straight back;
    /// only the swipe deletes it for real.
    private func historySection(_ history: [Components.Schemas.ListItem]) -> some View {
        Section {
            ForEach(history, id: \.id) { item in
                Button {
                    Task { await setChecked(item, to: false) }
                } label: {
                    HStack(spacing: 10) {
                        Text(item.name)
                            .strikethrough(true, color: .secondary)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if !item.amount.isEmpty {
                            Text(item.amount).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .grayscale(1)
                .opacity(0.7)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .listRowInsets(rowInsets)
                .listRowBackground(Color(.secondarySystemBackground))
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { Task { await delete(item) } }
                }
            }
        } header: {
            // Not a category — keeps its size (owner: "only categories
            // should get smaller").
            Text("History")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 4, trailing: 16))
        }
    }

    // MARK: - Data

    private func load() async {
        do {
            async let detailCall = context.client.api.getList(.init(path: .init(id: listID)))
            async let categoriesCall = context.client.api.listGroceryCategories(.init())
            async let libraryCall = context.client.api.listGroceryLibrary(.init())
            switch try await detailCall {
            case .ok(let ok): items = .loaded(try ok.body.json.items)
            case .unauthorized: appState.handleUnauthorized(); return
            default: if case .loading = items { items = .failed("Couldn\u{2019}t reach your home server.") }
            }
            if case .ok(let ok) = try await categoriesCall {
                categories = try ok.body.json.categories
            }
            if case .ok(let ok) = try await libraryCall {
                library = try ok.body.json.items
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            if case .loading = items { items = .failed("Couldn\u{2019}t reach your home server.") }
        }
    }

    /// Hint tap: the tapped language lands on the list; the entry's own
    /// category rides along (the server would resolve it anyway).
    private func add(entry: Components.Schemas.GroceryLibraryItem) async {
        let name = ListsLogic.addName(query: query, entry: entry)
        query = ""
        await post(name: name, categoryID: entry.categoryId)
        addFocused = true
    }

    /// Enter / "+ Add": one step — the server resolves a match in either
    /// language, or files it under Other and learns it.
    private func addFromEnter() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        query = ""
        await post(name: trimmed, categoryID: nil)
        addFocused = true
    }

    private func post(name: String, categoryID: String?) async {
        let body = Components.Schemas.ListItemCreate(name: name, categoryId: categoryID)
        _ = try? await context.client.api.addListItem(
            .init(path: .init(id: listID), body: .json(body))
        )
        await load()
    }

    private func setChecked(_ item: Components.Schemas.ListItem, to checked: Bool) async {
        _ = try? await context.client.api.updateListItem(.init(
            path: .init(id: listID, itemId: item.id),
            body: .json(.init(checked: checked))
        ))
        await load()
    }

    private func setAmount(_ item: Components.Schemas.ListItem, to amount: String) async {
        _ = try? await context.client.api.updateListItem(.init(
            path: .init(id: listID, itemId: item.id),
            body: .json(.init(amount: amount.trimmingCharacters(in: .whitespaces)))
        ))
        await load()
    }

    private func refile(_ item: Components.Schemas.ListItem, to categoryID: String) async {
        refiling = nil
        _ = try? await context.client.api.updateListItem(.init(
            path: .init(id: listID, itemId: item.id),
            body: .json(.init(categoryId: categoryID))
        ))
        await load()
    }

    private func delete(_ item: Components.Schemas.ListItem) async {
        _ = try? await context.client.api.deleteListItem(
            .init(path: .init(id: listID, itemId: item.id))
        )
        await load()
    }
}

/// The color grid, shared by swipe-refile and the library editor: every
/// category as a colored tile; picking is the save.
struct CategoryPickSheet: View {
    let categories: [Components.Schemas.GroceryCategory]
    let selected: String?
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(categories, id: \.id) { category in
                        Button {
                            onPick(category.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Spacer()
                                Text(category.name)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .shadow(radius: 1)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .bottomLeading)
                            .background(Color(hex: category.color), in: RoundedRectangle(cornerRadius: 11))
                            .overlay {
                                if category.id == selected {
                                    RoundedRectangle(cornerRadius: 11)
                                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
