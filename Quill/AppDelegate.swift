import AppKit
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem?

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
      button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Quill")
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

  // MARK: - Accessibility(權限引導交給 OnboardingWindow;這裡靜默輪詢,授權後啟動監聽)

  private func checkAccessibilityPermission() {
    if AXIsProcessTrusted() {
      startMonitoring()
      return
    }
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
  }
}
