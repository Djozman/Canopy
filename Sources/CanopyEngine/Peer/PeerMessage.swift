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
        let bytes = Array(data) // Avoid Data subscript crashes on ARM64 macOS 26
        guard bytes.count >= 4 else { return nil }
        let length = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        if length == 0 {
            data.removeFirst(4)
            return .keepAlive
        }
        guard bytes.count >= 4 + length else { return nil }
        let id = bytes[4]
        let payload = Data(bytes[5..<(4 + length)])
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
            guard payload.count >= 4 else { return .extended(id: id, data: payload) }
            let b = Array(payload)
            let piece = (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            return .have(piece: piece)
        case 5: return .bitfield(payload)
        case 6:
            guard payload.count >= 12 else { return .extended(id: id, data: payload) }
            let b = Array(payload)
            let p = (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            let beg = (Int(b[4]) << 24) | (Int(b[5]) << 16) | (Int(b[6]) << 8) | Int(b[7])
            let len = (Int(b[8]) << 24) | (Int(b[9]) << 16) | (Int(b[10]) << 8) | Int(b[11])
            return .request(piece: p, begin: beg, length: len)
        case 7:
            guard payload.count >= 8 else { return .extended(id: id, data: payload) }
            let b = Array(payload)
            let p = (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            let beg = (Int(b[4]) << 24) | (Int(b[5]) << 16) | (Int(b[6]) << 8) | Int(b[7])
            return .piece(piece: p, begin: beg, data: payload.count > 8 ? payload.subdata(in: 8..<payload.count) : Data())
        case 8:
            guard payload.count >= 12 else { return .extended(id: id, data: payload) }
            let b = Array(payload)
            let p = (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            let beg = (Int(b[4]) << 24) | (Int(b[5]) << 16) | (Int(b[6]) << 8) | Int(b[7])
            let len = (Int(b[8]) << 24) | (Int(b[9]) << 16) | (Int(b[10]) << 8) | Int(b[11])
            return .cancel(piece: p, begin: beg, length: len)
        case 9:
            guard payload.count >= 2 else { return .extended(id: id, data: payload) }
            let b = Array(payload)
            let port = (UInt16(b[0]) << 8) | UInt16(b[1])
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
        var val = UInt32(clamping: self).bigEndian
        return Data(bytes: &val, count: 4)
    }
}

private extension UInt32 {
    func encodeBigEndian() -> Data {
        var val = self.bigEndian
        return Data(bytes: &val, count: 4)
    }
}
