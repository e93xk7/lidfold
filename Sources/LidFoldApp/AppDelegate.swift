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

    private var demoTheta: Double?
    private var demoStart: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay.showDebugText = debugText
        overlay.angleProvider = { [weak self] in
            guard let self else { return 0 }
            if let d = self.demoTheta { return d }
            return self.predictor.angle(now: ProcessInfo.processInfo.systemUptime,
                                        lastUpdate: self.signalChain.lastUpdate,
                                        omega: self.lastOmega)
        }

        if !ScreenCapture.hasPermission() {
            NSLog("LidFold：還沒有螢幕錄製權限，正在請求…")
            ScreenCapture.requestPermission()
        }

        do {
            sensor = try LidSensor()
        } catch {
            NSLog("LidFold：感測器打不開 — \(error)")
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

    private func handle(_ event: LidEvent) {
        switch event {
        case .didStartClosing:
            captureAndShow()
        case .didClose, .didStartOpening, .didStopClosing:
            overlay.hide()
        case .didOpen:
            break
        }
    }

    /// 白皮書 D4：進入「闔上中」的瞬間拍一張，整段動畫都用它。
    private func captureAndShow() {
        guard !capturing, let thetaOpen = machine.thetaOpen else { return }
        capturing = true
        Task { @MainActor in
            defer { capturing = false }
            do {
                let image = try await ScreenCapture.captureBuiltIn()
                // 拍照是非同步的，拍回來時上蓋可能已經停了或打開了，那就不要顯示。
                guard machine.state == .closing else { return }
                overlay.show(snapshot: image, thetaOpen: thetaOpen)
            } catch {
                NSLog("LidFold：拍快照失敗 — \(error)")
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
                NSLog("LidFold：拍快照失敗 — \(error)")
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
