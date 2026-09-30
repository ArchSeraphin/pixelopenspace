import Foundation

/// Gathers the file URLs of one drop: `NSItemProvider` delivers each on a background queue. Once every provider has
/// answered, the URLs go to the main actor in drop order of arrival.
final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var urls: [URL] = []
    private let completion: @MainActor @Sendable ([URL]) -> Void

    init(expected: Int, completion: @escaping @MainActor @Sendable ([URL]) -> Void) {
        remaining = expected
        self.completion = completion
    }

    /// Called once per provider, with its URL or `nil` when it could not be read.
    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let finished = remaining == 0
        let collected = urls
        lock.unlock()
        guard finished else { return }
        let completion = self.completion
        Task { @MainActor in
            completion(collected)
        }
    }
}
