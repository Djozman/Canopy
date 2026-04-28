import Foundation

// BEP 3 tit-for-tat choking: unchoke top 4 fastest uploaders + 1 optimistic peer.
actor Choker {
    private var optimisticId: ObjectIdentifier?
    private var lastRotation: Date = .now

    init() {}

    func update(peers: [any AnyPeer], isSeeding: Bool) async {
        let now = Date.now

        struct S { let peer: any AnyPeer; let id: ObjectIdentifier
                   let interested: Bool; let speed: Int64; let choked: Bool; let snubbed: Bool }

        var stats: [S] = []
        for peer in peers {
            let lastBlock = await peer.lastBlockReceivedTime
            let snubbed   = !isSeeding && now.timeIntervalSince(lastBlock) > 30
            stats.append(S(
                peer:       peer,
                id:         ObjectIdentifier(peer),
                interested: await peer.peerInterested,
                speed:      isSeeding ? await peer.uploadSpeed : await peer.downloadSpeed,
                choked:     await peer.amChoking,
                snubbed:    snubbed
            ))
        }

        let interested         = stats.filter { $0.interested }
        let unchokeCandidates  = interested.filter { !$0.snubbed }
        // Unchoke top 8 (was 4) — more parallel upload slots, more tit-for-tat reciprocity.
        let top4ids            = Set(unchokeCandidates.sorted { $0.speed > $1.speed }.prefix(8).map { $0.id })

        // Rotate optimistic unchoke every 30 s, if the previous opt peer closed, or all are snubbed
        var rotate = now.timeIntervalSince(lastRotation) >= 30 || optimisticId == nil
        if !rotate, let oid = optimisticId {
            rotate = await peers.first(where: { ObjectIdentifier($0) == oid })?.isClosed ?? true
        }
        if !rotate && unchokeCandidates.isEmpty && !interested.isEmpty { rotate = true }

        if rotate {
            let candidates = interested.filter { !top4ids.contains($0.id) }
            optimisticId = candidates.randomElement().map { ObjectIdentifier($0.peer) }
            lastRotation = now
        }

        for s in stats {
            let unchoke = top4ids.contains(s.id) || s.id == optimisticId
            if  unchoke && s.choked  { await s.peer.sendUnchoke() }
            if !unchoke && !s.choked { await s.peer.sendChoke()   }
        }
    }
}
