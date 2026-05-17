import Foundation

/// Token-bucket rate limiter for upload/download bandwidth control.
/// A class (not struct) because DownloadCoordinator is an actor and
/// actor-isolated properties cannot be mutated in-place.
public final class RateLimiter {
    /// Maximum bytes per second. 0 = unlimited (consume() is a no-op).
    public let maxBytesPerSecond: Int64
    private var byteBalance: Double = 0
    private var lastRefillTime: Date = Date()

    public init(maxKiBPerSecond: Int) {
        self.maxBytesPerSecond = Int64(maxKiBPerSecond) * 1024
    }

    /// Wait until the rate limit permits `bytes`, then deduct from the balance.
    /// Returns immediately when maxBytesPerSecond is 0 (unlimited).
    public func consume(_ bytes: Int64) async {
        guard maxBytesPerSecond > 0, bytes > 0 else { return }
        let now = Date()
        // Refill tokens since last consume
        let elapsed = now.timeIntervalSince(lastRefillTime)
        byteBalance += elapsed * Double(maxBytesPerSecond)
        byteBalance = min(byteBalance, Double(maxBytesPerSecond)) // cap to 1s burst
        lastRefillTime = now

        byteBalance -= Double(bytes)

        if byteBalance < 0 {
            // Sleep until balance returns to zero
            let waitSeconds = -byteBalance / Double(maxBytesPerSecond)
            try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            lastRefillTime = Date()
            byteBalance = 0
        }
    }
}
