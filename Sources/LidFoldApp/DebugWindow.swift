import AppKit
import LidFoldCore

/// 除錯視窗（白皮書 5.6）：即時 θ、ω、狀態、p，M4 之後調參數都靠它。
///
/// 只有視窗開著的時候才更新，關掉就完全不做事 —— 閒置耗電是 M5 的過關條件。
@MainActor
final class DebugWindow {

    private var window: NSWindow?
    private let text = NSTextField(labelWithString: "")

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 180),
                         styleMask: [.titled, .closable, .utilityWindow],
                         backing: .buffered, defer: false)
        w.title = "LidFold 除錯"
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.center()

        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.maximumNumberOfLines = 0

        let container = NSView()
        container.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
        ])
        w.contentView = container
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(theta: Double, predicted: Double, omega: Double,
                state: LidState, thetaOpen: Double?, overlayShowing: Bool) {
        guard isVisible else { return }
        let p = thetaOpen.map { Mapping.progress(theta: predicted, thetaOpen: $0) } ?? 0
        text.stringValue = String(
            format: """
                θ（感測器）  %7.2f°
                θ（插值後）  %7.2f°
                ω            %+7.1f °/s
                狀態         %@
                θ_open       %@
                p            %.3f
                變暗         %.2f
                覆蓋窗       %@
                """,
            theta, predicted, omega, state.rawValue,
            thetaOpen.map { String(format: "%.1f°", $0) } ?? "—",
            p, Mapping.dim(p: p), overlayShowing ? "顯示中" : "沒有")
    }
}
