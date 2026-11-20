import Foundation

/// Decides whether a failure is worth another attempt.
///
/// The distinction that matters is transient versus permanent. A dropped Wi-Fi
/// packet deserves a retry; a wrong token does not, and retrying it would only
/// delay the message the person needs to read.
enum RetryPolicy {
    /// Attempts allowed for one logical request, including the first.
    static let maxAttempts = 4

    /// Whether `error` may succeed if the same request is sent again.
    /// @param error - the failure to classify.
    /// @returns true for transport failures and transient HTTP statuses.
    static func isTransient(_ error: Error) -> Bool {
        // Cancellation is never transient: the caller withdrew the request, so
        // repeating it would work against them. `.refreshable` cancels a pull
        // when the person pulls again, which arrives here as URLError.cancelled.
        if isCancellation(error) { return false }
        guard let bridge = error as? BridgeError else {
            // URLSession surfaces connectivity loss as its own error type.
            return isTransientURLSessionError(error)
        }
        switch bridge {
        case .http(let status, _):
            // 408 request timeout, 425 too early, 429 throttled, 5xx server side.
            // 401 is permanent: the token is wrong until the person fixes it.
            return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
        case .transport:
            return true
        case .decoding:
            // A malformed body is not going to parse on the next attempt.
            return false
        case .missingEndpoint, .invalidURL:
            return false
        }
    }

    /// Whether a failure means the caller stopped waiting.
    ///
    /// Both the Swift concurrency cancellation and the URL loading system's own
    /// `cancelled` code mean the same thing here, and neither deserves a retry
    /// or a message on screen.
    /// @param error - the failure to classify.
    /// @returns true when the request was withdrawn.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let bridge = error as? BridgeError {
            if case .transport(let message) = bridge {
                return message.contains("cancelled") || message.contains("canceled")
            }
            return false
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        return false
    }

    /// Whether a raw `URLSession` error is a connectivity failure.
    /// @param error - the error to classify.
    /// @returns true for the URLError families that recover on their own.
    static func isTransientURLSessionError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable,
             .cannotLoadFromNetwork,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Delay before attempt `attempt + 1`.
    ///
    /// Exponential with jitter: a phone that lost its network should not hammer
    /// the bridge in lockstep with another one that did the same.
    /// @param attempt - zero-based index of the attempt that just failed.
    /// @returns the seconds to wait.
    static func delay(afterAttempt attempt: Int) -> Double {
        let base = 0.4 * pow(2.0, Double(attempt))
        let capped = min(base, 4.0)
        return capped + Double.random(in: 0...0.25)
    }
}

/// Runs an async operation with bounded retries for transient failures.
///
/// `shouldRetry` lets a caller veto a retry for a request that must not be
/// repeated, which is why the retry count is a parameter rather than a constant.
enum Retry {
    /// Execute `operation`, retrying transient failures.
    ///
    /// Cancellation is never retried: the caller asked to stop.
    /// @param maxAttempts - total attempts including the first.
    /// @param onRetry - called before each wait, for status reporting.
    /// @param shouldRetry - additional veto consulted after `isTransient`.
    /// @param operation - the work to perform.
    /// @returns the operation's value from the first successful attempt.
    /// @throws the last error when every attempt fails.
    static func run<T>(
        maxAttempts: Int = RetryPolicy.maxAttempts,
        onRetry: (@Sendable (Int, Error, Double) -> Void)? = nil,
        shouldRetry: (@Sendable (Error) -> Bool)? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                if Task.isCancelled { throw error }
                let retryable = RetryPolicy.isTransient(error) && (shouldRetry?(error) ?? true)
                let exhausted = attempt + 1 >= maxAttempts
                if !retryable || exhausted { throw error }
                let wait = RetryPolicy.delay(afterAttempt: attempt)
                onRetry?(attempt + 1, error, wait)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                attempt += 1
            }
        }
    }
}