import AppKit
import LidFoldCore
import QuartzCore

/// Render 層（白皮書 5.4）：蓋滿內建螢幕的覆蓋窗，裡面一張快照做 3D 透視投影。
///
/// 平常這個窗**不存在**，只在 `didStartClosing` 時建立、`didClose` 或
/// `didStartOpening` 時銷毀，閒置零成本。
@MainActor
final class OverlayController {

    private var window: NSWindow?
    private var imageLayer: CALayer?
    private var displayLink: CADisplayLink?
    /// 安全網：覆蓋窗蓋滿整個螢幕，絕對不能卡住不收。
    private var watchdog: Timer?

    /// 這次闔蓋的起始角度，也就是虛擬平面的位置。
    private var thetaOpen: Double = 0
    /// 每公分幾個點。
    private var pixelsPerCm: Double = 1
    private var bezelPixels: Double = 0

    /// 每一幀要畫的角度從哪裡來（插值器）。
    var angleProvider: () -> Double = { 0 }
    /// M3 的除錯開關：顯示角度與視距。
    var showDebugText = false

    private var debugLayer: CATextLayer?

    var isShowing: Bool { window != nil }

    // MARK: - 建立與銷毀

    func show(snapshot: CGImage, thetaOpen: Double) {
        hide()
        guard let screen = builtInScreen() else { return }
        self.thetaOpen = thetaOpen

        // 螢幕的實體尺寸 → 每公分幾個點。投影的所有長度都靠這個換算。
        let displayID = screen.displayID ?? CGMainDisplayID()
        let sizeMM = CGDisplayScreenSize(displayID)
        let heightCm = Double(sizeMM.height) / 10.0
        pixelsPerCm = heightCm > 1 ? Double(screen.frame.height) / heightCm : 40
        bezelPixels = Tuning.bezelBottomCm * pixelsPerCm

        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.isOpaque = true
        // 內容轉出螢幕之後露出來的區域要是黑的 —— 露出真正的桌面會立刻拆穿錯覺。
        w.backgroundColor = .black
        w.hasShadow = false

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        w.contentView = view

        let layer = CALayer()
        layer.contents = snapshot
        layer.contentsGravity = .resize
        layer.bounds = CGRect(origin: .zero, size: screen.frame.size)
        // 轉軸在螢幕下緣中點。
        layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer.position = CGPoint(x: screen.frame.width / 2, y: 0)
        layer.contentsScale = screen.backingScaleFactor
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        layer.isOpaque = true
        view.layer?.addSublayer(layer)

        if showDebugText {
            let t = CATextLayer()
            t.frame = CGRect(x: 20, y: screen.frame.height - 80, width: 600, height: 60)
            t.fontSize = 28
            t.foregroundColor = NSColor.systemGreen.cgColor
            t.contentsScale = screen.backingScaleFactor
            view.layer?.addSublayer(t)
            debugLayer = t
        }

        window = w
        imageLayer = layer
        w.orderFrontRegardless()

        apply(theta: angleProvider())
        startDisplayLink(on: view)

        watchdog = Timer.scheduledTimer(withTimeInterval: Tuning.maxOverlaySeconds,
                                        repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                NSLog("LidFold：覆蓋窗超過 \(Tuning.maxOverlaySeconds) 秒還沒收，強制關掉")
                self?.hide()
            }
        }
    }

    func hide() {
        watchdog?.invalidate()
        watchdog = nil
        displayLink?.invalidate()
        displayLink = nil
        debugLayer = nil
        imageLayer = nil
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - 每一幀

    private func startDisplayLink(on view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        apply(theta: angleProvider())
    }

    private func apply(theta: Double) {
        guard let layer = imageLayer else { return }
        let m = Projection.transform(theta: theta, thetaOpen: thetaOpen,
                                     pixelsPerCm: pixelsPerCm, bezelPixels: bezelPixels)
        // 關掉隱式動畫：每一幀都是我們自己算的，交給 Core Animation 補間會變成雙重動畫。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = m
        if let d = debugLayer {
            let e = Projection.eyeInScreenFrame(theta: theta, eye: Projection.Eye())
            d.string = String(format: "θ=%.1f°  Δθ=%.1f°  視距=%.1f cm%@",
                              theta, thetaOpen - theta, e.outward,
                              Projection.isVisible(theta: theta, eye: Projection.Eye())
                                ? "" : "（已夾住）")
        }
        CATransaction.commit()
    }

    // MARK: - 螢幕

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { $0.displayID == CGMainDisplayID() } ?? NSScreen.main
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
