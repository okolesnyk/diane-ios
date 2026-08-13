import DianeKit
import SwiftUI

/// The household grocery library (owner rule 2026-08-12: editable in place):
/// search both languages, tap an entry to rename either side, recolor, or
/// delete it. The tag button up top manages categories. Everything the
/// family ever adds lands here, so cleanup is a browse, not a hunt.
struct LibraryView: View {
    let context: SignedInContext
    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState

    @State private var entries: Loadable<[Components.Schemas.GroceryLibraryItem]> = .loading
    @State private var categories: [Components.Schemas.GroceryCategory] = []
    @State private var query = ""
    @State private var editing: Components.Schemas.GroceryLibraryItem?

    private let rowInsets = EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)
    private let furnitureInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

    var body: some View {
        Group {
            switch entries {
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
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    CategoriesView(context: context)
                } label: {
                    Image(systemName: "tag")
                }
                .accessibilityLabel("Categories")
            }
        }
        .task(id: signals.version(of: [.lists])) { await load() }
        .sheet(item: $editing) { entry in
            LibraryEditSheet(context: context, entry: entry, categories: categories) {
                Task { await load() }
            }
        }
    }

    private func listBody(_ rows: [Components.Schemas.GroceryLibraryItem]) -> some View {
        let groups = ListsLogic.libraryGroups(entries: rows, categories: categories, query: query)
        return List {
            TextField("Search the library", text: $query)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                .listRowInsets(furnitureInsets)
                .listRowSeparator(.hidden)
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
                    Text("No matches")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .listRowSeparator(.hidden)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries, id: \.id) { entry in
                        Button {
                            editing = entry
                        } label: {
                            HStack(spacing: 11) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.name).foregroundStyle(.primary)
                                    if !entry.altName.isEmpty {
                                        Text(entry.altName).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                if !entry.lastAmount.isEmpty {
                                    Text(entry.lastAmount).font(.caption).foregroundStyle(.tertiary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .listRowInsets(rowInsets)
                    }
                } header: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color(hex: group.category.color))
                            .frame(width: 8, height: 8)
                        Text(group.category.name)
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(2)
        .contentMargins(.top, 8, for: .scrollContent)
        .fontDesign(.rounded)
        .refreshable { await load() }
    }

    private func load() async {
        do {
            async let libraryCall = context.client.api.listGroceryLibrary(.init())
            async let categoriesCall = context.client.api.listGroceryCategories(.init())
            switch try await libraryCall {
            case .ok(let ok): entries = .loaded(try ok.body.json.items)
            case .unauthorized: appState.handleUnauthorized(); return
            default: if case .loading = entries { entries = .failed("Couldn\u{2019}t reach your home server.") }
            }
            if case .ok(let ok) = try await categoriesCall {
                categories = try ok.body.json.categories
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            if case .loading = entries { entries = .failed("Couldn\u{2019}t reach your home server.") }
        }
    }
}

/// Edit one library entry: both names, the category grid, Delete at the
/// bottom (confirmed — deleting library knowledge is a real loss; list rows
/// already placed keep their text either way).
private struct LibraryEditSheet: View {
    let context: SignedInContext
    let entry: Components.Schemas.GroceryLibraryItem
    let categories: [Components.Schemas.GroceryCategory]
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var altName = ""
    @State private var categoryID: String?
    @State private var confirmingDelete = false
    @State private var busy = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Українською", text: $altName)
                }
                Section {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(categories, id: \.id) { category in
                            Button {
                                categoryID = category.id
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
                                    if category.id == categoryID {
                                        RoundedRectangle(cornerRadius: 11)
                                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                Section {
                    Button("Delete from the library", role: .destructive) {
                        confirmingDelete = true
                    }
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            .alert("Delete \(entry.name)?", isPresented: $confirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: {
                Text("It leaves the library. Lists that already have it keep their rows.")
            }
            .onAppear {
                name = entry.name
                altName = entry.altName
                categoryID = entry.categoryId
            }
        }
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let body = Components.Schemas.GroceryLibraryUpdate(
            name: name.trimmingCharacters(in: .whitespaces),
            altName: altName.trimmingCharacters(in: .whitespaces),
            categoryId: categoryID
        )
        if case .ok? = try? await context.client.api.updateGroceryLibraryItem(
            .init(path: .init(id: entry.id), body: .json(body))
        ) {
            onChanged()
            dismiss()
        }
    }

    private func delete() async {
        if case .noContent? = try? await context.client.api.deleteGroceryLibraryItem(
            .init(path: .init(id: entry.id))
        ) {
            onChanged()
            dismiss()
        }
    }
}
