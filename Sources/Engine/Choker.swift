import Foundation

/// BEP 3 tit-for-tat choking: unchoke the top 4 fastest uploaders + 1 optimistic peer.
actor Choker {
    private var optimisticUnchoke: PeerConnection?
    private var lastRotation: Date = .now

    init() {}

    func update(peers: [PeerConnection], isSeeding: Bool) async {
        let now = Date.now

        struct S { let peer: PeerConnection; let interested: Bool; let speed: Int64; let choked: Bool; let snubbed: Bool }
        var stats: [S] = []
        for peer in peers {
            let lastBlock = await peer.lastBlockReceivedTime
            let isSnubbed = !isSeeding && (now.timeIntervalSince(lastBlock) > 60)
            
            stats.append(S(
                peer: peer,
                interested: await peer.peerInterested,
                speed: isSeeding ? await peer.uploadSpeed : await peer.downloadSpeed,
                choked: await peer.amChoking,
                snubbed: isSnubbed
            ))
        }

        let interested = stats.filter { $0.interested }
        
        // Exclude snubbed peers from the standard unchoke slots (tit-for-tat)
        let unchokeCandidates = interested.filter { !$0.snubbed }
        let top4 = unchokeCandidates.sorted { $0.speed > $1.speed }.prefix(4).map { $0.peer }

        // Rotate optimistic unchoke every 30s or if the slot closed
        var rotate = now.timeIntervalSince(lastRotation) >= 30 || optimisticUnchoke == nil
        if !rotate, let opt = optimisticUnchoke {
            rotate = await opt.state == .closed
        }
        
        // Anti-snubbing: if all our unchoked peers are snubbed, we rotate optimistic unchoke more frequently to find better peers
        if !rotate && unchokeCandidates.isEmpty && !interested.isEmpty {
            rotate = true
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
