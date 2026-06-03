//  PeerMessage.swift
//  Canopy — Native Swift Engine
//
//  BEP 3 peer-wire protocol: the handshake, the length-prefixed message
//  framing, and the nine core message types. Pure value types with no I/O —
//  PeerConnection.swift owns the socket.

import Foundation

// MARK: - Errors

enum PeerWireError: Error, Equatable {
    case handshakeFailed
    case infoHashMismatch
    case peerIDMismatch
    case unknownMessageID(UInt8)
    case malformed(PeerMessage.ID)
    case messageTooLarge(UInt32)
    case connectionClosed
}

// MARK: - Handshake

struct PeerHandshake: Equatable {
    static let protocolName = "BitTorrent protocol"
    static let wireLength = 68

    var reserved: [UInt8]
    var infoHash: [UInt8]
    var peerID: [UInt8]

    init(infoHash: [UInt8], peerID: [UInt8], reserved: [UInt8] = [UInt8](repeating: 0, count: 8)) {
        precondition(infoHash.count == 20, "info_hash must be 20 bytes")
        precondition(peerID.count == 20, "peer_id must be 20 bytes")
        precondition(reserved.count == 8, "reserved must be 8 bytes")
        self.infoHash = infoHash
        self.peerID = peerID
        self.reserved = reserved
    }

    func encode() -> Data {
        let pstr = Array(Self.protocolName.utf8)
        var data = Data(capacity: Self.wireLength)
        data.append(UInt8(pstr.count))
        data.append(contentsOf: pstr)
        data.append(contentsOf: reserved)
        data.append(contentsOf: infoHash)
        data.append(contentsOf: peerID)
        return data
    }

    init?(decoding data: Data) {
        guard data.count == Self.wireLength else { return nil }
        let bytes = [UInt8](data)
        let pstrLen = Int(bytes[0])
        let expectedPstr = Array(Self.protocolName.utf8)
        guard pstrLen == expectedPstr.count, Array(bytes[1..<(1 + pstrLen)]) == expectedPstr else {
            return nil
        }
        var i = 1 + pstrLen
        reserved = Array(bytes[i..<(i + 8)])
        i += 8
        infoHash = Array(bytes[i..<(i + 20)])
        i += 20
        peerID = Array(bytes[i..<(i + 20)])
        i += 20
    }
}

// MARK: - Messages

enum PeerMessage: Equatable {
    case keepAlive
    case choke, unchoke, interested, notInterested
    case have(pieceIndex: UInt32)
    case bitfield(Data)
    case request(index: UInt32, begin: UInt32, length: UInt32)
    case piece(index: UInt32, begin: UInt32, block: Data)
    case cancel(index: UInt32, begin: UInt32, length: UInt32)

    enum ID: UInt8 {
        case choke = 0, unchoke = 1, interested = 2, notInterested = 3
        case have = 4, bitfield = 5, request = 6, piece = 7, cancel = 8
    }

    func encode() -> Data {
        var body = Data()
        switch self {
        case .keepAlive: break
        case .choke: body.append(ID.choke.rawValue)
        case .unchoke: body.append(ID.unchoke.rawValue)
        case .interested: body.append(ID.interested.rawValue)
        case .notInterested: body.append(ID.notInterested.rawValue)
        case .have(let index):
            body.append(ID.have.rawValue)
            body.appendUInt32BE(index)
        case .bitfield(let bits):
            body.append(ID.bitfield.rawValue)
            body.append(bits)
        case .request(let index, let begin, let length):
            body.append(ID.request.rawValue)
            body.appendUInt32BE(index)
            body.appendUInt32BE(begin)
            body.appendUInt32BE(length)
        case .piece(let index, let begin, let block):
            body.append(ID.piece.rawValue)
            body.appendUInt32BE(index)
            body.appendUInt32BE(begin)
            body.append(block)
        case .cancel(let index, let begin, let length):
            body.append(ID.cancel.rawValue)
            body.appendUInt32BE(index)
            body.appendUInt32BE(begin)
            body.appendUInt32BE(length)
        }
        var out = Data(capacity: 4 + body.count)
        out.appendUInt32BE(UInt32(body.count))
        out.append(body)
        return out
    }

    static func decode(body: Data) throws -> PeerMessage {
        guard !body.isEmpty else { return .keepAlive }
        let firstByte = body[body.startIndex]
        guard let id = ID(rawValue: firstByte) else {
            throw PeerWireError.unknownMessageID(firstByte)
        }
        let payload = Data(body[(body.startIndex + 1)...])
        switch id {
        case .choke:
            try requireEmpty(payload, id)
            return .choke
        case .unchoke:
            try requireEmpty(payload, id)
            return .unchoke
        case .interested:
            try requireEmpty(payload, id)
            return .interested
        case .notInterested:
            try requireEmpty(payload, id)
            return .notInterested
        case .have:
            guard payload.count == 4 else { throw PeerWireError.malformed(id) }
            return .have(pieceIndex: payload.readUInt32BE(at: 0))
        case .bitfield: return .bitfield(payload)
        case .request:
            guard payload.count == 12 else { throw PeerWireError.malformed(id) }
            return .request(
                index: payload.readUInt32BE(at: 0), begin: payload.readUInt32BE(at: 4),
                length: payload.readUInt32BE(at: 8))
        case .piece:
            guard payload.count >= 8 else { throw PeerWireError.malformed(id) }
            return .piece(
                index: payload.readUInt32BE(at: 0), begin: payload.readUInt32BE(at: 4),
                block: Data(payload[(payload.startIndex + 8)...]))
        case .cancel:
            guard payload.count == 12 else { throw PeerWireError.malformed(id) }
            return .cancel(
                index: payload.readUInt32BE(at: 0), begin: payload.readUInt32BE(at: 4),
                length: payload.readUInt32BE(at: 8))
        }
    }

    private static func requireEmpty(_ payload: Data, _ id: ID) throws {
        guard payload.isEmpty else { throw PeerWireError.malformed(id) }
    }
}

// MARK: - Bitfield

struct Bitfield: Equatable {
    private(set) var bytes: [UInt8]
    let count: Int

    init(pieceCount: Int) {
        self.count = pieceCount
        self.bytes = [UInt8](repeating: 0, count: (pieceCount + 7) / 8)
    }

    init?(payload: Data, pieceCount: Int) {
        let expected = (pieceCount + 7) / 8
        guard payload.count == expected else { return nil }
        let spare = expected * 8 - pieceCount
        if spare > 0, let last = payload.last {
            let mask = UInt8((1 << spare) - 1)
            guard last & mask == 0 else { return nil }
        }
        self.count = pieceCount
        self.bytes = [UInt8](payload)
    }

    func has(_ index: Int) -> Bool {
        guard index >= 0, index < count else { return false }
        return bytes[index >> 3] & (0x80 >> UInt8(index & 7)) != 0
    }

    mutating func set(_ index: Int) {
        guard index >= 0, index < count else { return }
        bytes[index >> 3] |= (0x80 >> UInt8(index & 7))
    }

    var payload: Data { Data(bytes) }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        let b = startIndex + offset
        return (UInt32(self[b]) << 24) | (UInt32(self[b + 1]) << 16) | (UInt32(self[b + 2]) << 8)
            | UInt32(self[b + 3])
    }
}
