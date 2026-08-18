#if !targetEnvironment(macCatalyst)

import BigInt
import Foundation

/// Protocol for elliptic curve operations needed by PAKE.
/// Matches Go's `EllipticCurve` interface in pake.go.
nonisolated protocol CrocEllipticCurve {
    /// Add two points on the curve.
    func add(_ x1: BigInt, _ y1: BigInt, _ x2: BigInt, _ y2: BigInt) -> (BigInt, BigInt)

    /// Multiply the generator point by scalar k (big-endian bytes).
    func scalarBaseMult(_ k: Data) -> (BigInt, BigInt)

    /// Multiply an arbitrary point by scalar k (big-endian bytes).
    func scalarMult(_ bx: BigInt, _ by: BigInt, _ k: Data) -> (BigInt, BigInt)

    /// Check if a point is on the curve.
    func isOnCurve(_ x: BigInt, _ y: BigInt) -> Bool

    /// The prime order of the underlying field.
    var P: BigInt { get }
}

// MARK: - Short Weierstrass Curve (y² = x³ + ax + b mod p)

/// Generic short Weierstrass curve implementation using BigInt.
/// Used for P-256, P-384, P-521, and SIEC255.
nonisolated struct ShortWeierstrassCurve: CrocEllipticCurve {
    let P: BigInt       // Field prime
    let a: BigInt       // Curve coefficient a
    let b: BigInt       // Curve coefficient b
    let Gx: BigInt      // Generator x
    let Gy: BigInt      // Generator y
    let N: BigInt       // Order of the generator

    func isOnCurve(_ x: BigInt, _ y: BigInt) -> Bool {
        // y² ≡ x³ + ax + b (mod P)
        let lhs = (y * y) % P
        var rhs = (x * x * x) % P
        rhs = (rhs + a * x + b) % P
        if rhs < 0 { rhs += P }
        return lhs == rhs
    }

    func add(_ x1: BigInt, _ y1: BigInt, _ x2: BigInt, _ y2: BigInt) -> (BigInt, BigInt) {
        // Point at infinity checks
        if x1 == 0 && y1 == 0 { return (x2, y2) }
        if x2 == 0 && y2 == 0 { return (x1, y1) }

        // Point doubling
        if x1 == x2 && y1 == y2 {
            return double(x1, y1)
        }

        // x1 == x2 but y1 != y2 → point at infinity
        let dx = (x2 - x1) % P
        if dx == 0 { return (BigInt(0), BigInt(0)) }

        // λ = (y2 - y1) / (x2 - x1) mod P
        let dy = (y2 - y1) % P
        guard let dxInv = modInverse(dx, P) else { return (BigInt(0), BigInt(0)) }
        let lambda = (dy * dxInv) % P

        // x3 = λ² - x1 - x2 mod P
        var x3 = (lambda * lambda - x1 - x2) % P
        if x3 < 0 { x3 += P }

        // y3 = λ(x1 - x3) - y1 mod P
        var y3 = (lambda * (x1 - x3) - y1) % P
        if y3 < 0 { y3 += P }

        return (x3, y3)
    }

    func double(_ x1: BigInt, _ y1: BigInt) -> (BigInt, BigInt) {
        if y1 == 0 { return (BigInt(0), BigInt(0)) }

        // λ = (3x1² + a) / (2y1) mod P
        let numerator = (3 * x1 * x1 + a) % P
        let denominator = (2 * y1) % P
        guard let denomInv = modInverse(denominator, P) else { return (BigInt(0), BigInt(0)) }
        let lambda = (numerator * denomInv) % P

        // x3 = λ² - 2x1 mod P
        var x3 = (lambda * lambda - 2 * x1) % P
        if x3 < 0 { x3 += P }

        // y3 = λ(x1 - x3) - y1 mod P
        var y3 = (lambda * (x1 - x3) - y1) % P
        if y3 < 0 { y3 += P }

        return (x3, y3)
    }

    func scalarMult(_ bx: BigInt, _ by: BigInt, _ k: Data) -> (BigInt, BigInt) {
        var rx = BigInt(0)
        var ry = BigInt(0)

        for byte in k {
            var b = byte
            for _ in 0..<8 {
                (rx, ry) = double(rx, ry)
                if b & 0x80 != 0 {
                    (rx, ry) = add(bx, by, rx, ry)
                }
                b <<= 1
            }
        }
        return (rx, ry)
    }

    func scalarBaseMult(_ k: Data) -> (BigInt, BigInt) {
        return scalarMult(Gx, Gy, k)
    }

    /// Modular inverse using extended Euclidean algorithm.
    private func modInverse(_ a: BigInt, _ m: BigInt) -> BigInt? {
        var val = a % m
        if val < 0 { val += m }
        // BigInt has an inverse method
        return val.inverse(m)
    }
}

// MARK: - Curve Definitions

/// Factory for creating elliptic curves matching Go's pake.initCurve().
nonisolated enum CrocCurveFactory {

    /// Available curve names (matches Go's pake.AvailableCurves()).
    static let availableCurves = ["p521", "p256", "p384", "siec", "ed25519"]

    /// Create a curve with its fixed U and V points for PAKE.
    /// Returns: (curve, P, Ux, Uy, Vx, Vy)
    static func initCurve(_ name: String) throws -> (curve: CrocEllipticCurve, Ux: BigInt, Uy: BigInt, Vx: BigInt, Vy: BigInt) {
        switch name {
        case "p256":
            let curve = makeP256()
            let Ux: BigInt = "793136080485469241208656611513609866400481671852"
            let Uy: BigInt = "59748757929350367369315811184980635230185250460108398961713395032485227207304"
            let Vx: BigInt = "1086685267857089638167386722555472967068468061489"
            let Vy: BigInt = "9157340230202296554417312816309453883742349874205386245733062928888341584123"
            return (curve, Ux, Uy, Vx, Vy)

        case "p384":
            let curve = makeP384()
            let Ux: BigInt = "793136080485469241208656611513609866400481671852"
            let Uy: BigInt = "7854890799382392388170852325516804266858248936799429260403044177981810983054351714387874260245230531084533936948596"
            let Vx: BigInt = "1086685267857089638167386722555472967068468061489"
            let Vy: BigInt = "21898206562669911998235297167979083576432197282633635629145270958059347586763418294901448537278960988843108277491616"
            return (curve, Ux, Uy, Vx, Vy)

        case "p521":
            let curve = makeP521()
            let Ux: BigInt = "793136080485469241208656611513609866400481671852"
            let Uy: BigInt = "4032821203812196944795502391345776760852202059010382256134592838722123385325802540879231526503456158741518531456199762365161310489884151533417829496019094620"
            let Vx: BigInt = "1086685267857089638167386722555472967068468061489"
            let Vy: BigInt = "5010916268086655347194655708160715195931018676225831839835602465999566066450501167246678404591906342753230577187831311039273858772817427392089150297708931207"
            return (curve, Ux, Uy, Vx, Vy)

        case "siec":
            let curve = CrocSIEC255.makeSIEC255()
            let Ux: BigInt = "793136080485469241208656611513609866400481671853"
            let Uy: BigInt = "18458907634222644275952014841865282643645472623913459400556233196838128612339"
            let Vx: BigInt = "1086685267857089638167386722555472967068468061489"
            let Vy: BigInt = "19593504966619549205903364028255899745298716108914514072669075231742699650911"
            return (curve, Ux, Uy, Vx, Vy)

        case "ed25519":
            let curve = CrocEdwards25519Curve()
            let Ux: BigInt = "41821174510521985817056358996007359290163947216650231187782646151092828043509"
            let Uy = BigInt(0)
            let Vx: BigInt = "1456941786990260824647297143563623381366314063537015067473110401627488371271"
            let Vy = BigInt(0)
            return (curve, Ux, Uy, Vx, Vy)

        default:
            throw CrocError.pakeInitFailed("unknown curve: \(name)")
        }
    }

    // MARK: - NIST Curve Parameters

    private static func makeP256() -> ShortWeierstrassCurve {
        // P-256 (secp256r1) parameters
        let P: BigInt = "115792089210356248762697446949407573530086143415290314195533631308867097853951"
        let a = BigInt(-3) + P // a = -3 mod P
        // swiftlint:disable:next force_unwrapping
        let b = BigInt("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b", radix: 16)!
        // swiftlint:disable:next force_unwrapping
        let Gx = BigInt("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296", radix: 16)!
        // swiftlint:disable:next force_unwrapping
        let Gy = BigInt("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5", radix: 16)!
        let N: BigInt = "115792089210356248762697446949407573529996955224135760342422259061068512044369"
        return ShortWeierstrassCurve(P: P, a: a, b: b, Gx: Gx, Gy: Gy, N: N)
    }

    private static func makeP384() -> ShortWeierstrassCurve {
        let P: BigInt = "39402006196394479212279040100143613805079739270465446667948293404245721771496870329047266088258938001861606973112319"
        let a = BigInt(-3) + P
        // swiftlint:disable:next force_unwrapping
        let b = BigInt("b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef", radix: 16)!
        // swiftlint:disable:next force_unwrapping
        let Gx = BigInt("aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7", radix: 16)!
        // swiftlint:disable:next force_unwrapping
        let Gy = BigInt("3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f", radix: 16)!
        let N: BigInt = "39402006196394479212279040100143613805079739270465446667946905279627659399113263569398956308152294913554433653942643"
        return ShortWeierstrassCurve(P: P, a: a, b: b, Gx: Gx, Gy: Gy, N: N)
    }

    private static func makeP521() -> ShortWeierstrassCurve {
        let P: BigInt = "6864797660130609714981900799081393217269435300143305409394463459185543183397656052122559640661454554977296311391480858037121987999716643812574028291115057151"
        let a = BigInt(-3) + P
        // swiftlint:disable:next force_unwrapping
        let b = BigInt("051953eb9618e1c9a1f929a21a0b68540eea2da725b99b315f3b8b489918ef109e156193951ec7e937b1652c0bd3bb1bf073573df883d2c34f1ef451fd46b503f00", radix: 16)!
        // swiftlint:disable:next force_unwrapping
        let Gx = BigInt("c6858e06b70404e9cd9e3ecb662395b4429c648139053fb521f828af606b4d3dbaa14b5e77efe75928fe1dc127a2ffa8de3348b3c1856a429bf97e7e31c2e5bd66", radix: 16)!
        // swiftlint:disable:next force_unwrapping
        let Gy = BigInt("11839296a789a3bc0045c8a5fb42c7d1bd998f54449579b446817afbd17273e662c97ee72995ef42640c550b9013fad0761353c7086a272c24088be94769fd16650", radix: 16)!
        let N: BigInt = "6864797660130609714981900799081393217269435300143305409394463459185543183397655394245057746333217197532963996371363321113864768612440380340372808892707005449"
        return ShortWeierstrassCurve(P: P, a: a, b: b, Gx: Gx, Gy: Gy, N: N)
    }
}

#endif
