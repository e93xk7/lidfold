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
}
