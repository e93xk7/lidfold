import AppKit
import LidFoldCore

// M3 的 app：覆蓋窗 + 快照 + 3D 投影。還沒有模糊變暗（那是 M4）。
//
//   LidFold.app                 正常跑：闔蓋時顯示動畫
//   LidFold.app --demo          不碰上蓋，用假角度掃一遍（開發用）
//   LidFold.app --debug         覆蓋窗上顯示 θ / Δθ / 視距
//   LidFold.app --eye 45,30     眼睛在轉軸前方 45 cm、上方 30 cm（M3 調校用）

@MainActor
func start() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    delegate.demoMode = CommandLine.arguments.contains("--demo")
    delegate.debugText = CommandLine.arguments.contains("--debug")
    // --eye 前,高（公分，相對轉軸）
    if let i = CommandLine.arguments.firstIndex(of: "--eye"),
       i + 1 < CommandLine.arguments.count {
        let parts = CommandLine.arguments[i + 1].split(separator: ",").compactMap { Double($0) }
        if parts.count == 2 {
            delegate.eye = Projection.Eye(forward: parts[0], up: parts[1])
        }
    }
    app.delegate = delegate
    // 選單列 app（M5 才加 NSStatusItem），不進 Dock。
    app.setActivationPolicy(.accessory)
    // delegate 要活到程式結束。
    objc_setAssociatedObject(app, "lidfold.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}

MainActor.assumeIsolated { start() }
