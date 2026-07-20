import AppKit
import ApplicationServices
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem?

  // Sparkle 自動更新(feed 見 Info.plist SUFeedURL;發佈流程見 docs/RELEASE.md)
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    setupStatusBar()
    if OnboardingWindow.shouldShowOnLaunch {
      OnboardingWindow.open()
    }
    checkAccessibilityPermission()
  }

  // MARK: - Menu bar

  private func setupStatusBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem?.button {
      // 品牌 logo(template 模式,自動適應深淺選單列);找不到時退回 sparkles
      if let path = Bundle.main.path(forResource: "quill_logo", ofType: "svg"),
         let logo = NSImage(contentsOfFile: path) {
        logo.isTemplate = true
        logo.size = NSSize(width: 18, height: 18)
        button.image = logo
      } else {
        button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Quill")
      }
    }

    let menu = NSMenu()
    menu.addItem(NSMenuItem(
      title: "Preferences…",
      action: #selector(openPreferences),
      keyEquivalent: ","
    ))
    menu.addItem(NSMenuItem(
      title: "設定引導…",
      action: #selector(openOnboarding),
      keyEquivalent: ""
    ))
    menu.addItem(NSMenuItem(
      title: "檢查更新…",
      action: #selector(checkForUpdates),
      keyEquivalent: ""
    ))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(
      title: "Quit Quill",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    ))
    statusItem?.menu = menu
  }

  // MARK: - Actions

  @objc private func openPreferences() {
    PreferencesPanel.open()
  }

  @objc private func openOnboarding() {
    OnboardingWindow.open()
  }

  @objc private func checkForUpdates() {
    updaterController.checkForUpdates(nil)
  }

  // MARK: - Accessibility(權限引導交給 OnboardingWindow;這裡靜默輪詢,授權後啟動監聽)

  private func checkAccessibilityPermission() {
    if AXIsProcessTrusted() {
      NSLog("[Quill] AXIsProcessTrusted = true → 啟動快捷鍵監聽")
      startMonitoring()
      return
    }
    NSLog("[Quill] AXIsProcessTrusted = false,2 秒後重試(路徑:%@)", Bundle.main.bundlePath)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.checkAccessibilityPermission()
    }
  }

  // MARK: - Monitoring

  private var monitoringStarted = false

  func startMonitoring() {
    guard !monitoringStarted else { return }
    monitoringStarted = true
    ScreenshotCapture.shared.register()
    TextCapture.shared.register()
    NSLog("[Quill] 快捷鍵註冊完成:截圖 keyCode=%u mods=%u / 文字 keyCode=%u mods=%u",
          PromptStore.shared.screenshotKeyCode, PromptStore.shared.screenshotModifiers,
          PromptStore.shared.textKeyCode, PromptStore.shared.textModifiers)
  }
}
