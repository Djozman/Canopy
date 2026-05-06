import Foundation
import CryptoKit

public struct SHA1 {
    public static func hash(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    public static func hash(_ string: String) -> Data {
        hash(Data(string.utf8))
    }
}

public extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
