import Foundation
import Observation

/// A subscription's result for SwiftUI: `data` follows the database after every commit that changes it.
/// It starts when created and stops when released.
@MainActor @Observable
public final class LiveQuery<S: NorvoSubscription> {
    public private(set) var data: S.Data?
    public private(set) var errors: [GraphQLError] = []
    /// Set when the live query ends, for instance after a migration that made it invalid.
    public private(set) var ended: NorvoError?

    @ObservationIgnored private let worker = Worker()

    public init(_ subscription: S, in db: Database) {
        let updates = db.liveUpdates(subscription)
        worker.task = Task { [weak self] in
            do {
                for try await u in updates {
                    guard let self else { return }
                    self.errors = u.errors
                    if case .null = u.data {
                        self.data = nil
                    } else if let d = try? CBORDecoder().decode(S.Data.self, from: u.data) {
                        self.data = d
                    }
                }
            } catch let e as NorvoError {
                self?.ended = e
            } catch {
                self?.ended = NorvoError(code: .internal, message: "\(error)")
            }
        }
    }

    deinit { worker.task?.cancel() }

    /// Holds the consuming task, so a nonisolated deinit can cancel it.
    final class Worker: @unchecked Sendable {
        var task: Task<Void, Never>?
    }
}
