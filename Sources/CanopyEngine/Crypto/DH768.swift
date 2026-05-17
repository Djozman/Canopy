import Foundation

enum DH768 {
    typealias Limb = UInt64
    static let limbCount = 12

    // BEP 8 / RFC 2409 768-bit MODP group (Group 1)
    // Little-endian limb array (limb[0] = least significant)
    static let primeLimbs: [Limb] = [
        0xFFFFFFFFFFFFFFFF,
        0xF44C42E9A63A3620,
        0xE485B576625E7EC6,
        0x4FE1356D6D51C245,
        0x302B0A6DF25F1437,
        0xEF9519B3CD3A431B,
        0x514A08798E3404DD,
        0x020BBEA63B139B22,
        0x29024E088A67CC74,
        0xC4C6628B80DC1CD1,
        0xC90FDAA22168C234,
        0xFFFFFFFFFFFFFFFF,
    ]

    static let G = 2  // generator

    static let primeMinusOneLimbs: [Limb] = [
        0xFFFFFFFFFFFFFFFE,
        0xF44C42E9A63A3620,
        0xE485B576625E7EC6,
        0x4FE1356D6D51C245,
        0x302B0A6DF25F1437,
        0xEF9519B3CD3A431B,
        0x514A08798E3404DD,
        0x020BBEA63B139B22,
        0x29024E088A67CC74,
        0xC4C6628B80DC1CD1,
        0xC90FDAA22168C234,
        0xFFFFFFFFFFFFFFFF,
    ]

    // MARK: - Public API

    static func isValidPublicKey(_ data: Data) -> Bool {
        guard data.count == limbCount * 8 else { return false }
        let limbs = limbsFromBEBytes(data)
        let zero: [Limb] = [Limb](repeating: 0, count: limbCount)
        let one: [Limb] = [1] + [Limb](repeating: 0, count: limbCount - 1)
        if limbs == zero { return false }
        if limbs == one { return false }
        if compare(limbs, primeMinusOneLimbs) >= 0 { return false }
        return true
    }

    /// Returns a 160-bit random private key and its corresponding 768-bit public value.
    static func generateKeypair() -> (privateKey: Data, publicKey: Data) {
        var priv = Data(count: 20)
        _ = priv.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, 20, buf.baseAddress!)
        }
        priv[19] |= 1  // ensure odd (per BEP 8: private key must be non-zero, odd)
        let pub = modExp(base: G, exponent: priv, modulus: primeLimbs)
        return (priv, pub)
    }

    /// Compute the DH shared secret given a peer's public key and our private key.
    static func computeShared(publicKey pubKeyData: Data, privateKey: Data) -> Data {
        let pubLimbs = limbsFromBEBytes(pubKeyData)
        return modExp(base: pubLimbs, exponent: privateKey, modulus: primeLimbs)
    }

    static func limbsToData(_ limbs: [Limb]) -> Data {
        var result = Data(capacity: limbCount * 8)
        for i in (0..<limbCount).reversed() {
            var be = limbs[i].bigEndian
            result.append(Data(bytes: &be, count: 8))
        }
        return result
    }

    static func limbsFromBEBytes(_ data: Data) -> [Limb] {
        var limbs = [Limb](repeating: 0, count: limbCount)
        let bytes = Array(data)
        let byteCount = min(bytes.count, limbCount * 8)
        for bi in 0..<byteCount {
            let li = limbCount - 1 - (bi / 8)
            let shift = (7 - (bi % 8)) * 8
            limbs[li] |= Limb(bytes[bi]) << shift
        }
        return limbs
    }

    // MARK: - Modular exponentiation

    static func modExp(base: [Limb], exponent: Data, modulus: [Limb]) -> Data {
        modExp(baseLimbs: parseBase(base), exponentBytes: exponent, modulus: modulus)
    }

    static func modExp(base: Int, exponent: Data, modulus: [Limb]) -> Data {
        modExp(baseLimbs: limbArray(base), exponentBytes: exponent, modulus: modulus)
    }

    private static func modExp(baseLimbs: [Limb], exponentBytes: Data, modulus: [Limb]) -> Data {
        var result = limbArray(1)
        let base = reduce(baseLimbs, modulo: modulus) // immutable, only squared by reference

        for byte in exponentBytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                result = reduce(multiply(result, result), modulo: modulus)
                if (byte >> bit) & 1 == 1 {
                    result = reduce(multiply(result, base), modulo: modulus)
                }
            }
        }
        return limbsToData(result)
    }

    // MARK: - Limbs helpers

    static func limbArray(_ value: Int) -> [Limb] {
        var arr = [Limb](repeating: 0, count: limbCount)
        arr[0] = Limb(value)
        return arr
    }

    private static func parseBase(_ limbs: [Limb]) -> [Limb] {
        if limbs.count >= limbCount { return Array(limbs[0..<limbCount]) }
        var arr = [Limb](repeating: 0, count: limbCount)
        for i in 0..<limbs.count { arr[i] = limbs[i] }
        return arr
    }

    // MARK: - Schoolbook multiplication

    private static func multiply(_ a: [Limb], _ b: [Limb]) -> [UInt64] {
        let n = max(a.count, b.count)
        var product = [UInt64](repeating: 0, count: 2 * n)
        for ai in 0..<n {
            let av = ai < a.count ? a[ai] : 0
            guard av != 0 else { continue }
            var carry: UInt64 = 0
            for bi in 0..<n {
                let bv = bi < b.count ? b[bi] : 0
                let (lo, hi) = mul128(av, bv)
                var sum = lo &+ carry
                carry = (sum < lo ? 1 : 0) &+ hi
                sum = product[ai + bi] &+ sum
                if sum < product[ai + bi] { carry = carry &+ 1 }
                product[ai + bi] = sum
            }
            var idx = ai + n
            while carry != 0, idx < product.count {
                let sum = product[idx] &+ carry
                carry = sum < product[idx] ? 1 : 0
                product[idx] = sum
                idx += 1
            }
        }
        return product
    }

    /// 64×64 → 128-bit multiplication. Returns (low 64 bits, high 64 bits).
    private static func mul128(_ a: UInt64, _ b: UInt64) -> (UInt64, UInt64) {
        let alo = UInt64(a & 0xFFFFFFFF)
        let ahi = a >> 32
        let blo = UInt64(b & 0xFFFFFFFF)
        let bhi = b >> 32
        let lolo = alo &* blo
        let mid1 = ahi &* blo
        let mid2 = alo &* bhi
        let hihi = ahi &* bhi
        let mid = mid1 &+ mid2
        let midCarry: UInt64 = (mid < mid1) ? 1 : 0
        let low = lolo &+ (mid << 32)
        let lowCarry: UInt64 = (low < lolo) ? 1 : 0
        let high = hihi &+ (mid >> 32) &+ (midCarry << 32) &+ lowCarry
        return (low, high)
    }

    // MARK: - Modular reduction (shift-subtract)

    private static func reduce(_ n: [UInt64], modulo mod: [Limb]) -> [Limb] {
        var r = stripTrailingZeros(n)
        let m = stripTrailingZeros([Limb](mod.prefix(limbCount)))

        if compare(r, m) < 0 {
            return padToLimbs(r, count: limbCount)
        }

        while compare(r, m) >= 0 {
            let shift = max(0, bitLength(r) - bitLength(m))
            let aligned = shiftLeft(m, by: shift)
            if compare(r, aligned) >= 0 {
                r = subtract(r, aligned)
            } else if shift > 0 {
                r = subtract(r, shiftLeft(m, by: shift - 1))
            } else {
                r = subtract(r, [UInt64](m))
            }
            r = stripTrailingZeros(r)
            if r.isEmpty { r = [0] }
        }

        return padToLimbs(r, count: limbCount)
    }

    // MARK: - Utility helpers

    private static func bitLength(_ n: [UInt64]) -> Int {
        guard let last = n.last, last != 0 else { return 0 }
        return (n.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    private static func stripTrailingZeros(_ n: [UInt64]) -> [UInt64] {
        var n = n
        while n.count > 1, n.last == 0 { n.removeLast() }
        return n
    }

    private static func shiftLeft(_ a: [UInt64], by bits: Int) -> [UInt64] {
        guard bits > 0, !a.isEmpty else { return a }
        let wordShift = bits / 64
        let bitShift = bits % 64
        var result = [UInt64](repeating: 0, count: a.count + wordShift + (bitShift > 0 ? 1 : 0))
        for i in 0..<a.count {
            let idx = i + wordShift
            result[idx] |= a[i] << bitShift
            if bitShift > 0 {
                result[idx + 1] |= a[i] >> (64 - bitShift)
            }
        }
        return stripTrailingZeros(result)
    }

    private static func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
        let n = max(a.count, b.count)
        for i in stride(from: n - 1, through: 0, by: -1) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av > bv { return 1 }
            if av < bv { return -1 }
        }
        return 0
    }

    private static func subtract(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let n = max(a.count, b.count)
        var result = [UInt64](repeating: 0, count: n)
        var borrow: UInt64 = 0
        for i in 0..<n {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            let (diff, b1) = av.subtractingReportingOverflow(bv)
            let (finalDiff, b2) = diff.subtractingReportingOverflow(borrow)
            result[i] = finalDiff
            borrow = (b1 ? 1 : 0) &+ (b2 ? 1 : 0)
        }
        return stripTrailingZeros(result)
    }

    private static func padToLimbs(_ a: [UInt64], count: Int) -> [Limb] {
        var result = [Limb](repeating: 0, count: count)
        for i in 0..<min(a.count, count) { result[i] = Limb(a[i]) }
        return result
    }
}
