import AppKit
import LidFoldCore
import ServiceManagement

/// App 層（白皮書 5.6）：選單列常駐。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let angleItem = NSMenuItem(title: "角度 —", action: nil, keyEquivalent: "")
    private let enableItem = NSMenuItem(title: "啟用動畫", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "開機時啟動", action: nil, keyEquivalent: "")

    /// 動畫開著還是關著。
    private(set) var isEnabled = true

    var onToggleEnabled: ((Bool) -> Void)?
    var onShowDebugWindow: (() -> Void)?

    /// 選單是不是正開著。沒開就不用更新角度 —— 沒人在看的時候不做白工。
    private var menuIsOpen = false

    override init() {
        super.init()
        if let button = item.button {
            // 上蓋的側影：一條底線加一道斜線。
            button.image = NSImage(systemSymbolName: "laptopcomputer",
                                   accessibilityDescription: "LidFold")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        angleItem.isEnabled = false
        menu.addItem(angleItem)
        menu.addItem(.separator())

        enableItem.target = self
        enableItem.action = #selector(toggleEnabled)
        enableItem.state = .on
        menu.addItem(enableItem)

        loginItem.target = self
        loginItem.action = #selector(toggleLoginItem)
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let debugItem = NSMenuItem(title: "除錯視窗…", action: #selector(showDebug),
                                   keyEquivalent: "d")
        debugItem.target = self
        menu.addItem(debugItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "結束 LidFold", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        item.menu = menu
        refreshLoginItemState()
    }

    /// 選單打開時才更新角度 —— 沒人在看的時候不要做白工。
    func updateAngle(_ theta: Double, state: LidState) {
        guard menuIsOpen else { return }
        angleItem.title = String(format: "角度 %.1f°　%@", theta, state.rawValue)
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        enableItem.state = isEnabled ? .on : .off
        item.button?.appearsDisabled = !isEnabled
        onToggleEnabled?(isEnabled)
    }

    @objc private func showDebug() {
        onShowDebugWindow?()
    }

    // MARK: - 開機啟動

    private func refreshLoginItemState() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                Log.write("已取消開機啟動")
            } else {
                try SMAppService.mainApp.register()
                Log.write("已設定開機啟動")
            }
        } catch {
            Log.write("開機啟動設定失敗 — \(error)")
            let alert = NSAlert()
            alert.messageText = "設定開機啟動失敗"
            alert.informativeText = "\(error.localizedDescription)\n\n"
                + "這個 app 是本機自簽的，macOS 可能會擋。"
                + "可以改用「系統設定 → 一般 → 登入項目」手動加。"
            alert.runModal()
        }
        refreshLoginItemState()
    }
}
