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
    let resumes: Int              // didResumeClosing 次數（停一下又繼續，沿用原快照）
    let stops: Int                // didStopClosing 次數
    let mustClose: Bool           // 要不要出現 didClose
    /// didStartClosing 時，θ 最多可以比 θ_open 低幾度（越小代表反應越快）。
    let maxTriggerLag: Double
}

let expectations: [String: Expectation] = [
    "normal_1": Expectation(closes: 1, resumes: 0, stops: 0, mustClose: true, maxTriggerLag: 20),
    "normal_2": Expectation(closes: 1, resumes: 0, stops: 0, mustClose: true, maxTriggerLag: 20),
    "normal_3": Expectation(closes: 1, resumes: 0, stops: 0, mustClose: true, maxTriggerLag: 20),
    "slow":     Expectation(closes: 1, resumes: 0, stops: 0, mustClose: true, maxTriggerLag: 10),
    "fast":     Expectation(closes: 1, resumes: 0, stops: 0, mustClose: true, maxTriggerLag: 40),
    // 闔到一半停住再繼續：只拍一次快照，第二段用 didResumeClosing 接回來。
    // 重拍的話虛擬平面會重設，畫面會跳 —— M3 實測就是栽在這裡。
    "pause_resume": Expectation(closes: 1, resumes: 1, stops: 1, mustClose: true, maxTriggerLag: 25),
]

// MARK: - 主程式

/// 幾何自檢：虛擬平面上的一點，不管上蓋轉到哪個角度，
/// 投影到螢幕再反推回世界座標，都應該落在同一個位置。
/// 這是 M3 唯一能在「用眼睛看」之前驗的東西。
func checkGeometry() -> Bool {
    let thetaOpen = 113.0
    let pixelsPerCm = 1.0   // 用公分當單位，驗算不需要換成點
    let probe = (x: 0.0, y: 10.0)
    var reference: (x: Double, y: Double, z: Double)?
    var worst = 0.0

    print("── 幾何自檢（虛擬平面上的一點 (0, 10 cm)）")
    print("    θ      畫在螢幕上的位置      反推的世界座標")
    for theta in stride(from: thetaOpen, through: 30.0, by: -13.0) {
        // 視距被夾住之後幾何本來就不準了（眼睛快落在螢幕平面上，透視會發散）。
        // 那段交給 M4 的模糊變暗蓋掉，不列入檢查。
        guard Projection.isVisible(theta: theta, eye: Projection.Eye()) else {
            print(String(format: "  %5.1f°   視距已不足，幾何夾住（交給 M4 蓋掉）", theta))
            continue
        }
        // 自檢用強度 1：物理精確的那個版本才該零偏移。
        // 實際動畫用的強度小於 1（刻意的，見 Tuning.projectionStrength）。
        let m = Projection.transform(theta: theta, thetaOpen: thetaOpen,
                                     pixelsPerCm: pixelsPerCm, strength: 1.0)
        // 圖層上的點 (probe) 經過變換後落在螢幕的哪裡。
        let w = probe.x * m.m14 + probe.y * m.m24 + m.m44
        guard abs(w) > 1e-9 else { continue }
        let sx = (probe.x * m.m11 + probe.y * m.m21 + m.m41) / w
        let sy = (probe.x * m.m12 + probe.y * m.m22 + m.m42) / w

        guard let world = Projection.worldPointSeen(screenPoint: (sx, sy),
                                                    theta: theta, thetaOpen: thetaOpen) else {
            print(String(format: "  %5.1f°   (%6.2f, %6.2f)   看不到", theta, sx, sy))
            continue
        }
        if reference == nil { reference = world }
        let r = reference!
        let err = ((world.x - r.x) * (world.x - r.x) + (world.y - r.y) * (world.y - r.y)
                   + (world.z - r.z) * (world.z - r.z)).squareRoot()
        worst = max(worst, err)
        print(String(format: "  %5.1f°   (%6.2f, %6.2f)   (%6.2f, %6.2f, %6.2f)  偏移 %.4f cm",
                     theta, sx, sy, world.x, world.y, world.z, err))
    }
    // 錯覺能撐到幾度：視距掉到下限的那個角度。
    var limit = 0.0
    for theta in stride(from: thetaOpen, through: 0.0, by: -0.1)
    where Projection.isVisible(theta: theta, eye: Projection.Eye()) {
        limit = theta
    }

    let ok = worst < 0.01
    print(ok ? String(format: "✓ 幾何：可見範圍內最大偏移 %.5f cm", worst)
             : String(format: "✗ 幾何：最大偏移 %.3f cm，內容會跟著上蓋跑", worst))
    print(String(format: "  錯覺的角度窗口：%.0f° → %.0f°（再闔下去視距不足，M4 要在這裡接手）",
                 thetaOpen, limit))
    return ok
}

/// 漸進模糊的遮罩自檢：p=0 時整面清晰、p=1 時整面掃完、中間單調前進。
func checkSweep(span: Double = 1, label: String = "整面單向") -> Bool {
    let layers = 3   // 清晰 + 兩張模糊
    print("── 漸進模糊遮罩（\(layers) 層，\(label)，行程 \(span)）")
    print("    p     最清晰層        中層            最模糊層        （lo–hi：lo 以下藏起來）")
    var ok = true
    var previous: [Double] = []
    for step in 0...10 {
        let p = Double(step) / 10
        var cells: [String] = []
        var los: [Double] = []
        for i in 0..<layers {
            let m = Mapping.sweepMask(p: p, indexFromSharpest: i, layerCount: layers, span: span)
            cells.append(String(format: "%.2f–%.2f", m.lo, m.hi))
            los.append(m.lo)
        }
        print(String(format: "  %.1f   %@", p, cells.joined(separator: "    ")))

        // 遮罩只能往前掃，不能倒退。
        if !previous.isEmpty {
            for (a, b) in zip(previous, los) where b < a - 1e-9 {
                print("  ✗ p=\(p) 的遮罩比前一步退回去了")
                ok = false
            }
        }
        previous = los

        // 最清晰那層一定被掃得最多（最先糊掉）。
        if layers > 1, los[0] < los[layers - 1] - 1e-9 {
            print("  ✗ p=\(p)：最模糊的那層反而先被掃掉，層次順序錯了")
            ok = false
        }
    }
    let start = Mapping.sweepMask(p: 0, indexFromSharpest: 0, layerCount: layers, span: span)
    let end = Mapping.sweepMask(p: 1, indexFromSharpest: layers - 1, layerCount: layers, span: span)
    if start.lo > 1e-9 || start.hi > 1e-9 {
        print("  ✗ p=0 時最清晰層就已經被遮掉一部分（lo=\(start.lo) hi=\(start.hi)）")
        ok = false
    }
    if end.lo < span - 1e-9 {
        print("  ✗ p=1 時最模糊層還沒掃完（lo=\(end.lo)，應為 \(span)）")
        ok = false
    }
    print(ok ? "✓ 遮罩：起點乾淨、終點掃完、層次順序正確" : "✗ 遮罩有問題")
    return ok
}

var trace = false
var predictDir: String?
var paths: [String] = []
var pending = Array(CommandLine.arguments.dropFirst())
while !pending.isEmpty {
    let a = pending.removeFirst()
    if a == "--trace" {
        trace = true
    } else if a == "--geometry" {
        exit(checkGeometry() ? 0 : 1)
    } else if a == "--sweep" {
        let sides = checkSweep(span: 0.5, label: "側邊：兩側往中線")
        print("")
        let vertical = checkSweep(span: 1, label: "整面單向")
        exit(sides && vertical ? 0 : 1)
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
    let resumes = transitions.filter { $0.event == .didResumeClosing }
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
    if resumes.count != exp.resumes {
        problems.append("didResumeClosing \(resumes.count) 次，應為 \(exp.resumes)")
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
        print("✓ \(name)：闔 \(closes.count) 次、續 \(resumes.count) 次、停 \(stops.count) 次、"
              + "觸發落後 \(lagText)")
    } else {
        print("✗ \(name)：" + problems.joined(separator: "；"))
        failures += 1
    }
}

print(failures == 0 ? "\n全部通過" : "\n\(failures) 項沒過")
exit(failures == 0 ? 0 : 1)
