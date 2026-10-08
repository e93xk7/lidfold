import AppKit
import LidFoldCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var sensor: LidSensor?
    private let signalChain = LidSignal()
    private let machine = LidStateMachine()
    private let predictor = AnglePredictor()
    private let overlay = OverlayController()

    private var pollTimer: Timer?
    private var capturing = false

    /// `--demo`：不碰上蓋，直接用假角度掃一遍，方便看渲染對不對。
    var demoMode = false
    /// `--debug`：覆蓋窗上顯示 θ / Δθ / 視距。
    var debugText = false
    /// `--eye 前,高`：眼睛位置（公分，相對轉軸）。
    var eye = Projection.Eye()
    /// `--strength k`：投影強度，1 = 物理精確。只有 projection 模式用得到。
    var strength = Tuning.projectionStrength
    /// `--mode gradient|projection`
    var mode: RenderMode = .gradient
    /// `--from sides|hinge|top`
    var sweepFrom: SweepOrigin = .sides

    private var demoTheta: Double?
    private var demoStart: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("啟動：模式 \(mode.rawValue)，模糊從 \(sweepFrom.rawValue) 掃")
        overlay.showDebugText = debugText
        overlay.eye = eye
        overlay.strength = strength
        overlay.mode = mode
        overlay.sweepFrom = sweepFrom
        overlay.angleProvider = { [weak self] in
            guard let self else { return 0 }
            if let d = self.demoTheta { return d }
            return self.predictor.angle(now: ProcessInfo.processInfo.systemUptime,
                                        lastUpdate: self.signalChain.lastUpdate,
                                        omega: self.lastOmega)
        }

        if !ScreenCapture.hasPermission() {
            Log.write("還沒有螢幕錄製權限，正在請求…")
            ScreenCapture.requestPermission()
        }
        // 闔蓋只有 0.8 秒，拍照的冷啟動要先付掉。
        Task { await ScreenCapture.prewarm() }

        do {
            sensor = try LidSensor()
        } catch {
            Log.write("感測器打不開 — \(error)")
            if !demoMode { NSApp.terminate(nil) }
        }

        if demoMode {
            startDemo()
        } else {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / Tuning.activePollHz,
                                             repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
    }

    // MARK: - 感測器

    private var lastOmega: Double = 0

    private func poll() {
        guard let sensor, let sample = try? sensor.read() else { return }
        let out = signalChain.ingest(sample)
        lastOmega = out.omega
        let events = machine.step(theta: out.theta, omega: out.omega,
                                  now: sample.timestamp, isNewUpdate: out.isNewUpdate)
        for e in events { handle(e) }
    }

    /// 停住之後的寬限計時器：在這段時間內又繼續闔，就沿用同一張快照。
    private var pauseTimer: Timer?

    private func handle(_ event: LidEvent) {
        Log.write(String(format: "%@（θ=%.1f°）", event.rawValue, predictor.current))
        switch event {
        case .didStartClosing:
            pauseTimer?.invalidate()
            pauseTimer = nil
            captureAndShow()

        case .didResumeClosing:
            // 同一次闔蓋，畫面繼續動就好，不重拍、不重設虛擬平面。
            pauseTimer?.invalidate()
            pauseTimer = nil
            if !overlay.isShowing { captureAndShow() }

        case .didStopClosing:
            // 先凍住（畫面停在那裡，內容仍然釘在原處），等看看會不會繼續。
            pauseTimer?.invalidate()
            pauseTimer = Timer.scheduledTimer(withTimeInterval: Tuning.resumeGrace,
                                              repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.write("停太久，收掉覆蓋窗")
                    self?.overlay.hide()
                }
            }

        case .didClose, .didStartOpening:
            pauseTimer?.invalidate()
            pauseTimer = nil
            overlay.hide()

        case .didOpen:
            break
        }
    }

    /// 白皮書 D4：進入「闔上中」的瞬間拍一張，整段動畫都用它。
    private func captureAndShow() {
        guard !capturing, let thetaOpen = machine.thetaOpen else { return }
        capturing = true
        let t0 = ProcessInfo.processInfo.systemUptime
        Log.write(String(format: "didStartClosing，θ_open=%.1f°，開始拍快照", thetaOpen))
        Task { @MainActor in
            defer { capturing = false }
            do {
                let image = try await ScreenCapture.captureBuiltIn()
                let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
                // 拍照是非同步的，拍回來時上蓋可能已經停了或打開了，那就不要顯示。
                guard machine.state == .closing else {
                    Log.write(String(format: "快照 %.0f ms 拍回來，但狀態已經是 %@，不顯示",
                                      ms, machine.state.rawValue))
                    return
                }
                overlay.show(snapshot: image, thetaOpen: thetaOpen)
                Log.write(String(format: "快照 %.0f ms，覆蓋窗已顯示", ms))
            } catch {
                Log.write("拍快照失敗 — \(error)")
            }
        }
    }

    // MARK: - Demo

    private func startDemo() {
        let thetaOpen = (try? sensor?.read())??.theta ?? 113
        demoTheta = thetaOpen
        demoStart = ProcessInfo.processInfo.systemUptime

        Task { @MainActor in
            do {
                let image = try await ScreenCapture.captureBuiltIn()
                overlay.show(snapshot: image, thetaOpen: thetaOpen)
            } catch {
                Log.write("拍快照失敗 — \(error)")
                NSApp.terminate(nil)
            }
        }

        // 2 秒內從 θ_open 掃到 30°，再停在那裡，方便截圖細看。
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let elapsed = ProcessInfo.processInfo.systemUptime - self.demoStart
                let p = min(elapsed / 2.0, 1.0)
                self.demoTheta = thetaOpen + (30 - thetaOpen) * p
                if elapsed > 8 { NSApp.terminate(nil) }
            }
        }
    }
}
