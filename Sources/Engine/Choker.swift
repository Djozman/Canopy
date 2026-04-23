import Foundation

/// BEP 3 tit-for-tat choking: unchoke the top 4 fastest uploaders + 1 optimistic peer.
actor Choker {
    private var optimisticUnchoke: PeerConnection?
    private var lastRotation: Date = .now

    init() {}

    func update(peers: [PeerConnection]) async {
        let now = Date.now

        struct S { let peer: PeerConnection; let interested: Bool; let speed: Int64; let choked: Bool }
        var stats: [S] = []
        for peer in peers {
            stats.append(S(
                peer: peer,
                interested: await peer.peerInterested,
                speed: await peer.downloadSpeed,
                choked: await peer.amChoking
            ))
        }

        let interested = stats.filter { $0.interested }
        let top4 = interested.sorted { $0.speed > $1.speed }.prefix(4).map { $0.peer }

        // Rotate optimistic unchoke every 30s or if the slot closed
        var rotate = now.timeIntervalSince(lastRotation) >= 30 || optimisticUnchoke == nil
        if !rotate, let opt = optimisticUnchoke {
            rotate = await opt.state == .closed
        }
        if rotate {
            let candidates = interested.filter { s in !top4.contains { $0 === s.peer } }
            optimisticUnchoke = candidates.randomElement()?.peer
            lastRotation = now
        }

        for s in stats {
            let unchoke = top4.contains { $0 === s.peer } || s.peer === optimisticUnchoke
            if unchoke && s.choked { await s.peer.sendUnchoke() }
            else if !unchoke && !s.choked { await s.peer.sendChoke() }
        }
    }
}
