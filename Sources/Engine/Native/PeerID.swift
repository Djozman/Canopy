// PeerID.swift — BEP 20 Azureus-style peer id.
// Layout: '-' + 2-char client id + 4-char version + '-' + 12 random bytes = 20 bytes.
// "CY" = Canopy. Example: -CY2520-xxxxxxxxxxxx

import Foundation

public enum PeerID {
    public static func generate(clientID: String = "CY", version: String = "2520") -> Data {
        precondition(clientID.utf8.count == 2, "client id must be exactly 2 ASCII chars")
        var ver = Array(version.utf8.prefix(4))
        while ver.count < 4 { ver.append(UInt8(ascii: "0")) }

        var id = Data()
        id.append(UInt8(ascii: "-"))
        id.append(contentsOf: clientID.utf8)
        id.append(contentsOf: ver)
        id.append(UInt8(ascii: "-"))
        while id.count < 20 { id.append(UInt8.random(in: 0...255)) }
        return id
    }

    /// Human-readable form for logging (non-ASCII bytes shown as '.').
    public static func describe(_ id: Data) -> String {
        String(id.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }
}
