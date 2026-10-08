import AppKit
import LidFoldCore
import QuartzCore

/// 動畫的做法。
enum RenderMode: String {
    /// 以轉軸為起點的漸進模糊／變暗／淡出。內容一個像素都不動。
    case gradient
    /// 把內容釘在空間裡的透視投影。幾何正確，但畫面會被放大 ——
    /// M3 實測看起來像「螢幕被拉長」，所以不是預設。留著對照用。
    case projection
}

/// 模糊前緣從哪裡開始掃。
enum SweepOrigin: String {
    /// **側邊模糊**：從左右兩側同時往中線吃，中間最後才糊。
    /// iPhone Duo 沿垂直軸對折，模糊就是這樣橫向擴散的。
    case sides
    /// 從轉軸（螢幕下緣）開始往上掃。
    case hinge
    /// 從上緣開始往下掃。
    case top

    /// 前緣要走多遠：兩側往中線只要走半個螢幕，單向掃要走整面。
    var span: Double { self == .sides ? 0.5 : 1 }
}

/// Render 層（白皮書 5.4）：蓋滿內建螢幕的覆蓋窗。
///
/// 平常這個窗**不存在**，只在 `didStartClosing` 時建立、`didClose` 或
/// `didStartOpening` 時銷毀，閒置零成本。
@MainActor
final class OverlayController {

    private var window: NSWindow?
    private var pyramid: BlurPyramid?
    /// 由最模糊到最清晰疊起來。index 0 在最下面（最模糊）。
    private var imageLayers: [CALayer] = []
    /// 每一層自己的漸層遮罩，決定它在螢幕的哪一段露出來。
    private var masks: [CAGradientLayer] = []
    private var dimLayer: CALayer?
    private var displayLink: CADisplayLink?
    /// 安全網：覆蓋窗蓋滿整個螢幕，絕對不能卡住不收。
    private var watchdog: Timer?
    private var debugLayer: CATextLayer?

    /// 這次闔蓋的起始角度。
    private var thetaOpen: Double = 0
    private var pixelsPerCm: Double = 1
    private var bezelPixels: Double = 0

    /// 每一幀要畫的角度從哪裡來（插值器）。
    var angleProvider: () -> Double = { 0 }
    /// 顯示 θ / p / 模式。
    var showDebugText = false
    var mode: RenderMode = .gradient
    var sweepFrom: SweepOrigin = .sides
    /// 眼睛位置（公分，相對轉軸）。只有 projection 模式用得到。
    var eye = Projection.Eye()
    /// 投影強度，1 = 物理精確。只有 projection 模式用得到。
    var strength = Tuning.projectionStrength

    var isShowing: Bool { window != nil }

    // MARK: - 建立與銷毀

    func show(snapshot: CGImage, thetaOpen: Double) {
        hide()
        guard let screen = builtInScreen() else { return }
        self.thetaOpen = thetaOpen

        // 螢幕的實體尺寸 → 每公分幾個點（projection 模式要用）。
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
        // 內容淡掉之後露出來的要是黑的 —— 露出真正的桌面會立刻拆穿。
        w.backgroundColor = .black
        w.hasShadow = false

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        w.contentView = view

        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        imageLayers = []
        masks = []

        // 先只放清晰那層：模糊要算幾十毫秒，不能擋住動畫開頭。
        appendImageLayer(snapshot, bounds: bounds, scale: screen.backingScaleFactor, into: view)

        let pyramid = BlurPyramid(sharp: snapshot)
        self.pyramid = pyramid
        pyramid.computeBlurs(scale: Double(screen.backingScaleFactor)) { [weak self, weak view, weak w] blurs in
            guard let self, let view, let w, self.window === w else { return }
            // 最模糊的要在最底下，所以由淺到深依序插到最下面。
            for image in blurs {
                self.insertImageLayer(image, bounds: bounds,
                                      scale: screen.backingScaleFactor, into: view, at: 0)
            }
        }

        // 整體變暗：疊一層黑的，透明度由 p 控制。
        let dim = CALayer()
        dim.frame = bounds
        dim.backgroundColor = NSColor.black.cgColor
        dim.opacity = 0
        view.layer?.addSublayer(dim)
        dimLayer = dim

        if showDebugText {
            let t = CATextLayer()
            t.frame = CGRect(x: 20, y: screen.frame.height - 80, width: 900, height: 60)
            t.fontSize = 24
            t.foregroundColor = NSColor.systemGreen.cgColor
            t.contentsScale = screen.backingScaleFactor
            view.layer?.addSublayer(t)
            debugLayer = t
        }

        window = w
        w.orderFrontRegardless()

        apply(theta: angleProvider())
        startDisplayLink(on: view)

        watchdog = Timer.scheduledTimer(withTimeInterval: Tuning.maxOverlaySeconds,
                                        repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.write("覆蓋窗超過 \(Tuning.maxOverlaySeconds) 秒還沒收，強制關掉")
                self?.hide()
            }
        }
    }

    private func appendImageLayer(_ image: CGImage, bounds: CGRect,
                                  scale: CGFloat, into view: NSView) {
        insertImageLayer(image, bounds: bounds, scale: scale, into: view, at: nil)
    }

    private func insertImageLayer(_ image: CGImage, bounds: CGRect, scale: CGFloat,
                                  into view: NSView, at index: UInt32?) {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.bounds = bounds
        // 轉軸在螢幕下緣中點（projection 模式要繞它轉）。
        layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer.position = CGPoint(x: bounds.width / 2, y: 0)
        layer.contentsScale = scale
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear

        let mask = CAGradientLayer()
        mask.frame = bounds
        // 遮罩看的是 alpha：透明處藏起來，不透明處露出來。
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = mask

        if let index {
            view.layer?.insertSublayer(layer, at: index)
            imageLayers.insert(layer, at: Int(index))
            masks.insert(mask, at: Int(index))
        } else {
            view.layer?.addSublayer(layer)
            imageLayers.append(layer)
            masks.append(mask)
        }
    }

    func hide() {
        watchdog?.invalidate()
        watchdog = nil
        displayLink?.invalidate()
        displayLink = nil
        debugLayer = nil
        dimLayer = nil
        imageLayers = []
        masks = []
        pyramid = nil
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
        guard !imageLayers.isEmpty else { return }
        let p = Mapping.progress(theta: theta, thetaOpen: thetaOpen)

        // 每一幀都是我們自己算的，關掉 Core Animation 的隱式補間。
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        switch mode {
        case .gradient: applyGradient(p: p)
        case .projection: applyProjection(theta: theta)
        }
        dimLayer?.opacity = Float(Mapping.dim(p: p))

        if let d = debugLayer {
            d.string = String(format: "θ=%.1f°  Δθ=%.1f°  p=%.2f   %@／%@",
                              theta, thetaOpen - theta, p, mode.rawValue, sweepFrom.rawValue)
        }
        CATransaction.commit()
    }

    /// 漸進模糊：模糊前緣隨 p 推進，內容本身一動也不動。
    ///
    /// 圖層由下往上是「最模糊 → 次模糊 → 清晰」，每層的遮罩前緣錯開一段，
    /// 所以同一瞬間螢幕上同時存在清晰／半糊／全糊三段，中間平滑接起來。
    ///
    /// 預設 `sides`：從左右兩側同時往中線吃 —— Duo 沿垂直軸對折，
    /// 模糊就是這樣橫向擴散的。
    private func applyGradient(p: Double) {
        let count = masks.count
        guard count > 0 else { return }
        let clear = NSColor.clear.cgColor
        let solid = NSColor.black.cgColor

        for (i, mask) in masks.enumerated() {
            // i = 0 是最模糊那層（最下面），最晚被前緣掃到。
            let edges = Mapping.sweepMask(p: p, indexFromSharpest: count - 1 - i,
                                          layerCount: count, span: sweepFrom.span)
            let lo = edges.lo
            let hi = edges.hi

            switch sweepFrom {
            case .sides:
                // 左右對稱：兩端透明（已糊掉），中間一條還清晰。
                // 四個色標讓同一個 CAGradientLayer 做出對稱的帶狀遮罩。
                mask.startPoint = CGPoint(x: 0, y: 0.5)
                mask.endPoint = CGPoint(x: 1, y: 0.5)
                mask.colors = [clear, solid, solid, clear]
                mask.locations = [NSNumber(value: lo), NSNumber(value: hi),
                                  NSNumber(value: 1 - hi), NSNumber(value: 1 - lo)]
            case .hinge, .top:
                // 單向掃：hinge 由下往上，top 反過來。
                mask.startPoint = sweepFrom == .hinge ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0.5, y: 1)
                mask.endPoint = sweepFrom == .hinge ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 0.5, y: 0)
                mask.colors = [clear, solid]
                mask.locations = [NSNumber(value: lo), NSNumber(value: hi)]
            }
        }

        // gradient 模式完全不動幾何 —— 不縮放、不位移、不旋轉。
        for layer in imageLayers where !CATransform3DIsIdentity(layer.transform) {
            layer.transform = CATransform3DIdentity
        }
    }

    /// 舊的透視投影，留著對照用（`--mode projection`）。
    private func applyProjection(theta: Double) {
        let m = Projection.transform(theta: theta, thetaOpen: thetaOpen,
                                     pixelsPerCm: pixelsPerCm, bezelPixels: bezelPixels,
                                     eye: eye, strength: strength)
        for layer in imageLayers {
            layer.transform = m
            layer.mask = nil
        }
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
