import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Image compression（上傳前降採樣 + JPEG,控制 vision 成本與延遲）

enum ImageProcessor {
  /// 長邊縮到 maxDimension 以內並轉 JPEG。全解析度 Retina PNG 會產生
  /// 數倍的 token 成本與上傳延遲,這一步是 Quill Cloud 毛利的關鍵。
  static func compressForUpload(
    _ data: Data,
    maxDimension: CGFloat = 1568,
    quality: CGFloat = 0.75
  ) -> (data: Data, mime: String) {
    guard let source = NSBitmapImageRep(data: data), let cgImage = source.cgImage else {
      return (data, "image/png")
    }
    let width  = CGFloat(source.pixelsWide)
    let height = CGFloat(source.pixelsHigh)
    let scale = min(1, maxDimension / max(width, height))
    let newWidth  = max(1, Int(width * scale))
    let newHeight = max(1, Int(height * scale))

    guard let target = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: newWidth, pixelsHigh: newHeight,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return (data, "image/png") }
    target.size = NSSize(width: newWidth, height: newHeight)

    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext(bitmapImageRep: target) {
      NSGraphicsContext.current = ctx
      ctx.cgContext.interpolationQuality = .high
      ctx.cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(newWidth), height: CGFloat(newHeight)))
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let jpeg = target.representation(
      using: .jpeg,
      properties: [.compressionFactor: quality]
    ) else { return (data, "image/png") }

    // 壓縮後反而更大就沿用原圖
    return jpeg.count < data.count ? (jpeg, "image/jpeg") : (data, "image/png")
  }
}

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
        // 檔案不存在 = 使用者按 Esc 取消,靜默返回
        guard FileManager.default.fileExists(atPath: tempPath) else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tempPath)), !data.isEmpty else {
          try? FileManager.default.removeItem(atPath: tempPath)
          Self.showErrorAlert("截圖讀取失敗,請再試一次。")
          return
        }
        try? FileManager.default.removeItem(atPath: tempPath)
        let compressed = ImageProcessor.compressForUpload(data)
        ScreenshotCapture.shared.showPromptPanel(imageData: compressed.data, imageMime: compressed.mime)
      }
    }
    do {
      try process.run()
    } catch {
      Self.showErrorAlert("無法啟動截圖工具:\(error.localizedDescription)")
    }
  }

  static func showErrorAlert(_ message: String) {
    DispatchQueue.main.async {
      if #available(macOS 14, *) { NSApp.activate() }
      else { NSApp.activate(ignoringOtherApps: true) }
      let alert = NSAlert()
      alert.messageText = "Quill"
      alert.informativeText = message
      alert.alertStyle = .warning
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  // MARK: - Prompt panel (same style as TextCapture's prompt menu)

  private func showPromptPanel(imageData: Data, imageMime: String) {
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
      imageData: imageData,
      imageMime: imageMime,
      onDismiss: { [weak self] in self?.dismissPromptPanel() }
    )

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

    // 選單出現在滑鼠附近(截圖框選結束的位置),而非螢幕正中央
    let mouse  = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame
      ?? NSScreen.main?.visibleFrame ?? .zero
    var x = mouse.x + 12
    var y = mouse.y - menuHeight - 12
    if y < screen.minY + 20 { y = mouse.y + 20 }
    x = min(max(x, screen.minX + 8), screen.maxX - menuWidth - 8)
    promptPanel?.setFrame(
      NSRect(x: x, y: y, width: menuWidth, height: menuHeight),
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
