import Foundation

/// Stub engine — builds cleanly, does nothing.
/// Will conform to TorrentEngineProtocol once wired into the app (Phase 4+).
@MainActor
public final class CanopyEngine: ObservableObject {
    @Published public var torrents: [String] = []
    @Published public var sessionError: String?

    public init() {}
    public func shutdown() {}
}
