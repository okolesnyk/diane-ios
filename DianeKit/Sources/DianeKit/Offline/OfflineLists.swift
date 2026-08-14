import Foundation

/// Pure offline-apply for the Lists module: each queued mutation is applied
/// to the cached wire payloads so views (which reload from cache while
/// offline) immediately show the optimistic result. The rules deliberately
/// mirror the server's (dedupe by name, revive from history, explicit
/// category beats library match beats Other) so the post-replay refetch
/// changes nothing visible.
public enum OfflineLists {
    static let tempIdPrefix = "local-"

    public static func isTempId(_ id: String) -> Bool { id.hasPrefix(tempIdPrefix) }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // Payload wrappers built from the full generated schemas, so re-encoding
    // a patched cache never drops fields.
    struct IndexPayload: Codable {
        var lists: [Components.Schemas.List]
    }
    struct LibraryPayload: Codable {
        var items: [Components.Schemas.GroceryLibraryItem]
    }
    struct CategoriesPayload: Codable {
        var categories: [Components.Schemas.GroceryCategory]
    }
    struct ItemPatch: Codable {
        var checked: Bool?
        var amount: String?
        var categoryId: String?
    }
    struct AddBody: Codable {
        var name: String
        var categoryId: String?
        var amount: String?
    }
    struct OrderBody: Codable {
        var itemIds: [String]
    }

    /// The category the SERVER would file this name under: explicit wins,
    /// then a library match in either language, then Other.
    static func resolveCategory(
        name: String,
        explicit: String?,
        library: Data?,
        categories: Data?
    ) -> String? {
        if let explicit { return explicit }
        let norm = normalized(name)
        if let library,
           let payload = try? JSONDecoder().decode(LibraryPayload.self, from: library),
           let hit = payload.items.first(where: {
               normalized($0.name) == norm || normalized($0.altName) == norm
           }),
           let categoryId = hit.categoryId {
            return categoryId
        }
        if let categories,
           let payload = try? JSONDecoder().decode(CategoriesPayload.self, from: categories) {
            return payload.categories.first { $0.key == "other" }?.id
        }
        return nil
    }

    /// Result of applying one op: the patched detail payload, the count
    /// deltas the lists-index badges need, and the temp id when the op
    /// created a fresh item (replay swaps it for the server's id).
    public struct Applied {
        public var detail: Data
        public var itemDelta: Int
        public var checkedDelta: Int
        public var createdItemId: String?
    }

    public static func applyAdd(
        detail: Data,
        body: Data,
        library: Data?,
        categories: Data?,
        now: Date = Date()
    ) -> Applied? {
        guard var payload = try? JSONDecoder().decode(Components.Schemas.ListDetail.self, from: detail),
              let add = try? JSONDecoder().decode(AddBody.self, from: body)
        else { return nil }
        let norm = normalized(add.name)
        if let index = payload.items.firstIndex(where: { normalized($0.name) == norm }) {
            // The server's dedupe: an active twin is a no-op, a crossed twin
            // is resurrected with the new amount/category.
            guard payload.items[index].checked else { return encode(payload, item: 0, checked: 0) }
            payload.items[index].checked = false
            if let amount = add.amount, !amount.isEmpty { payload.items[index].amount = amount }
            if let categoryId = add.categoryId { payload.items[index].categoryId = categoryId }
            payload.list.checkedCount -= 1
            return encode(payload, item: 0, checked: -1)
        }
        let item = Components.Schemas.ListItem(
            id: tempIdPrefix + UUID().uuidString.lowercased(),
            listId: payload.list.id,
            name: add.name.trimmingCharacters(in: .whitespaces),
            amount: add.amount ?? "",
            categoryId: resolveCategory(
                name: add.name, explicit: add.categoryId,
                library: library, categories: categories
            ),
            checked: false,
            sortOrder: (payload.items.map(\.sortOrder).max() ?? 0) + 1,
            createdAt: ISO8601DateFormatter().string(from: now)
        )
        payload.items.append(item)
        payload.list.itemCount += 1
        var applied = encode(payload, item: 1, checked: 0)
        applied?.createdItemId = item.id
        return applied
    }

    public static func applyUpdate(detail: Data, itemId: String, body: Data) -> Applied? {
        guard var payload = try? JSONDecoder().decode(Components.Schemas.ListDetail.self, from: detail),
              let patch = try? JSONDecoder().decode(ItemPatch.self, from: body),
              let index = payload.items.firstIndex(where: { $0.id == itemId })
        else { return nil }
        var checkedDelta = 0
        if let checked = patch.checked, checked != payload.items[index].checked {
            payload.items[index].checked = checked
            checkedDelta = checked ? 1 : -1
            payload.list.checkedCount += checkedDelta
        }
        if let amount = patch.amount { payload.items[index].amount = amount }
        if let categoryId = patch.categoryId { payload.items[index].categoryId = categoryId }
        return encode(payload, item: 0, checked: checkedDelta)
    }

    public static func applyDelete(detail: Data, itemId: String) -> Applied? {
        guard var payload = try? JSONDecoder().decode(Components.Schemas.ListDetail.self, from: detail),
              let index = payload.items.firstIndex(where: { $0.id == itemId })
        else { return nil }
        let wasChecked = payload.items[index].checked
        payload.items.remove(at: index)
        payload.list.itemCount -= 1
        if wasChecked { payload.list.checkedCount -= 1 }
        return encode(payload, item: -1, checked: wasChecked ? -1 : 0)
    }

    public static func applyOrder(detail: Data, body: Data) -> Applied? {
        guard var payload = try? JSONDecoder().decode(Components.Schemas.ListDetail.self, from: detail),
              let order = try? JSONDecoder().decode(OrderBody.self, from: body)
        else { return nil }
        // Subset semantics like the server: listed ids first in given order.
        var rank: [String: Int] = [:]
        for (offset, id) in order.itemIds.enumerated() { rank[id] = offset }
        payload.items.sort {
            (rank[$0.id] ?? Int.max, $0.sortOrder) < (rank[$1.id] ?? Int.max, $1.sortOrder)
        }
        for index in payload.items.indices { payload.items[index].sortOrder = index }
        return encode(payload, item: 0, checked: 0)
    }

    /// Keep the Lists index badges honest while offline.
    public static func patchIndexCounts(index: Data, listId: String, itemDelta: Int, checkedDelta: Int) -> Data? {
        guard var payload = try? JSONDecoder().decode(IndexPayload.self, from: index),
              let at = payload.lists.firstIndex(where: { $0.id == listId })
        else { return nil }
        payload.lists[at].itemCount += itemDelta
        payload.lists[at].checkedCount += checkedDelta
        return try? JSONEncoder().encode(payload)
    }

    /// After a queued create replays, the server id replaces the temp id in
    /// every later op — paths (PATCH/DELETE) and bodies (reorder) alike.
    public static func rewriteTempId(_ ops: [QueuedOp], temp: String, real: String) -> [QueuedOp] {
        ops.map { op in
            var op = op
            op.path = op.path.replacingOccurrences(of: temp, with: real)
            if let body = op.body, let text = String(data: body, encoding: .utf8), text.contains(temp) {
                op.body = Data(text.replacingOccurrences(of: temp, with: real).utf8)
            }
            return op
        }
    }

    private static func encode(_ payload: Components.Schemas.ListDetail, item: Int, checked: Int) -> Applied? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return Applied(detail: data, itemDelta: item, checkedDelta: checked)
    }
}
