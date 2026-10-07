import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Capture 層（白皮書 5.5）：拍內建螢幕當下的畫面。
enum ScreenCapture {

    enum CaptureError: Error, CustomStringConvertible {
        case noDisplay
        case denied

        var description: String {
            switch self {
            case .noDisplay: return "找不到內建螢幕"
            case .denied: return "沒有螢幕錄製權限（系統設定 → 隱私權與安全性 → 螢幕錄製）"
            }
        }
    }

    /// 先解析好的內建螢幕濾鏡與設定。
    ///
    /// 第一次呼叫 `SCShareableContent` 要叫醒 replayd，實測會花掉快一秒 ——
    /// 而整段闔蓋只有 0.8–2.7 秒，等它回來螢幕已經關了（M3 第一次實測就是死在這裡）。
    /// 所以開 app 時就先把這些準備好，闔蓋當下只剩真正拍照那一步。
    private static var warmFilter: SCContentFilter?
    private static var warmConfig: SCStreamConfiguration?

    /// 開 app 時呼叫一次。順便把整條路徑跑熱（含一張丟掉不用的快照）。
    static func prewarm() async {
        do {
            let (filter, config) = try await resolveBuiltIn()
            warmFilter = filter
            warmConfig = config
            // 真的拍一張丟掉：第一次拍照本身也有冷啟動成本。
            let t0 = ProcessInfo.processInfo.systemUptime
            _ = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            Log.write(String(format: "Capture 預熱完成，第一張 %.0f ms",
                              (ProcessInfo.processInfo.systemUptime - t0) * 1000))
        } catch {
            Log.write("Capture 預熱失敗 — \(error)")
        }
    }

    private static func resolveBuiltIn() async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // 用實際像素數，拍到 Retina 解析度。
        config.width = display.width * 2
        config.height = display.height * 2
        config.showsCursor = false
        return (filter, config)
    }

    /// 拍一張內建螢幕。macOS 14+ 用 ScreenCaptureKit。
    static func captureBuiltIn() async throws -> CGImage {
        let filter: SCContentFilter
        let config: SCStreamConfiguration
        if let f = warmFilter, let c = warmConfig {
            (filter, config) = (f, c)
        } else {
            (filter, config) = try await resolveBuiltIn()
            warmFilter = filter
            warmConfig = config
        }
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
    }

    /// 權限還沒給的時候，ScreenCaptureKit 會丟錯。先問一次好給出清楚的指引。
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }
}
