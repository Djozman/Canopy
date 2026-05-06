import Foundation

public enum BencodeValue: Equatable {
    case integer(Int64)
    case string(Data)
    case list([BencodeValue])
    case dict([(String, BencodeValue)])

    public static func == (lhs: BencodeValue, rhs: BencodeValue) -> Bool {
        switch (lhs, rhs) {
        case (.integer(let a), .integer(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.list(let a), .list(let b)): return a == b
        case (.dict(let a), .dict(let b)):
            guard a.count == b.count else { return false }
            for i in 0..<a.count {
                if a[i].0 != b[i].0 || a[i].1 != b[i].1 { return false }
            }
            return true
        default: return false
        }
    }
}
