import Foundation

/// 開發期用的日誌。
///
/// 系統的 `log show` 會把 NSLog 的內容遮成 `<private>`，看不到自己印的東西，
/// 所以同時寫一份純文字到 `build/LidFold.log`，開發時直接 `tail -f` 就好。
enum Log {
    /// `~/Library/Logs/LidFold.log`。不要寫進 .app 裡 —— 那會破壞簽章，
    /// 簽章一變螢幕錄製權限就掉了。
    private static let url: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("LidFold.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        NSLog("LidFold：\(message)")
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
