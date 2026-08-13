import DianeKit
import Foundation

// sheet(item:)/ForEach need these; the generated types already carry an `id`.
extension Components.Schemas.List: @retroactive Identifiable {}
extension Components.Schemas.ListItem: @retroactive Identifiable {}
extension Components.Schemas.GroceryLibraryItem: @retroactive Identifiable {}
extension Components.Schemas.GroceryCategory: @retroactive Identifiable {}

/// Data-shaping rules for the Lists module (design pass rev 3, all decisions
/// owner-settled 2026-08-12). Nonisolated on purpose — tested without UI.
enum ListsLogic {
    // MARK: - Badges

    /// The root rows' status line, straight from the mock:
    /// grocery "14 to buy · 2 in cart", checklist "11 of 18 done",
    /// plain "6 items"; anything empty reads "Empty".
    static func badge(type: Components.Schemas.ListType, itemCount: Int, checkedCount: Int) -> String {
        guard itemCount > 0 else { return "Empty" }
        switch type {
        case .grocery:
            let toBuy = itemCount - checkedCount
            let cart = checkedCount > 0 ? " · \(checkedCount) in cart" : ""
            return "\(toBuy) to buy\(cart)"
        case .checklist:
            return "\(checkedCount) of \(itemCount) done"
        case .plain:
            return "\(itemCount) item\(itemCount == 1 ? "" : "s")"
        }
    }

    // MARK: - To-dos (checklist + plain)

    /// Owner rule: done sinks to the bottom — a stable partition, unchecked
    /// first, each side in stored (manual) order.
    static func todoOrder(_ items: [Components.Schemas.ListItem]) -> [Components.Schemas.ListItem] {
        items.filter { !$0.checked } + items.filter(\.checked)
    }

    /// A drag within the DISPLAYED order, mapped back to the full id list the
    /// server's *-order endpoints expect (items and the lists themselves).
    static func movedIds<Row: Identifiable>(
        _ displayed: [Row],
        from source: IndexSet,
        to destination: Int
    ) -> [Row.ID] {
        var rows = displayed
        rows.move(fromOffsets: source, toOffset: destination)
        return rows.map(\.id)
    }

    // MARK: - Grocery grouping

    struct CategoryGroup: Identifiable {
        var category: Components.Schemas.GroceryCategory
        var items: [Components.Schemas.ListItem]
        var id: String { category.id }
    }

    /// Active (uncarted) rows grouped in category display order; NULL or
    /// unknown categories read as Other. The cart is simply `checked`.
    static func grouped(
        items: [Components.Schemas.ListItem],
        categories: [Components.Schemas.GroceryCategory]
    ) -> [CategoryGroup] {
        let other = categories.first { $0.key == "other" }
        var buckets: [String: [Components.Schemas.ListItem]] = [:]
        for item in items where !item.checked {
            let key = item.categoryId ?? other?.id ?? ""
            buckets[categories.contains { $0.id == key } ? key : (other?.id ?? ""), default: []]
                .append(item)
        }
        return categories.compactMap { category in
            guard let rows = buckets[category.id], !rows.isEmpty else { return nil }
            return CategoryGroup(category: category, items: rows)
        }
    }

    // MARK: - Hints (the inline add)

    struct Hint: Identifiable, Equatable {
        var entry: Components.Schemas.GroceryLibraryItem
        /// Cyrillic query shows the Ukrainian side when there is one.
        var label: String
        var onList: Bool
        var id: String { entry.id }
    }

    static func hasCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// Library chips for the typed query: both languages match, at most
    /// `limit`, rows already on the list wear a checkmark and do nothing.
    static func hints(
        query: String,
        library: [Components.Schemas.GroceryLibraryItem],
        listNames: [String],
        limit: Int = 12
    ) -> [Hint] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let cyrillic = hasCyrillic(needle)
        let onList = Set(listNames.map { $0.lowercased() })
        return library
            .filter {
                $0.name.lowercased().contains(needle)
                    || (!$0.altName.isEmpty && $0.altName.lowercased().contains(needle))
            }
            .prefix(limit)
            .map { entry in
                Hint(
                    entry: entry,
                    label: cyrillic && !entry.altName.isEmpty ? entry.altName : entry.name,
                    onList: onList.contains(entry.name.lowercased())
                        || (!entry.altName.isEmpty && onList.contains(entry.altName.lowercased()))
                )
            }
    }

    /// The "+ Add" chip shows only while no library entry matches exactly.
    static func exactMatch(
        query: String,
        library: [Components.Schemas.GroceryLibraryItem]
    ) -> Components.Schemas.GroceryLibraryItem? {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nil }
        return library.first {
            $0.name.lowercased() == needle
                || (!$0.altName.isEmpty && $0.altName.lowercased() == needle)
        }
    }

    /// What lands on the list when a hint is tapped: the language you typed.
    static func addName(query: String, entry: Components.Schemas.GroceryLibraryItem) -> String {
        hasCyrillic(query) && !entry.altName.isEmpty ? entry.altName : entry.name
    }

    // MARK: - Library screen

    struct LibraryGroup: Identifiable {
        var category: Components.Schemas.GroceryCategory
        var entries: [Components.Schemas.GroceryLibraryItem]
        var id: String { category.id }
    }

    static func libraryGroups(
        entries: [Components.Schemas.GroceryLibraryItem],
        categories: [Components.Schemas.GroceryCategory],
        query: String
    ) -> [LibraryGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let other = categories.first { $0.key == "other" }
        let hits = needle.isEmpty
            ? entries
            : entries.filter {
                $0.name.lowercased().contains(needle)
                    || (!$0.altName.isEmpty && $0.altName.lowercased().contains(needle))
            }
        var buckets: [String: [Components.Schemas.GroceryLibraryItem]] = [:]
        for entry in hits {
            let key = entry.categoryId ?? other?.id ?? ""
            buckets[categories.contains { $0.id == key } ? key : (other?.id ?? ""), default: []]
                .append(entry)
        }
        return categories.compactMap { category in
            guard let rows = buckets[category.id], !rows.isEmpty else { return nil }
            return LibraryGroup(category: category, entries: rows)
        }
    }

    /// Swatches offered when creating/recoloring a category (mock rev 3).
    static let swatches: [String] = [
        "#58a94c", "#2da44e", "#bf2f3f", "#e0442e", "#14a3b8", "#4d9fe8",
        "#a9743a", "#e07b39", "#e08a00", "#8748ad", "#7c3aed", "#c19b1f",
        "#b5b820", "#ea4c89", "#5352d1", "#9a9fa8",
    ]

    /// Seeded rows (and Other in particular) never offer Delete.
    static func canDelete(_ category: Components.Schemas.GroceryCategory) -> Bool {
        category.key == nil
    }
}
