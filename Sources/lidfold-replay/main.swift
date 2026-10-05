import Foundation
import LidFoldCore

// M2 的測試：拿 M1 錄下的 CSV 回放進 Signal + 狀態機，檢查判斷對不對。
// 取代 XCTest（這台機器只有 Command Line Tools，沒有完整 Xcode）。
//
//   lidfold-replay data/takes/*.csv          跑預期檢查，全過回傳 0
//   lidfold-replay --trace data/takes/x.csv  印出每一次狀態轉移

struct Row {
    let t: Double
    let theta: Double
    let asleep: Bool
}

func loadCSV(_ path: String) throws -> [Row] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard !lines.isEmpty else { return [] }
    let header = lines.removeFirst().split(separator: ",").map(String.init)
    func col(_ name: String) -> Int? { header.firstIndex(of: name) }
    guard let iT = col("t_mono"), let iTheta = col("theta") else {
        throw NSError(domain: "replay", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "\(path)：缺 t_mono 或 theta 欄"])
    }
    let iSleep = col("display_asleep")
    return lines.compactMap { line in
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count > max(iT, iTheta), let t = Double(f[iT]), let th = Double(f[iTheta])
        else { return nil }
        let asleep = iSleep.flatMap { $0 < f.count ? Double(f[$0]) : nil } ?? 0
        return Row(t: t, theta: th, asleep: asleep != 0)
    }
}

struct Transition {
    let t: Double
    let theta: Double
    let event: LidEvent
    let state: LidState
}

/// 把 CSV 當成感測器讀數餵進去，回傳所有狀態轉移。
func replay(_ rows: [Row]) -> (transitions: [Transition], machine: LidStateMachine) {
    let signal = LidSignal()
    let machine = LidStateMachine()
    var transitions: [Transition] = []
    var lastRaw: UInt32 = .max

    for r in rows {
        // 回放時沒有原始 rawFine，用 0.01° 的整數值當「值有沒有變」的依據，
        // 跟真機上 report 7 的行為一致。
        let raw = UInt32((r.theta * 100).rounded())
        let sample = LidAngleSample(
            timestamp: r.t, theta: r.theta, thetaCoarse: r.theta.rounded(),
            rawFine: raw, rawCoarse: UInt16(min(max(r.theta.rounded(), 0), 360)))
        lastRaw = raw
        _ = lastRaw

        let out = signal.ingest(sample)
        for e in machine.step(theta: out.theta, omega: out.omega, now: r.t,
                              isNewUpdate: out.isNewUpdate) {
            transitions.append(Transition(t: r.t, theta: out.theta, event: e, state: machine.state))
        }
    }
    return (transitions, machine)
}

// MARK: - 預期

/// 一份錄音該長什麼樣。依檔名（去掉副檔名）對應。
struct Expectation {
    let closes: Int               // didStartClosing 次數
    let stops: Int                // didStopClosing 次數
    let mustClose: Bool           // 要不要出現 didClose
    /// didStartClosing 時，θ 最多可以比 θ_open 低幾度（越小代表反應越快）。
    let maxTriggerLag: Double
}

let expectations: [String: Expectation] = [
    "normal_1": Expectation(closes: 1, stops: 0, mustClose: true, maxTriggerLag: 20),
    "normal_2": Expectation(closes: 1, stops: 0, mustClose: true, maxTriggerLag: 20),
    "normal_3": Expectation(closes: 1, stops: 0, mustClose: true, maxTriggerLag: 20),
    "slow":     Expectation(closes: 1, stops: 0, mustClose: true, maxTriggerLag: 10),
    "fast":     Expectation(closes: 1, stops: 0, mustClose: true, maxTriggerLag: 40),
    // 闔到一半停住再繼續：停一次、所以會闔兩次。
    "pause_resume": Expectation(closes: 2, stops: 1, mustClose: true, maxTriggerLag: 25),
]

// MARK: - 主程式

var trace = false
var predictDir: String?
var paths: [String] = []
var pending = Array(CommandLine.arguments.dropFirst())
while !pending.isEmpty {
    let a = pending.removeFirst()
    if a == "--trace" {
        trace = true
    } else if a == "--predict" {
        predictDir = pending.isEmpty ? "data/predict" : pending.removeFirst()
    } else {
        paths.append(a)
    }
}

/// 把回放資料重跑一次，但以 60 fps 問插值器「現在該畫幾度」，
/// 輸出 t, θ_sensor（10 Hz 階梯）, θ_pred（插值後）給畫圖用。
func writePrediction(_ rows: [Row], name: String, dir: String) {
    let signal = LidSignal()
    let predictor = AnglePredictor()
    var lines = ["t,theta_sensor,theta_pred"]
    let frameInterval = 1.0 / 60.0
    var frame = rows[0].t
    var i = 0
    var latest = rows[0].theta
    var omega = 0.0

    while frame <= rows[rows.count - 1].t {
        // 餵完所有時間 ≤ 這一幀的感測器讀數。
        while i < rows.count && rows[i].t <= frame {
            let raw = UInt32((rows[i].theta * 100).rounded())
            let out = signal.ingest(LidAngleSample(
                timestamp: rows[i].t, theta: rows[i].theta, thetaCoarse: rows[i].theta.rounded(),
                rawFine: raw, rawCoarse: UInt16(min(max(rows[i].theta.rounded(), 0), 360))))
            latest = out.theta
            omega = out.omega
            i += 1
        }
        let pred = predictor.angle(now: frame, lastUpdate: signal.lastUpdate, omega: omega)
        lines.append(String(format: "%.4f,%.2f,%.2f", frame - rows[0].t, latest, pred))
        frame += frameInterval
    }

    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? lines.joined(separator: "\n").write(toFile: "\(dir)/\(name).csv",
                                             atomically: true, encoding: .utf8)
    print("  插值輸出 → \(dir)/\(name).csv")
}
guard !paths.isEmpty else {
    print("用法：lidfold-replay [--trace] <csv…>")
    exit(2)
}

var failures = 0
for path in paths {
    let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".csv", with: "")
    guard let rows = try? loadCSV(path), rows.count > 10 else {
        print("✗ \(name)：讀不到資料")
        failures += 1
        continue
    }
    if let dir = predictDir { writePrediction(rows, name: name, dir: dir) }

    let (transitions, _) = replay(rows)
    let closes = transitions.filter { $0.event == .didStartClosing }
    let stops = transitions.filter { $0.event == .didStopClosing }
    let closed = transitions.contains { $0.event == .didClose }

    if trace {
        print("── \(name)")
        for tr in transitions {
            print(String(format: "   t=%6.2f  θ=%6.2f°  %@ → %@",
                         tr.t - rows[0].t, tr.theta, tr.event.rawValue, tr.state.rawValue))
        }
    }

    guard let exp = expectations[name] else {
        print("· \(name)：沒有預期值，只回放（闔 \(closes.count) 次、停 \(stops.count) 次、"
              + "\(closed ? "有" : "沒") didClose）")
        continue
    }

    var problems: [String] = []
    if closes.count != exp.closes {
        problems.append("didStartClosing \(closes.count) 次，應為 \(exp.closes)")
    }
    if stops.count != exp.stops {
        problems.append("didStopClosing \(stops.count) 次，應為 \(exp.stops)")
    }
    if exp.mustClose && !closed { problems.append("沒有 didClose") }

    // 觸發有多快：θ_open 掉了多少度才判定在闔。
    var lagText = "—"
    if let first = closes.first {
        let thetaOpen = rows.first(where: { $0.t >= first.t })
            .map { _ in first.theta } ?? first.theta
        let restAngle = rows.prefix(while: { $0.t < first.t }).map(\.theta).max() ?? thetaOpen
        let lag = restAngle - first.theta
        lagText = String(format: "%.1f°", lag)
        if lag > exp.maxTriggerLag {
            problems.append(String(format: "觸發太慢：掉了 %.1f°（上限 %.0f°）", lag, exp.maxTriggerLag))
        }
    }

    if problems.isEmpty {
        print("✓ \(name)：闔 \(closes.count) 次、停 \(stops.count) 次、觸發落後 \(lagText)")
    } else {
        print("✗ \(name)：" + problems.joined(separator: "；"))
        failures += 1
    }
}

print(failures == 0 ? "\n全部通過" : "\n\(failures) 項沒過")
exit(failures == 0 ? 0 : 1)
