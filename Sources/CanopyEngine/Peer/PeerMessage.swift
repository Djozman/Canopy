import Foundation

/// Wire-level BitTorrent peer messages (BEP 3).
public enum PeerMessage: Equatable {
    case choke              // id 0
    case unchoke            // id 1
    case interested         // id 2
    case notInterested      // id 3
    case have(piece: Int)   // id 4
    case bitfield(Data)     // id 5
    case request(piece: Int, begin: Int, length: Int)  // id 6
    case piece(piece: Int, begin: Int, data: Data)      // id 7
    case cancel(piece: Int, begin: Int, length: Int)    // id 8
    case port(port: UInt16) // id 9 (DHT)
    case keepAlive          // 0-length message
    case extended(id: UInt8, data: Data)

    /// Parse a single message from a byte stream. Returns nil if more data is needed.
    public static func decode(from data: inout Data) -> PeerMessage? {
        guard data.count >= 4 else { return nil }
        let length = Int(data[0..<4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        if length == 0 {
            data.removeFirst(4)
            return .keepAlive
        }
        guard data.count >= 4 + length else { return nil }
        let id = data[4]
        let payload = data.subdata(in: 5..<(4 + length))
        data.removeFirst(4 + length)
        return messageFrom(id: id, payload: payload)
    }

    public func encode() -> Data {
        let payload: Data
        let id: UInt8
        switch self {
        case .keepAlive: return Data([0, 0, 0, 0])
        case .choke:           payload = Data(); id = 0
        case .unchoke:         payload = Data(); id = 1
        case .interested:      payload = Data(); id = 2
        case .notInterested:   payload = Data(); id = 3
        case .have(let piece): payload = piece.encodeBigEndian(); id = 4
        case .bitfield(let d): payload = d; id = 5
        case .request(let p, let b, let l):
            payload = p.encodeBigEndian() + b.encodeBigEndian() + l.encodeBigEndian(); id = 6
        case .piece(let p, let b, let d):
            payload = p.encodeBigEndian() + b.encodeBigEndian() + d; id = 7
        case .cancel(let p, let b, let l):
            payload = p.encodeBigEndian() + b.encodeBigEndian() + l.encodeBigEndian(); id = 8
        case .port(let port):
            payload = Data([UInt8(port >> 8), UInt8(port & 0xFF)]); id = 9
        case .extended(let extID, let d):
            payload = Data([extID]) + d; id = 20
        }
        let length = UInt32(1 + payload.count)
        return length.encodeBigEndian() + Data([id]) + payload
    }

    private static func messageFrom(id: UInt8, payload: Data) -> PeerMessage {
        switch id {
        case 0: return .choke
        case 1: return .unchoke
        case 2: return .interested
        case 3: return .notInterested
        case 4:
            let piece = Int(payload.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            return .have(piece: piece)
        case 5: return .bitfield(payload)
        case 6:
            let p = Int(payload[0..<4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            let b = Int(payload[4..<8].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            let l = Int(payload[8..<12].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            return .request(piece: p, begin: b, length: l)
        case 7:
            let p = Int(payload[0..<4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            let b = Int(payload[4..<8].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            return .piece(piece: p, begin: b, data: payload.subdata(in: 8..<payload.count))
        case 8:
            let p = Int(payload[0..<4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            let b = Int(payload[4..<8].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            let l = Int(payload[8..<12].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            return .cancel(piece: p, begin: b, length: l)
        case 9:
            let port = payload.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            return .port(port: port)
        case 20:
            guard payload.count > 0 else { return .extended(id: 0, data: payload) }
            return .extended(id: payload[0], data: payload.count > 1 ? payload.subdata(in: 1..<payload.count) : Data())
        default: return .extended(id: id, data: payload)
        }
    }
}

private extension Int {
    func encodeBigEndian() -> Data {
        var val = UInt32(self).bigEndian
        return Data(bytes: &val, count: 4)
    }
}

private extension UInt32 {
    func encodeBigEndian() -> Data {
        var val = self.bigEndian
        return Data(bytes: &val, count: 4)
    }
}
