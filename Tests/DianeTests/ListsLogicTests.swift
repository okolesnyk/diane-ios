import DianeKit
import Foundation
import Testing

@testable import Diane

@Suite struct ListsLogicTests {
    // MARK: Fixtures

    private func item(
        _ name: String,
        id: String = UUID().uuidString,
        checked: Bool = false,
        categoryId: String? = nil,
        sortOrder: Int = 0
    ) -> Components.Schemas.ListItem {
        .init(
            id: id, listId: "l1", name: name, amount: "", categoryId: categoryId,
            checked: checked, sortOrder: sortOrder, createdAt: "2026-08-12T00:00:00Z"
        )
    }

    private func category(
        _ key: String?,
        id: String,
        name: String,
        sortOrder: Int
    ) -> Components.Schemas.GroceryCategory {
        .init(id: id, key: key, name: name, color: "#58a94c", sortOrder: sortOrder)
    }

    private func entry(
        _ name: String,
        ua: String = "",
        id: String = UUID().uuidString,
        categoryId: String? = "c-dairy"
    ) -> Components.Schemas.GroceryLibraryItem {
        .init(id: id, name: name, altName: ua, categoryId: categoryId, lastAmount: "")
    }

    private var cats: [Components.Schemas.GroceryCategory] {
        [
            category("produce", id: "c-produce", name: "Produce", sortOrder: 0),
            category("dairy", id: "c-dairy", name: "Dairy & Eggs", sortOrder: 2),
            category(nil, id: "c-custom", name: "TJ", sortOrder: 10),
            category("other", id: "c-other", name: "Other", sortOrder: 100),
        ]
    }

    // MARK: Badges

    @Test func groceryBadgeCountsToBuyOnly() {
        // History is quiet — crossed rows never show in the badge.
        #expect(ListsLogic.badge(type: .grocery, itemCount: 16, checkedCount: 2) == "14 to buy")
        #expect(ListsLogic.badge(type: .grocery, itemCount: 4, checkedCount: 0) == "4 to buy")
        #expect(ListsLogic.badge(type: .grocery, itemCount: 3, checkedCount: 3) == "All bought")
    }

    @Test func checklistBadgeReadsDone() {
        #expect(ListsLogic.badge(type: .checklist, itemCount: 18, checkedCount: 11) == "11 of 18 done")
    }

    @Test func plainBadgeCountsItemsAndEmptyReadsEmpty() {
        #expect(ListsLogic.badge(type: .plain, itemCount: 1, checkedCount: 0) == "1 item")
        #expect(ListsLogic.badge(type: .plain, itemCount: 6, checkedCount: 2) == "6 items")
        #expect(ListsLogic.badge(type: .grocery, itemCount: 0, checkedCount: 0) == "Empty")
    }

    // MARK: To-dos — done sinks, drag maps back

    @Test func todoOrderSinksDoneKeepingRelativeOrder() {
        let rows = [
            item("A", id: "a", checked: true),
            item("B", id: "b"),
            item("C", id: "c", checked: true),
            item("D", id: "d"),
        ]
        #expect(ListsLogic.todoOrder(rows).map(\.id) == ["b", "d", "a", "c"])
    }

    @Test func movedMapsDisplayedDragToFullIdOrder() {
        let displayed = [item("B", id: "b"), item("D", id: "d"), item("A", id: "a", checked: true)]
        // Drag the last displayed row to the front.
        #expect(ListsLogic.movedIds(displayed, from: IndexSet(integer: 2), to: 0) == ["a", "b", "d"])
    }

    @Test func movedIdsWorksForListsToo() {
        let lists: [Components.Schemas.List] = [
            .init(id: "a", _type: .grocery, name: "Costco", sortOrder: 0, itemCount: 0, checkedCount: 0, createdAt: "2026-08-12T00:00:00Z"),
            .init(id: "b", _type: .checklist, name: "Packing", sortOrder: 1, itemCount: 0, checkedCount: 0, createdAt: "2026-08-12T00:00:00Z"),
            .init(id: "c", _type: .plain, name: "Projects", sortOrder: 2, itemCount: 0, checkedCount: 0, createdAt: "2026-08-12T00:00:00Z"),
        ]
        // Drag Projects to the top.
        #expect(ListsLogic.movedIds(lists, from: IndexSet(integer: 2), to: 0) == ["c", "a", "b"])
    }

    // MARK: Grocery grouping

    @Test func groupsFollowCategoryOrderAndNilReadsAsOther() {
        let rows = [
            item("Milk", categoryId: "c-dairy"),
            item("Mystery", categoryId: nil),
            item("Ghost", categoryId: "c-deleted"),  // stale id → Other too
            item("Bananas", categoryId: "c-produce"),
            item("In cart", checked: true, categoryId: "c-produce"),
        ]
        let groups = ListsLogic.grouped(items: rows, categories: cats)
        #expect(groups.map(\.category.id) == ["c-produce", "c-dairy", "c-other"])
        #expect(groups[0].items.map(\.name) == ["Bananas"])  // the cart row stays out
        #expect(groups[2].items.map(\.name) == ["Mystery", "Ghost"])
    }

    // MARK: Hints

    @Test func hintsMatchEitherLanguageAndFlagOnList() {
        let library = [entry("Milk", ua: "Молоко"), entry("Whipping cream", ua: "Вершки")]
        let hints = ListsLogic.hints(query: "mil", library: library, listNames: ["Milk"])
        #expect(hints.count == 1)
        #expect(hints[0].label == "Milk")
        #expect(hints[0].onList)
    }

    @Test func cyrillicQueryShowsAndAddsTheUkrainianSide() {
        let library = [entry("Whipping cream", ua: "Вершки")]
        let hints = ListsLogic.hints(query: "верш", library: library, listNames: [])
        #expect(hints.count == 1)
        #expect(hints[0].label == "Вершки")
        #expect(ListsLogic.addName(query: "верш", entry: library[0]) == "Вершки")
        #expect(ListsLogic.addName(query: "whip", entry: library[0]) == "Whipping cream")
    }

    @Test func onListMatchesTheOtherLanguageToo() {
        // The list row holds the UA name; the hint for the same entry must
        // still read as already-on-list.
        let library = [entry("Whipping cream", ua: "Вершки")]
        let hints = ListsLogic.hints(query: "wh", library: library, listNames: ["Вершки"])
        #expect(hints[0].onList)
    }

    @Test func exactMatchGatesTheAddChip() {
        let library = [entry("Milk", ua: "Молоко")]
        #expect(ListsLogic.exactMatch(query: "milk", library: library) != nil)
        #expect(ListsLogic.exactMatch(query: "молоко", library: library) != nil)
        #expect(ListsLogic.exactMatch(query: "mil", library: library) == nil)
    }

    // MARK: Library groups + category rules

    @Test func libraryGroupsFilterAcrossBothLanguages() {
        let entries = [
            entry("Milk", ua: "Молоко", categoryId: "c-dairy"),
            entry("Bananas", ua: "Банани", categoryId: "c-produce"),
        ]
        let hit = ListsLogic.libraryGroups(entries: entries, categories: cats, query: "банан")
        #expect(hit.count == 1)
        #expect(hit[0].entries.map(\.name) == ["Bananas"])
    }

    @Test func onlyCustomCategoriesDelete() {
        #expect(!ListsLogic.canDelete(cats[0]))
        #expect(ListsLogic.canDelete(cats[2]))
        #expect(!ListsLogic.canDelete(cats[3]))
    }

    // MARK: Home tile line

    @Test func homeLinePicksTheBusiestGroceryList() {
        let lists: [Components.Schemas.List] = [
            .init(id: "a", _type: .grocery, name: "Costco", sortOrder: 0, itemCount: 16, checkedCount: 2, createdAt: "2026-08-12T00:00:00Z"),
            .init(id: "b", _type: .grocery, name: "TJ", sortOrder: 1, itemCount: 4, checkedCount: 0, createdAt: "2026-08-12T00:00:00Z"),
            .init(id: "c", _type: .checklist, name: "Packing", sortOrder: 2, itemCount: 18, checkedCount: 0, createdAt: "2026-08-12T00:00:00Z"),
        ]
        #expect(HomeLogic.listsLine(lists: lists) == HomeLogic.Line(count: "Costco · 14 to buy"))
    }

    @Test func homeLineGoesQuietWhenNothingToBuy() {
        let lists: [Components.Schemas.List] = [
            .init(id: "a", _type: .grocery, name: "Costco", sortOrder: 0, itemCount: 2, checkedCount: 2, createdAt: "2026-08-12T00:00:00Z"),
        ]
        #expect(HomeLogic.listsLine(lists: lists) == nil)
    }
}
