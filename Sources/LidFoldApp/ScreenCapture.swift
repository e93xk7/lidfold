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

    /// 拍一張內建螢幕。macOS 14+ 用 ScreenCaptureKit。
    static func captureBuiltIn() async throws -> CGImage {
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
