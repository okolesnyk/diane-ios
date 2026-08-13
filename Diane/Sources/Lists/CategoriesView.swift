import DianeKit
import SwiftUI

/// The category manager (owner ruling 2026-08-12: Library → tag icon):
/// "+ New category" makes a custom one from a name and a color swatch; any
/// category renames or recolors; only custom ones delete — their items and
/// library entries fall back to Other, so the fallback always exists.
struct CategoriesView: View {
    let context: SignedInContext
    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState

    @State private var categories: Loadable<[Components.Schemas.GroceryCategory]> = .loading
    @State private var creating = false
    @State private var editing: Components.Schemas.GroceryCategory?

    private let rowInsets = EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)

    var body: some View {
        Group {
            switch categories {
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
                List {
                    ForEach(rows, id: \.id) { category in
                        Button {
                            editing = category
                        } label: {
                            HStack(spacing: 11) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(hex: category.color))
                                    .frame(width: 16, height: 16)
                                Text(category.name).foregroundStyle(.primary)
                                Spacer(minLength: 0)
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
                    // The ghost row every module uses for "make a new one".
                    Button { creating = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("New category")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                .foregroundStyle(.tertiary)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .contentMargins(.top, 8, for: .scrollContent)
                .fontDesign(.rounded)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: signals.version(of: [.lists])) { await load() }
        .sheet(isPresented: $creating) {
            CategoryFormSheet(context: context, category: nil) { Task { await load() } }
        }
        .sheet(item: $editing) { category in
            CategoryFormSheet(context: context, category: category) { Task { await load() } }
        }
    }

    private func load() async {
        do {
            switch try await context.client.api.listGroceryCategories(.init()) {
            case .ok(let ok): categories = .loaded(try ok.body.json.categories)
            case .unauthorized: appState.handleUnauthorized()
            default: if case .loading = categories { categories = .failed("Couldn\u{2019}t reach your home server.") }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            if case .loading = categories { categories = .failed("Couldn\u{2019}t reach your home server.") }
        }
    }
}

/// Create or edit a category: name + a swatch. Delete (custom only) confirms
/// and names the consequence — everything filed here becomes Other.
private struct CategoryFormSheet: View {
    let context: SignedInContext
    /// nil = creating.
    let category: Components.Schemas.GroceryCategory?
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var color = ListsLogic.swatches[0]
    @State private var confirmingDelete = false
    @State private var busy = false

    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 8)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                Section {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(ListsLogic.swatches, id: \.self) { swatch in
                            Button {
                                color = swatch
                            } label: {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(hex: swatch))
                                    .frame(height: 38)
                                    .overlay {
                                        if swatch == color {
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Color \(swatch)")
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                if let category, ListsLogic.canDelete(category) {
                    Section {
                        Button("Delete category", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                }
            }
            .navigationTitle(category?.name ?? "New category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(category == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            .alert("Delete \(category?.name ?? "")?", isPresented: $confirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: {
                Text("Its items and library entries move to Other.")
            }
            .onAppear {
                if let category {
                    name = category.name
                    color = category.color
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let category {
            let body = Components.Schemas.GroceryCategoryUpdate(name: trimmed, color: color)
            if case .ok? = try? await context.client.api.updateGroceryCategory(
                .init(path: .init(id: category.id), body: .json(body))
            ) {
                onChanged()
                dismiss()
            }
        } else {
            let body = Components.Schemas.GroceryCategoryCreate(name: trimmed, color: color)
            if case .created? = try? await context.client.api.createGroceryCategory(
                .init(body: .json(body))
            ) {
                onChanged()
                dismiss()
            }
        }
    }

    private func delete() async {
        guard let category else { return }
        if case .noContent? = try? await context.client.api.deleteGroceryCategory(
            .init(path: .init(id: category.id))
        ) {
            onChanged()
            dismiss()
        }
    }
}
