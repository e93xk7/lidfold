import CoreGraphics
import Foundation
import LidFoldCore

// M0–M2 的命令列工具。
//
// 用法：
//   lidfold-cli                      即時顯示 θ、插值後的 θ、ω、狀態、p
//   lidfold-cli --csv data/x.csv     同上，另外把每一筆寫成 CSV（M1 錄製）
//   lidfold-cli --raw                加印兩個 HID report 的 hex（M0 除錯）
//   lidfold-cli --hz 120             自訂輪詢率（預設依狀態自動在 5–120 Hz 之間切）
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

var fixedIntervalMs: Int?
var showRaw = false
var csvPath: String?

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--interval-ms":
        guard let v = args.first.flatMap(Int.init), v > 0 else { fail("--interval-ms 需要正整數") }
        fixedIntervalMs = v
        args.removeFirst()
    case "--hz":
        guard let v = args.first.flatMap(Double.init), v > 0 else { fail("--hz 需要正數") }
        fixedIntervalMs = max(1, Int((1000.0 / v).rounded()))
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

// CSV：闔蓋時機器會睡著、行程被凍住，所以每一行都立刻寫進檔案，不進緩衝區。
var csv: FileHandle?
if let path = csvPath {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path, contents: nil),
          let out = FileHandle(forWritingAtPath: url.path) else {
        fail("寫不了檔案：\(url.path)")
    }
    out.write("t_mono,t_wall,raw,theta,theta_coarse,display_asleep\n".data(using: .utf8)!)
    csv = out
    FileHandle.standardError.write(
        "錄製中 → \(url.path)。先別碰上蓋停兩秒，再闔蓋；打開後按 Ctrl-C。\n".data(using: .utf8)!)
}

signal(SIGINT) { _ in print(""); exit(0) }
signal(SIGTERM) { _ in exit(0) }

let signalChain = LidSignal()
let machine = LidStateMachine()
let predictor = AnglePredictor()

let t0mono = ProcessInfo.processInfo.systemUptime
let t0wall = Date().timeIntervalSince1970
var lastPrint = 0.0
var lastMotion = t0mono

print("θ = 感測器讀值（10 Hz）｜θ̂ = 插值後（給 60 fps 用）｜ω = 角速度｜p = 動畫進度")

while true {
    let now = ProcessInfo.processInfo.systemUptime
    guard let sample = try? sensor.read() else {
        usleep(20000)
        continue
    }
    let out = signalChain.ingest(sample)
    let events = machine.step(theta: out.theta, omega: out.omega, now: sample.timestamp,
                              isNewUpdate: out.isNewUpdate)
    let theta = predictor.angle(now: sample.timestamp,
                                lastUpdate: signalChain.lastUpdate, omega: out.omega)
    let p = machine.thetaOpen.map { Mapping.progress(theta: theta, thetaOpen: $0) } ?? 0

    if let csv {
        let line = String(
            format: "%.4f,%.4f,%d,%.2f,%.0f,%d\n",
            sample.timestamp - t0mono, Date().timeIntervalSince1970 - t0wall,
            Int(sample.rawFine), sample.theta, sample.thetaCoarse,
            builtInDisplayAsleep() ? 1 : 0)
        csv.write(line.data(using: .utf8)!)
    }

    // 狀態轉移各自印一行，才不會被即時那行蓋掉。
    for e in events {
        print(String(format: "\r  t=%6.2f s  θ=%6.2f°  %@ → %@",
                     sample.timestamp - t0mono, out.theta, e.rawValue, machine.state.rawValue))
    }

    if abs(out.omega) >= Tuning.omegaDeadZone { lastMotion = now }

    if now - lastPrint > 0.05 {
        lastPrint = now
        var line = String(format: "\r  θ=%7.2f°  θ̂=%7.2f°  ω=%+7.1f °/s  %@  p=%.2f",
                          out.theta, theta, out.omega, machine.state.rawValue, p)
        if showRaw { line += "  " + sensor.rawReportHex() }
        FileHandle.standardError.write((line + "   ").data(using: .utf8)!)
    }

    // 輪詢率：靜止時 5 Hz 省電，動起來拉到 120 Hz（白皮書 5.1）。
    let interval: Int
    if let fixed = fixedIntervalMs {
        interval = fixed
    } else {
        let idle = now - lastMotion > Tuning.idleAfter
        interval = Int(1000.0 / (idle ? Tuning.idlePollHz : Tuning.activePollHz))
    }
    usleep(useconds_t(interval * 1000))
}
