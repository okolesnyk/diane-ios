import Foundation

/// Screen data-loading state. No `idle`: screens load in `.task` on
/// appearance, so the initial state is already `.loading`.
enum Loadable<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}
