import Foundation

/// Mapping 層（白皮書 5.3）：角度 → 動畫進度 p ∈ [0,1]。
///
/// M2 只做 p 本身。模糊、變暗的曲線是 M4 的事，先不寫。
public enum Mapping {

    /// p = 0 在 θ_open（內容該完全清楚、不動），p = 1 在 θ_off（螢幕要關了）。
    public static func progress(theta: Double, thetaOpen: Double,
                                thetaOff: Double = Tuning.thetaOff) -> Double {
        let span = thetaOpen - thetaOff
        guard span > 1 else { return 0 }
        return min(max((thetaOpen - theta) / span, 0), 1)
    }

    /// 幾何投影用的轉過角度 Δθ（白皮書 5.3：投影用 Δθ 本身，不用 p）。
    public static func deltaTheta(theta: Double, thetaOpen: Double) -> Double {
        max(thetaOpen - theta, 0)
    }

    /// 整體變暗的程度 0–1（白皮書 5.3 的初版曲線）。
    public static func dim(p: Double) -> Double {
        Tuning.dimMax * smoothstep(Tuning.dimStart, 1, p)
    }

    /// 漸進模糊的遮罩位置。
    ///
    /// 模糊前緣隨 p 從「螢幕外一點」掃到「另一側螢幕外一點」，
    /// 所以 p=0 時整面都還是最清晰那層、p=1 時整面都被掃過。
    ///
    /// - Parameters:
    ///   - p: 動畫進度 0–1。
    ///   - indexFromSharpest: 0 = 最清晰那層，數字越大越模糊。
    ///   - layerCount: 總共疊了幾層。
    /// - Returns: 遮罩的兩個位置 `(lo, hi)`，都在 0–1。
    ///   `lo` 以下完全藏起來，`hi` 以上完全露出，中間線性過渡。
    public static func sweepMask(p: Double, indexFromSharpest: Int,
                                 layerCount: Int) -> (lo: Double, hi: Double) {
        let soft = Tuning.sweepSoftness
        let stagger = Tuning.sweepStagger
        // 行程：從 −soft/2（還沒碰到螢幕）到 1 + soft/2 + 最後一層的錯開量。
        let travel = 1 + soft + Double(max(layerCount - 1, 0)) * stagger
        let front = -soft / 2 + min(max(p, 0), 1) * travel
        let edge = front - Double(indexFromSharpest) * stagger
        let lo = min(max(edge - soft / 2, 0), 1)
        let hi = min(max(edge + soft / 2, 0), 1)
        return (lo, max(lo, hi))
    }

    /// 0 → 1 之間的平滑過渡，兩端導數為 0。
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
