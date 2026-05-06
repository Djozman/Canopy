/// Leecher: connects to our engine at 127.0.0.1:6881 and downloads.
/// Run AFTER starting SeedOnly.
/// Run: swift run -c debug LeechOnly 2>/dev/null
/// Proves upload works end-to-end.

import Foundation
import CanopyEngine
import Network

@main
struct LeechOnly {
    static func main() async {
        let torrentPath = "Tests/CanopyEngine/TestTorrents/debian-13.4.0-amd64-netinst.iso.torrent"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: torrentPath)),
              let torrent = try? TorrentParser.parse(data: data) else {
            print("[LeechOnly] ❌ Could not parse torrent")
            return
        }

        print("[LeechOnly] Info hash: \(torrent.infoHash.hexString)")
        print("[LeechOnly] Connecting to 127.0.0.1:6881...")

        let peer = Peer(ip: "127.0.0.1", port: 6881)
        let conn = PeerConnection(peer: peer, infoHash: torrent.infoHash, localPeerID: PeerID.current)

        let stream: AsyncStream<PeerMessage>
        do {
            stream = try await conn.connect()
            print("[LeechOnly] ✅ Connected!")

            // We're interested — request a piece
            try? await conn.send(.interested)
            print("[LeechOnly] Sent interested")
        } catch {
            print("[LeechOnly] ❌ Connect failed: \(error)")
            return
        }

        // Track state
        var pieceData: [Int: Data] = [:]
        var pieceBlocks: Set<String> = []
        let pieceManager = PieceManager(
            pieceCount: torrent.pieces.count,
            pieceLength: torrent.pieceLength,
            totalSize: torrent.totalSize,
            expectedHashes: torrent.pieces
        )

        let targetPiece: Int

        // Receive bitfield to find a piece, or pick piece 0
        var chosenPiece: Int?
        for await msg in stream {
            switch msg {
            case .bitfield(let bf):
                // Find first available piece
                let bytes = Array(bf)
                for (byteIdx, byte) in bytes.enumerated() {
                    for bit in 0..<8 {
                        if (byte >> (7 - bit)) & 1 == 1 {
                            let p = byteIdx * 8 + bit
                            if p < torrent.pieces.count {
                                chosenPiece = p
                                break
                            }
                        }
                    }
                    if chosenPiece != nil { break }
                }
                if let p = chosenPiece {
                    print("[LeechOnly] Seeder has piece \(p) — requesting")
                    try? await conn.send(.request(piece: p, begin: 0, length: 16384))
                    try? await conn.send(.request(piece: p, begin: 16384, length: 16384))
                    try? await conn.send(.request(piece: p, begin: 32768, length: 16384))
                    try? await conn.send(.request(piece: p, begin: 49152, length: 16384))
                    try? await conn.send(.request(piece: p, begin: 65536, length: 16384))
                }

            case .unchoke:
                print("[LeechOnly] ✨ Unchoked")

            case .piece(let piece, let begin, let data):
                print("[LeechOnly] 📦 Received piece \(piece) begin=\(begin) len=\(data.count)")
                await pieceManager.storeBlock(piece: piece, begin: begin, data: data)
                // Request more blocks if we don't have all
                if begin + data.count < 262144 {
                    let next = begin + data.count
                    try? await conn.send(.request(piece: piece, begin: next, length: 16384))
                }

                if let assembled = await pieceManager.tryAssemble(piece: piece) {
                    print("[LeechOnly] 🎉 PIECE VERIFIED! Piece \(piece) SHA1 matches")
                    print("[LeechOnly] ✅ UPLOAD WORKS — bytes transferred: \(assembled.count)")
                    await conn.disconnect()
                    return
                }

            case .choke:
                print("[LeechOnly] 🔒 Choked")

            default:
                break
            }
        }
        print("[LeechOnly] ⛔ Disconnected")
    }
}
