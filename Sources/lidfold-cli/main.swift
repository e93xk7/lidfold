import Foundation
import LidFoldCore

// M0：每 50 ms 讀一次上蓋角度印出。
// 用法：lidfold-cli [--interval-ms 50] [--raw]
//   --raw  額外印出整段 feature report 的 hex（確認 report 格式用）

var intervalMs = 50
var showRaw = false
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--interval-ms":
        guard let v = args.first.flatMap(Int.init) else { fail("--interval-ms 需要整數") }
        intervalMs = v
        args.removeFirst()
    case "--raw":
        showRaw = true
    default:
        fail("不認得的參數：\(a)")
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

let sensor: LidSensor
do {
    sensor = try LidSensor()
} catch {
    fail("啟動失敗：\(error)")
}

signal(SIGINT) { _ in exit(0) }

print("# t[s]  raw  θ[°]" + (showRaw ? "  report" : ""))
let t0 = ProcessInfo.processInfo.systemUptime
while true {
    do {
        let s = try sensor.read()
        var line = String(format: "%8.3f  %5d  %7.2f", s.timestamp - t0, s.raw, s.theta)
        if showRaw { line += "  " + sensor.rawReportHex() }
        print(line)
    } catch {
        print("讀取失敗：\(error)")
    }
    fflush(stdout)
    usleep(useconds_t(intervalMs * 1000))
}
