import AppKit
import ApplicationServices
import Combine
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate, SPUStandardUserDriverDelegate {
  var statusItem: NSStatusItem?

  private var localeObserver: AnyCancellable?
  private var updateMenuItem: NSMenuItem?
  private var hasScheduledUpdate = false
  private lazy var updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: self
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    _ = updaterController
    setupStatusBar()
    // 語言切換時重建選單列文字
    localeObserver = LocaleStore.shared.$language
      .dropFirst()
      .sink { [weak self] _ in DispatchQueue.main.async { self?.setupStatusBar() } }
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
      title: L10n.t("menu.preferences"),
      action: #selector(openPreferences),
      keyEquivalent: ","
    ))
    menu.addItem(NSMenuItem(
      title: L10n.t("menu.onboarding"),
      action: #selector(openOnboarding),
      keyEquivalent: ""
    ))
    let updateItem = NSMenuItem(
      title: hasScheduledUpdate ? L10n.t("menu.updateAvailable") : L10n.t("menu.checkUpdates"),
      action: #selector(checkForUpdates),
      keyEquivalent: ""
    )
    updateItem.target = self
    updateMenuItem = updateItem
    menu.addItem(updateItem)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(
      title: L10n.t("menu.quit"),
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
    hasScheduledUpdate = false
    updateMenuItem?.title = L10n.t("menu.checkUpdates")
    updaterController.checkForUpdates(nil)
  }

  // MARK: - Sparkle gentle reminders

  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    immediateFocus
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    guard !state.userInitiated, !handleShowingUpdate else { return }
    hasScheduledUpdate = true
    updateMenuItem?.title = L10n.t("menu.updateAvailable")
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    hasScheduledUpdate = false
    updateMenuItem?.title = L10n.t("menu.checkUpdates")
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
