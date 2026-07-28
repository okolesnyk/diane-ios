import Foundation

/// SwiftUI cancels `.task(id:)` bodies whenever the id changes or the view
/// disappears; the in-flight URLSession call then throws. That is routine
/// lifecycle, not a failure — screens must never render it as "can't reach
/// the server" (review M9 HIGH).
func isTaskCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}
