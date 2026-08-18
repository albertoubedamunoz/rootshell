#if !targetEnvironment(macCatalyst)

import BigInt
import Foundation

/// SIEC255 elliptic curve: y² = x³ + 19 over a 255-bit prime field.
/// Direct port of Go's `github.com/tscholl2/siec` package.
nonisolated enum CrocSIEC255 {

    /// Create the SIEC255 curve as a ShortWeierstrassCurve.
    static func makeSIEC255() -> ShortWeierstrassCurve {
        let P: BigInt = "28948022309329048855892746252183396360603931420023084536990047309120118726721"
        let N: BigInt = "28948022309329048855892746252183396360263649053102146073526672701688283398081"
        let Gx = BigInt(5)
        let Gy = BigInt(12)
        return ShortWeierstrassCurve(P: P, a: BigInt(0), b: BigInt(19), Gx: Gx, Gy: Gy, N: N)
    }
}

#endif
