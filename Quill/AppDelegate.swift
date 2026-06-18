import AppKit
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    setupStatusBar()
    checkAccessibilityPermission()
  }

  // MARK: - Menu bar

  private func setupStatusBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem?.button {
      button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Quill")
    }

    let menu = NSMenu()
    menu.addItem(NSMenuItem(
      title: "Preferences…",
      action: #selector(openPreferences),
      keyEquivalent: ","
    ))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(
      title: "Quit Quill",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    ))
    statusItem?.menu = menu
  }

  // MARK: - Accessibility

  private var accessibilityPrompted = false

  @objc private func openPreferences() {
    PreferencesPanel.open()
  }

  private func checkAccessibilityPermission() {
    if AXIsProcessTrusted() {
      startMonitoring()
      return
    }

    if !accessibilityPrompted {
      accessibilityPrompted = true
      showAccessibilityGuide()
    }

    // 靜默輪詢直到使用者開啟權限（alert 只顯示一次，之後靜默等待）
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.checkAccessibilityPermission()
    }
  }

  private func showAccessibilityGuide() {
    // 找到 app 所在路徑，方便使用者手動加入
    let appPath = Bundle.main.bundlePath

    let alert = NSAlert()
    alert.messageText = "Quill 需要 Accessibility 權限"
    alert.informativeText = """
      請手動加入一次（之後每次 build 都不用重加）：

      1. 點「開啟設定」→ 左下角「＋」
      2. 按 Cmd+Shift+G，貼入以下路徑：

      \(appPath)

      3. 選 Quill.app → 開啟開關
      """
    alert.addButton(withTitle: "開啟 Accessibility 設定")
    alert.addButton(withTitle: "稍後")

    // 把路徑複製到剪貼簿，方便貼上
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(appPath, forType: .string)

    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
      )
    }
  }

  // MARK: - Monitoring

  func startMonitoring() {
    ScreenshotCapture.shared.register()
    TextCapture.shared.register()
  }
}
