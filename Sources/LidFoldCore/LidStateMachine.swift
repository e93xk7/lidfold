import Foundation

public enum LidState: String, CaseIterable {
    case idle = "靜止"
    case closing = "闔上中"
    case opening = "打開中"
    case closed = "已關"
}

public enum LidEvent: String {
    case didStartClosing   // → 拍快照、建覆蓋窗
    case didResumeClosing  // 停一下又繼續闔 → 沿用原本的快照與虛擬平面，不要重拍
    case didStopClosing    // 闔到一半停住 → 凍住畫面，等一下看會不會繼續
    case didClose          // 螢幕要關了 → 收掉覆蓋窗
    case didStartOpening   // → 收掉覆蓋窗
    case didOpen           // 回到正常角度
}

/// Signal 層 → 狀態機（白皮書 5.2）。
///
/// 與白皮書的兩點差異，都是 M1 數據逼出來的：
/// 1. 「持續 ≥ 2 個樣本」改成兩段式門檻 —— 感測器只有 10 Hz，等兩個樣本要 200 ms，
///    而快闔整段只有 760 ms。ω 夠大（≥ `omegaInstantTrigger`）就單次觸發。
/// 2. `thetaOpen` 用「動之前最後的靜止角度」，不是「進入闔上中那一刻的 θ」。
///    10 Hz 下後者已經掉了 8–16°，拿它當虛擬平面的位置，錯覺一開始就歪了。
public final class LidStateMachine {
    public private(set) var state: LidState = .idle
    /// 這次闔蓋的起始角度 = 動起來之前最後的靜止角度。
    public private(set) var thetaOpen: Double?

    /// 動之前的靜止角度，持續更新。
    private var restAngle: Double?
    private var closingVotes = 0
    private var openingVotes = 0
    private var stillSince: Double?
    /// 上一次從「闔上中」停下來的時間。短時間內又繼續闔，就當成同一次闔蓋。
    private var stoppedClosingAt: Double?

    public init() {}

    public func reset() {
        state = .idle
        thetaOpen = nil
        restAngle = nil
        closingVotes = 0
        openingVotes = 0
        stillSince = nil
    }

    /// 每次輪詢都呼叫。`isNewUpdate` 區分「感測器真的更新了」與「只是又輪詢一次」：
    /// 票數只在更新時算，但「停住了沒」「闔死了沒」每次都要看 —— 上蓋停住後
    /// 感測器不再變值，只靠更新驅動的話狀態機會卡住。
    @discardableResult
    public func step(theta: Double, omega: Double, now: Double,
                     isNewUpdate: Bool = true) -> [LidEvent] {
        var events: [LidEvent] = []

        // 票數：ω 夠大就一次到位，不夠大就要連續幾次。
        if isNewUpdate {
            if omega <= -Tuning.omegaDeadZone {
                closingVotes += omega <= -Tuning.omegaInstantTrigger ? Tuning.confirmUpdates : 1
                openingVotes = 0
            } else if omega >= Tuning.omegaDeadZone {
                openingVotes += omega >= Tuning.omegaInstantTrigger ? Tuning.confirmUpdates : 1
                closingVotes = 0
            } else {
                closingVotes = 0
                openingVotes = 0
            }
        }

        let moving = abs(omega) >= Tuning.omegaDeadZone
        if moving {
            stillSince = nil
        } else if stillSince == nil {
            stillSince = now
        }
        // 靜止時記住目前角度，下次開始闔的時候拿它當 θ_open。
        if !moving && state != .closed { restAngle = theta }

        let closedNow = theta <= Tuning.thetaOff

        switch state {
        case .idle, .opening:
            if closedNow && !moving {
                state = .closed
                events.append(.didClose)
            } else if closingVotes >= Tuning.confirmUpdates, !closedNow {
                // 已經闔死了就不要再「開始闔」—— 睡醒那一刻 θ 會從記憶中的
                // 開蓋角度瞬間變成 0，看起來像一次超快的闔蓋。沒東西好動畫。
                if state == .opening { events.append(.didOpen) }
                // 剛剛才停下來、而且上蓋沒有被往回打開 → 當成同一次闔蓋繼續，
                // 沿用原本的 θ_open。重設虛擬平面會讓畫面瞬間跳回去再重來。
                let resuming = stoppedClosingAt.map { now - $0 <= Tuning.resumeGrace } ?? false
                let didNotReopen = thetaOpen.map { theta <= $0 + Tuning.reopenTolerance } ?? false
                if resuming && didNotReopen && state == .idle {
                    state = .closing
                    events.append(.didResumeClosing)
                } else {
                    thetaOpen = restAngle ?? theta
                    state = .closing
                    events.append(.didStartClosing)
                }
            } else if state == .opening, let since = stillSince,
                      now - since >= Tuning.stillHoldTime {
                state = .idle
                events.append(.didOpen)
            } else if state == .idle, openingVotes >= Tuning.confirmUpdates {
                state = .opening
                events.append(.didStartOpening)
            }

        case .closing:
            if closedNow {
                state = .closed
                events.append(.didClose)
            } else if openingVotes >= Tuning.confirmUpdates {
                state = .opening
                events.append(.didStopClosing)
                events.append(.didStartOpening)
            } else if let since = stillSince, now - since >= Tuning.stillHoldTime {
                // 闔到一半停住：先凍住畫面。在 resumeGrace 之內又繼續闔的話，
                // 會以 didResumeClosing 接回來，虛擬平面不動。
                state = .idle
                stoppedClosingAt = now
                events.append(.didStopClosing)
            }

        case .closed:
            if !closedNow && openingVotes >= 1 {
                state = .opening
                restAngle = nil
                events.append(.didStartOpening)
            }
        }

        return events
    }
}
