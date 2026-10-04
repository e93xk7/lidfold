import CoreGraphics
import Foundation
import LidFoldCore

// M0–M2 的命令列工具。
//
// 用法：
//   lidfold-cli                              每 50 ms 印一次角度（M0）
//   lidfold-cli --raw                        額外印出整段 feature report 的 hex
//   lidfold-cli --csv data/close_normal_1.csv  錄 CSV（M1），預設 200 Hz
//   lidfold-cli --csv <path> --hz 100        自訂取樣率
//
// CSV 欄位：t_mono,t_wall,raw,theta,theta_coarse,display_asleep
//   t_mono          單調時鐘秒數，睡眠期間不前進 → 用來算 dθ/dt
//   t_wall          牆上時鐘秒數，睡眠期間照走 → 用來看睡了多久
//   raw             report 7 的原始整數（單位 0.01°）
//   theta           角度（度），解析度 0.01°
//   theta_coarse    角度（度），解析度 1°，report 1 的值，對照用
//   display_asleep  0/1，內建螢幕是否已關 → 螢幕變黑那一刻的 θ 就是 θ_off

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

var intervalMs = 50
var showRaw = false
var csvPath: String?
var hzGiven = false

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--interval-ms":
        guard let v = args.first.flatMap(Int.init), v > 0 else { fail("--interval-ms 需要正整數") }
        intervalMs = v
        args.removeFirst()
    case "--hz":
        guard let v = args.first.flatMap(Double.init), v > 0 else { fail("--hz 需要正數") }
        intervalMs = max(1, Int((1000.0 / v).rounded()))
        hzGiven = true
        args.removeFirst()
    case "--csv":
        guard let v = args.first, !v.hasPrefix("--") else { fail("--csv 需要檔案路徑") }
        csvPath = v
        args.removeFirst()
    case "--raw":
        showRaw = true
    default:
        fail("不認得的參數：\(a)")
    }
}
// 錄 CSV 時預設 200 Hz：要先量到感測器自己的更新率，得比它快。
if csvPath != nil && !hzGiven { intervalMs = 5 }

let sensor: LidSensor
do {
    sensor = try LidSensor()
} catch {
    fail("啟動失敗：\(error)")
}

/// 內建螢幕是否已關。θ_off 就是這個從 0 翻成 1 那一刻的 θ。
func builtInDisplayAsleep() -> Bool {
    CGDisplayIsAsleep(CGMainDisplayID()) != 0
}

let t0mono = ProcessInfo.processInfo.systemUptime
let t0wall = Date().timeIntervalSince1970

if let path = csvPath {
    // ── M1：錄 CSV ─────────────────────────────────────────────
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path, contents: nil),
          let out = FileHandle(forWritingAtPath: url.path) else {
        fail("寫不了檔案：\(url.path)")
    }
    out.write("t_mono,t_wall,raw,theta,theta_coarse,display_asleep\n".data(using: .utf8)!)

    // 闔蓋時機器會睡著、行程被凍住，所以每一行都立刻寫進檔案，不進緩衝區。
    let handle = out
    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in exit(0) }
    }

    FileHandle.standardError.write(
        "錄製中 → \(url.path)（\(1000 / intervalMs) Hz）。闔蓋、等螢幕黑、再打開，然後按 Ctrl-C。\n"
            .data(using: .utf8)!)

    var lastPrint = 0.0
    while true {
        if let s = try? sensor.read() {
            let tMono = s.timestamp - t0mono
            let tWall = Date().timeIntervalSince1970 - t0wall
            let asleep = builtInDisplayAsleep() ? 1 : 0
            let line = String(
                format: "%.4f,%.4f,%d,%.2f,%.0f,%d\n",
                tMono, tWall, Int(s.rawFine), s.theta, s.thetaCoarse, asleep)
            handle.write(line.data(using: .utf8)!)

            if tMono - lastPrint > 0.1 {
                lastPrint = tMono
                let status = asleep == 1 ? "螢幕已關" : "螢幕亮著"
                FileHandle.standardError.write(
                    String(format: "\r  t=%6.2f s   θ=%6.2f°   %@   ", tMono, s.theta, status)
                        .data(using: .utf8)!)
            }
        }
        usleep(useconds_t(intervalMs * 1000))
    }
} else {
    // ── M0：印到螢幕 ───────────────────────────────────────────
    signal(SIGINT) { _ in exit(0) }
    print("# t[s]  raw  θ[°]" + (showRaw ? "  report" : ""))
    while true {
        do {
            let s = try sensor.read()
            var line = String(
                format: "%8.3f  %6d  %7.2f", s.timestamp - t0mono, Int(s.rawFine), s.theta)
            if showRaw { line += "  " + sensor.rawReportHex() }
            print(line)
        } catch {
            print("讀取失敗：\(error)")
        }
        fflush(stdout)
        usleep(useconds_t(intervalMs * 1000))
    }
}
