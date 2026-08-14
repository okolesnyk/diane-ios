import Foundation
import Testing
@testable import DianeKit

/// The offline-apply rules mirror the SERVER's lists semantics (dedupe by
/// name, revive from history, explicit > library > Other) so that the
/// post-replay refetch changes nothing the user can see.
struct OfflineListsTests {
    // MARK: - Fixtures

    private func item(
        id: String = "i1",
        name: String,
        amount: String = "",
        categoryId: String? = nil,
        checked: Bool = false,
        sortOrder: Int = 0
    ) -> Components.Schemas.ListItem {
        .init(
            id: id, listId: "L1", name: name, amount: amount,
            categoryId: categoryId, checked: checked, sortOrder: sortOrder,
            createdAt: "2026-08-13T00:00:00Z"
        )
    }

    private func detail(_ items: [Components.Schemas.ListItem]) -> Data {
        let checked = items.count(where: \.checked)
        let payload = Components.Schemas.ListDetail(
            list: .init(
                id: "L1", _type: .grocery, name: "Costco", sortOrder: 0,
                itemCount: items.count, checkedCount: checked,
                createdAt: "2026-08-13T00:00:00Z"
            ),
            items: items
        )
        return try! JSONEncoder().encode(payload)
    }

    private func decode(_ data: Data) -> Components.Schemas.ListDetail {
        try! JSONDecoder().decode(Components.Schemas.ListDetail.self, from: data)
    }

    private var library: Data {
        let payload = OfflineLists.LibraryPayload(items: [
            .init(id: "g1", name: "Milk", altName: "Молоко", categoryId: "c-dairy", lastAmount: ""),
            .init(id: "g2", name: "Bananas", altName: "", categoryId: "c-produce", lastAmount: ""),
        ])
        return try! JSONEncoder().encode(payload)
    }

    private var categories: Data {
        let payload = OfflineLists.CategoriesPayload(categories: [
            .init(id: "c-dairy", key: "dairy", name: "Dairy & Eggs", color: "#1798a4", sortOrder: 2),
            .init(id: "c-other", key: "other", name: "Other", color: "#9a9fa8", sortOrder: 100),
        ])
        return try! JSONEncoder().encode(payload)
    }

    private func body(_ json: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - Add

    @Test func addInsertsWithLibraryCategoryAndTempId() {
        let applied = OfflineLists.applyAdd(
            detail: detail([]), body: body(["name": "молоко"]),
            library: library, categories: categories
        )!
        let result = decode(applied.detail)
        #expect(result.items.count == 1)
        #expect(result.items[0].categoryId == "c-dairy")
        #expect(OfflineLists.isTempId(result.items[0].id))
        #expect(applied.createdItemId == result.items[0].id)
        #expect(result.list.itemCount == 1)
        #expect(applied.itemDelta == 1)
    }

    @Test func addUnknownNameFilesUnderOther() {
        let applied = OfflineLists.applyAdd(
            detail: detail([]), body: body(["name": "Омивайка"]),
            library: library, categories: categories
        )!
        #expect(decode(applied.detail).items[0].categoryId == "c-other")
    }

    @Test func addActiveTwinIsANoOp() {
        let applied = OfflineLists.applyAdd(
            detail: detail([item(name: "Milk")]), body: body(["name": " milk "]),
            library: library, categories: categories
        )!
        let result = decode(applied.detail)
        #expect(result.items.count == 1)
        #expect(applied.createdItemId == nil)
        #expect(applied.itemDelta == 0)
    }

    @Test func addRevivesACrossedTwin() {
        let applied = OfflineLists.applyAdd(
            detail: detail([item(name: "Milk", checked: true)]),
            body: body(["name": "Milk", "amount": "2"]),
            library: library, categories: categories
        )!
        let result = decode(applied.detail)
        #expect(result.items.count == 1)
        #expect(!result.items[0].checked)
        #expect(result.items[0].amount == "2")
        #expect(result.list.checkedCount == 0)
        #expect(applied.checkedDelta == -1)
    }

    // MARK: - Update / delete / order

    @Test func checkAndUncheckMoveTheCounts() {
        let checked = OfflineLists.applyUpdate(
            detail: detail([item(name: "Milk")]), itemId: "i1",
            body: body(["checked": true])
        )!
        #expect(decode(checked.detail).list.checkedCount == 1)
        #expect(checked.checkedDelta == 1)
        let unchecked = OfflineLists.applyUpdate(
            detail: checked.detail, itemId: "i1", body: body(["checked": false])
        )!
        #expect(decode(unchecked.detail).list.checkedCount == 0)
    }

    @Test func deleteRemovesAndCounts() {
        let applied = OfflineLists.applyDelete(
            detail: detail([item(name: "Milk", checked: true)]), itemId: "i1"
        )!
        let result = decode(applied.detail)
        #expect(result.items.isEmpty)
        #expect(result.list.itemCount == 0)
        #expect(applied.itemDelta == -1 && applied.checkedDelta == -1)
    }

    @Test func deleteMissingItemFails() {
        #expect(OfflineLists.applyDelete(detail: detail([]), itemId: "ghost") == nil)
    }

    @Test func orderPutsListedIdsFirstInGivenOrder() {
        let items = [
            item(id: "a", name: "A", sortOrder: 0),
            item(id: "b", name: "B", sortOrder: 1),
            item(id: "c", name: "C", sortOrder: 2),
        ]
        let applied = OfflineLists.applyOrder(
            detail: detail(items), body: body(["itemIds": ["c", "a"]])
        )!
        #expect(decode(applied.detail).items.map(\.id) == ["c", "a", "b"])
    }

    // MARK: - Index counts + temp ids

    @Test func indexCountsFollowTheDeltas() {
        let index = try! JSONEncoder().encode(OfflineLists.IndexPayload(lists: [
            .init(id: "L1", _type: .grocery, name: "Costco", sortOrder: 0,
                  itemCount: 3, checkedCount: 1, createdAt: "2026-08-13T00:00:00Z"),
        ]))
        let patched = OfflineLists.patchIndexCounts(index: index, listId: "L1", itemDelta: 1, checkedDelta: -1)!
        let payload = try! JSONDecoder().decode(OfflineLists.IndexPayload.self, from: patched)
        #expect(payload.lists[0].itemCount == 4)
        #expect(payload.lists[0].checkedCount == 0)
    }

    @Test func tempIdRewriteHitsPathsAndBodies() {
        let temp = "local-abc"
        let ops = [
            QueuedOp(method: "PATCH", path: "/api/v1/lists/L1/items/\(temp)", body: nil, summary: ""),
            QueuedOp(method: "PUT", path: "/api/v1/lists/L1/items-order",
                     body: body(["itemIds": [temp, "real2"]]), summary: ""),
        ]
        let rewritten = OfflineLists.rewriteTempId(ops, temp: temp, real: "srv9")
        #expect(rewritten[0].path == "/api/v1/lists/L1/items/srv9")
        let text = String(data: rewritten[1].body!, encoding: .utf8)!
        #expect(text.contains("srv9") && !text.contains(temp))
    }

    @Test func explicitCategoryBeatsTheLibrary() {
        let id = OfflineLists.resolveCategory(
            name: "Milk", explicit: "c-x", library: library, categories: categories
        )
        #expect(id == "c-x")
    }
}
