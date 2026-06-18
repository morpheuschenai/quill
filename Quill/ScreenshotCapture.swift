import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Panel subclass (needs to be key window for text field)

private class ScreenshotPromptNSPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

// MARK: - Screenshot coordinator

class ScreenshotCapture {
  static let shared = ScreenshotCapture()

  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private var promptPanel: ScreenshotPromptNSPanel?
  private var globalClickMonitor: Any?

  // MARK: - Hotkey registration

  func register() {
    var eventSpec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    InstallEventHandler(
      GetApplicationEventTarget(),
      { callRef, event, _ -> OSStatus in
        var hkID = EventHotKeyID()
        GetEventParameter(event!, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        if hkID.id == 1 { ScreenshotCapture.shared.capture() }
        return CallNextEventHandler(callRef, event!)
      },
      1, &eventSpec, nil, &eventHandlerRef
    )

    registerHotKey(
      keyCode:   PromptStore.shared.screenshotKeyCode,
      modifiers: PromptStore.shared.screenshotModifiers
    )
  }

  func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
    if let ref = hotKeyRef {
      UnregisterEventHotKey(ref)
      hotKeyRef = nil
    }
    PromptStore.shared.screenshotKeyCode  = keyCode
    PromptStore.shared.screenshotModifiers = modifiers
    registerHotKey(keyCode: keyCode, modifiers: modifiers)
  }

  private func registerHotKey(keyCode: UInt32, modifiers: UInt32) {
    var hotKeyID = EventHotKeyID()
    hotKeyID.signature = 0x5175696C  // 'Quil'
    hotKeyID.id = 1
    RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
  }

  // MARK: - Screenshot capture

  func capture() {
    let tempPath = NSTemporaryDirectory() + "quill_shot_\(Int(Date().timeIntervalSince1970)).png"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-i", "-x", tempPath]  // -i: interactive selection, -x: no shutter sound
    process.terminationHandler = { _ in
      DispatchQueue.main.async {
        guard
          FileManager.default.fileExists(atPath: tempPath),
          let data = try? Data(contentsOf: URL(fileURLWithPath: tempPath))
        else { return }  // user cancelled
        try? FileManager.default.removeItem(atPath: tempPath)
        ScreenshotCapture.shared.showPromptPanel(imageData: data)
      }
    }
    try? process.run()
  }

  // MARK: - Prompt panel (same style as TextCapture's prompt menu)

  private func showPromptPanel(imageData: Data) {
    if promptPanel == nil {
      let panel = ScreenshotPromptNSPanel(
        contentRect: .zero,
        styleMask: [.nonactivatingPanel, .borderless],
        backing: .buffered,
        defer: false
      )
      panel.level = .floating
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = true
      panel.isMovable = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      promptPanel = panel
    }

    let prompts = PromptStore.shared.screenshotAsPrompts

    let view = PromptListView(
      prompts: prompts,
      selectedText: "",
      isEditable: false,
      imageData: imageData
    ) { [weak self] result in
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(result, forType: .string)
      ResultPanel.show(text: result)
      self?.dismissPromptPanel()
    }

    let hosting = NSHostingView(rootView: view)
    hosting.wantsLayer = true
    hosting.layer?.cornerRadius = 14
    hosting.layer?.masksToBounds = true
    hosting.layer?.borderWidth = 0.5
    hosting.layer?.borderColor = NSColor(white: 1, alpha: 0.09).cgColor
    promptPanel?.contentView = hosting

    let rowHeight:   CGFloat = 48
    let inputHeight: CGFloat = 44
    let divider:     CGFloat = 9
    let outerPad:    CGFloat = 14
    let menuWidth:   CGFloat = 224
    let menuHeight   = CGFloat(prompts.count) * rowHeight + divider + inputHeight + outerPad

    let screen = NSScreen.main?.visibleFrame ?? .zero
    promptPanel?.setFrame(
      NSRect(
        x: screen.midX - menuWidth / 2,
        y: screen.midY - menuHeight / 2,
        width: menuWidth,
        height: menuHeight
      ),
      display: false
    )

    if #available(macOS 14, *) { NSApp.activate() }
    else { NSApp.activate(ignoringOtherApps: true) }
    promptPanel?.alphaValue = 0
    promptPanel?.makeKeyAndOrderFront(nil)
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.15
      promptPanel?.animator().alphaValue = 1
    }

    if globalClickMonitor == nil {
      globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown]
      ) { [weak self] _ in
        self?.dismissPromptPanel()
      }
    }
  }

  private func dismissPromptPanel() {
    promptPanel?.orderOut(nil)
    if let m = globalClickMonitor {
      NSEvent.removeMonitor(m)
      globalClickMonitor = nil
    }
  }
}
