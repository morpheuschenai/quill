import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Panel subclass

private class TextPromptPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

// MARK: - Text capture coordinator

class TextCapture {
  static let shared = TextCapture()

  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private var promptPanel: TextPromptPanel?
  private var globalClickMonitor: Any?
  private var escKeyMonitor: Any?

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
        if hkID.id == 2 { TextCapture.shared.trigger() }
        return CallNextEventHandler(callRef, event!)
      },
      1, &eventSpec, nil, &eventHandlerRef
    )
    registerHotKey(keyCode: PromptStore.shared.textKeyCode, modifiers: PromptStore.shared.textModifiers)
  }

  func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
    if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    PromptStore.shared.textKeyCode  = keyCode
    PromptStore.shared.textModifiers = modifiers
    registerHotKey(keyCode: keyCode, modifiers: modifiers)
  }

  private func registerHotKey(keyCode: UInt32, modifiers: UInt32) {
    var hotKeyID = EventHotKeyID()
    hotKeyID.signature = 0x5175696C  // 'Quil'
    hotKeyID.id = 2
    let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    NSLog("[Quill] TextCapture RegisterEventHotKey status=%d (0=成功)", status)
  }

  // MARK: - Trigger

  func trigger() {
    NSLog("[Quill] 文字快捷鍵觸發")
    let (text, element, isEditable) = readSelectionViaAX()
    if !text.isEmpty {
      showPromptPanel(text: text, element: element, isEditable: isEditable)
      return
    }
    clipboardFallback()
  }

  // MARK: - AX reading

  private func readSelectionViaAX() -> (text: String, element: AXUIElement?, isEditable: Bool) {
    guard let front = NSWorkspace.shared.frontmostApplication,
          front.bundleIdentifier != Bundle.main.bundleIdentifier else {
      return ("", nil, false)
    }

    let sysWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sysWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
          let focusedRef else { return ("", nil, false) }

    let element = focusedRef as! AXUIElement

    var selRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRef) == .success,
          let text = selRef as? String, !text.isEmpty else {
      return ("", nil, false)
    }

    let isEditable = checkEditable(element)
    return (text, element, isEditable)
  }

  private func checkEditable(_ element: AXUIElement) -> Bool {
    var roleRef: CFTypeRef?
    var role: String?
    if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success {
      role = roleRef as? String
    }
    var editRef: CFTypeRef?
    var axEditable: Bool?
    if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editRef) == .success {
      axEditable = editRef as? Bool
    }
    return Self.detectEditable(role: role, axEditable: axEditable)
  }

  /// 純函式，供 unit test 使用。
  /// AXComboBox / AXSearchField 也是可編輯角色（沿用舊 AccessibilityMonitor 的行為）。
  static func detectEditable(role: String?, axEditable: Bool?) -> Bool {
    let editableRoles: Set<String> = [
      kAXTextFieldRole as String,
      kAXTextAreaRole as String,
      kAXComboBoxRole as String,
      "AXSearchField",
    ]
    if let role, editableRoles.contains(role) { return true }
    return axEditable ?? false
  }

  // MARK: - Clipboard fallback

  /// 輪詢間隔與上限：每 50ms 檢查一次 changeCount，最多等 1 秒。
  /// 慢的 app（大型網頁、Electron）需要比固定 0.15s 更長的時間才會寫入 pasteboard。
  private static let pollInterval: TimeInterval = 0.05
  private static let pollTimeout:  TimeInterval = 1.0

  private func clipboardFallback() {
    let pasteboard  = NSPasteboard.general
    let beforeCount = pasteboard.changeCount

    // 備份使用者剪貼簿（每個 item 的所有 types，不只字串）
    let backup: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? [])
      .map { item in
        item.types.compactMap { type in
          item.data(forType: type).map { (type, $0) }
        }
      }

    let src   = CGEventSource(stateID: .combinedSessionState)
    let cDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
    let cUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
    cDown?.flags = .maskCommand
    cUp?.flags   = .maskCommand
    cDown?.post(tap: .cgAnnotatedSessionEventTap)
    cUp?.post(tap: .cgAnnotatedSessionEventTap)

    pollPasteboard(beforeCount: beforeCount, elapsed: 0) { [weak self] text in
      Self.restorePasteboard(backup)
      guard let text, !text.isEmpty else { return }
      self?.showPromptPanel(text: text, element: nil, isEditable: false)
    }
  }

  /// 輪詢 changeCount 直到 app 寫入剪貼簿或 timeout
  private func pollPasteboard(
    beforeCount: Int,
    elapsed: TimeInterval,
    completion: @escaping (String?) -> Void
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
      let pasteboard = NSPasteboard.general
      if pasteboard.changeCount != beforeCount {
        completion(pasteboard.string(forType: .string))
        return
      }
      let newElapsed = elapsed + Self.pollInterval
      if newElapsed >= Self.pollTimeout {
        completion(nil)  // 沒有可複製的選取內容（或 app 不支援 Cmd+C）
        return
      }
      self?.pollPasteboard(beforeCount: beforeCount, elapsed: newElapsed, completion: completion)
    }
  }

  private static func restorePasteboard(_ backup: [[(NSPasteboard.PasteboardType, Data)]]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let items: [NSPasteboardItem] = backup.compactMap { entries in
      guard !entries.isEmpty else { return nil }
      let item = NSPasteboardItem()
      for (type, data) in entries {
        item.setData(data, forType: type)
      }
      return item
    }
    if !items.isEmpty { pasteboard.writeObjects(items) }
  }

  // MARK: - Prompt panel

  private func showPromptPanel(text: String, element: AXUIElement?, isEditable: Bool) {
    if promptPanel == nil {
      let panel = TextPromptPanel(
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

    let prompts = isEditable ? PromptStore.shared.editableAsPrompts : PromptStore.shared.nonEditableAsPrompts

    let view = PromptListView(
      prompts: prompts,
      selectedText: text,
      isEditable: isEditable,
      onResult: { [weak self] result in
        // 僅可編輯情境會走到這裡:原地取代選取文字
        if let element {
          AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, result as CFTypeRef)
        }
        self?.dismiss()
      },
      onDismiss: { [weak self] in self?.dismiss() }
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

    let mouse  = NSEvent.mouseLocation
    let screen = NSScreen.main?.visibleFrame ?? .zero
    var x = mouse.x
    var y = mouse.y - menuHeight
    if y < screen.minY + 20 { y = mouse.y + 20 }
    x = min(max(x, screen.minX + 8), screen.maxX - menuWidth - 8)

    promptPanel?.setFrame(NSRect(x: x, y: y, width: menuWidth, height: menuHeight), display: false)

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
      ) { [weak self] _ in self?.dismiss() }
    }
    if escKeyMonitor == nil {
      escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        if event.keyCode == 53 {  // Esc
          self?.dismiss()
          return nil
        }
        return event
      }
    }
  }

  private func dismiss() {
    promptPanel?.orderOut(nil)
    if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
    if let k = escKeyMonitor { NSEvent.removeMonitor(k); escKeyMonitor = nil }
  }
}
