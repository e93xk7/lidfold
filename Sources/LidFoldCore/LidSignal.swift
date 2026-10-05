import Foundation

/// Signal 層的一次輸出。
public struct SignalOutput {
    /// 平滑後的角度（度）。
    public let theta: Double
    /// 角速度（°/s），負值 = 正在闔上。
    public let omega: Double
    /// 這一筆是不是感測器真的更新了（不是輪詢讀到同一個舊值）。
    public let isNewUpdate: Bool
    /// 距離上一次感測器更新多久（秒）。
    public let sinceUpdate: Double
}

/// Signal 層：平滑 + 角速度。
///
/// 關鍵：感測器只有 10 Hz，但我們輪詢 120 Hz，所以大多數讀到的是同一個舊值。
/// 只有「值真的變了」才算一次更新，ω 也只在更新時重算 —— 不然會算出一堆 0。
public final class LidSignal {
    /// 最近幾次感測器更新：(時間, 平滑後角度)。
    private var updates: [(t: Double, theta: Double)] = []
    private var lastRawFine: UInt32?
    private var smoothed: Double?
    private var lastUpdateTime: Double?
    /// 被扣住等確認的可疑讀數。
    private var heldSpike: Double?
    /// 擋掉幾筆假跳值，除錯用。
    public private(set) var spikesRejected = 0

    public init() {}

    public func reset() {
        updates.removeAll()
        lastRawFine = nil
        smoothed = nil
        lastUpdateTime = nil
        heldSpike = nil
    }

    /// 餵一筆感測器讀數進來。
    public func ingest(_ sample: LidAngleSample) -> SignalOutput {
        var isNew = (lastRawFine != sample.rawFine)
        lastRawFine = sample.rawFine

        // 假跳值防護：單筆讀數隱含的角速度超過物理上限時先扣住，
        // 等下一次更新確認方向一致才採信。實測遇過 114° 瞬間變 0° 再跳回來。
        if isNew, let prev = updates.last {
            let dt = sample.timestamp - prev.t
            if dt > 0, abs((sample.theta - prev.theta) / dt) > Tuning.maxPlausibleOmega {
                if let held = heldSpike,
                   abs(sample.theta - held) <= Tuning.maxPlausibleOmega * dt {
                    // 下一筆也落在同一區 → 不是雜訊，是真的動這麼快，放行。
                    heldSpike = nil
                } else {
                    heldSpike = sample.theta
                    spikesRejected += 1
                    isNew = false
                }
            } else {
                heldSpike = nil
            }
        }

        if isNew {
            // 一階低通。M1 量到雜訊極小，所以 α 高、幾乎不延遲。
            let s = smoothed.map { Tuning.alpha * sample.theta + (1 - Tuning.alpha) * $0 }
                ?? sample.theta
            smoothed = s
            lastUpdateTime = sample.timestamp
            updates.append((sample.timestamp, s))
            if updates.count > Tuning.velocityWindow { updates.removeFirst() }
        }

        // 上蓋停住時感測器就不再變值了。太久沒更新就當作停下來，
        // 不然最後一次的 ω 會一直掛著，狀態機永遠停在「闔上中」。
        let since = lastUpdateTime.map { sample.timestamp - $0 } ?? 0
        return SignalOutput(
            theta: smoothed ?? sample.theta,
            omega: since > Tuning.staleAfter ? 0 : velocity(),
            isNewUpdate: isNew,
            sinceUpdate: since
        )
    }

    /// 最近 N 次更新的最小平方斜率（白皮書 5.2：用最近 3 個樣本做差分）。
    private func velocity() -> Double {
        guard updates.count >= 2 else { return 0 }
        let n = Double(updates.count)
        let meanT = updates.reduce(0) { $0 + $1.t } / n
        let meanTheta = updates.reduce(0) { $0 + $1.theta } / n
        var num = 0.0, den = 0.0
        for u in updates {
            let dt = u.t - meanT
            num += dt * (u.theta - meanTheta)
            den += dt * dt
        }
        return den > 0 ? num / den : 0
    }

    /// 最近一次感測器更新的 (時間, 角度)，給插值用。
    public var lastUpdate: (t: Double, theta: Double)? { updates.last }
}

/// 把 10 Hz 的角度變成任意時刻都能問的連續角度。
///
/// 做法：**等速外推 + 只對誤差做指數衰減**。
///
///     θ̂(t) = θ_k + ω·(t − t_k) + offset·e^(−(t−t_update)/τ)
///
/// 第一項是物理預測，所以等速運動時**沒有延遲**；每次感測器更新時，把「舊輸出與
/// 新預測的落差」記成 offset，再讓它用 τ 衰減掉 —— 畫面不會在更新那一刻跳一下。
///
/// 一開始用「阻尼追蹤外推目標」寫過一版，平順但動作中落後 8.5°（快闔時最大 25°）：
/// 追蹤器對斜坡輸入本來就有 2τ 的穩態誤差。錯覺要的是「畫出來的角度等於上蓋的實際
/// 角度」，落後 8.5° 等於內容整個歪掉，所以改成這個零延遲的版本。
public final class AnglePredictor {
    private var output: Double = 0
    private var offset: Double = 0
    private var offsetTime: Double = 0
    private var lastUpdateTime: Double?
    private var started = false

    public init() {}

    public func reset(to theta: Double) {
        output = theta
        offset = 0
        offsetTime = 0
        lastUpdateTime = nil
        started = true
    }

    /// 問「現在」該畫幾度。`now` 用同一個單調時鐘。
    public func angle(now: Double, lastUpdate: (t: Double, theta: Double)?, omega: Double) -> Double {
        guard let last = lastUpdate else { return output }
        if !started {
            reset(to: last.theta)
            lastUpdateTime = last.t
        }

        func lead(_ t: Double) -> Double { min(max(t - last.t, 0), Tuning.maxExtrapolation) }

        if lastUpdateTime != last.t {
            // 新的一次感測器更新：把當下的落差吸收成 offset，輸出才不會跳。
            offset = output - (last.theta + omega * lead(now))
            offsetTime = now
            lastUpdateTime = last.t
        }

        let decay = exp(-(now - offsetTime) / Tuning.smoothingTimeConstant)
        // 夾在物理範圍內：上蓋不會是負角度，也不會超過全開。
        output = min(max(last.theta + omega * lead(now) + offset * decay, 0), 180)
        return output
    }

    /// 目前輸出值，不推進時間。
    public var current: Double { output }
}
