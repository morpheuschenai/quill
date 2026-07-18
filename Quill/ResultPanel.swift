import AppKit
import Combine
import SwiftUI

// MARK: - Chat session（一個結果視窗 = 一個 session,支援多輪追問）

final class ChatSession: ObservableObject {
  struct Message: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    var text: String
    enum Role: Equatable { case user, assistant }
  }

  @Published var messages: [Message] = []
  @Published var isStreaming = false
  @Published var errorText: String?

  let title: String
  /// 首輪完成後自動複製結果(OCR 情境)
  let autoCopyResult: Bool
  private var hasAutoCopied = false
  private let systemPrompt: String?
  private let imageData: Data?       // 已壓縮(JPEG)
  private let imageMime: String
  private let model: String
  private var apiMessages: [[String: Any]] = []
  private var task: StreamingChatTask?

  private init(
    title: String,
    systemPrompt: String?,
    imageData: Data?,
    imageMime: String,
    model: String,
    autoCopyResult: Bool
  ) {
    self.title = title
    self.systemPrompt = systemPrompt
    self.imageData = imageData
    self.imageMime = imageMime
    self.model = model
    self.autoCopyResult = autoCopyResult
  }

  /// 文字情境(選取文字 → 動作)
  static func forText(title: String, systemPrompt: String, autoCopy: Bool = false) -> ChatSession {
    ChatSession(
      title: title, systemPrompt: systemPrompt,
      imageData: nil, imageMime: "",
      model: PromptStore.shared.textModel,
      autoCopyResult: autoCopy
    )
  }

  /// 截圖情境
  static func forImage(title: String, imageData: Data, mime: String, autoCopy: Bool = false) -> ChatSession {
    ChatSession(
      title: title, systemPrompt: nil,
      imageData: imageData, imageMime: mime,
      model: PromptStore.shared.visionModel,
      autoCopyResult: autoCopy
    )
  }

  var lastAssistantText: String {
    messages.last(where: { $0.role == .assistant })?.text ?? ""
  }

  /// 開始第一輪。displayUserText 非 nil 時在視窗顯示為使用者訊息(自訂指令用)。
  func begin(apiUserContent: String, displayUserText: String?) {
    if let displayUserText, !displayUserText.isEmpty {
      messages.append(Message(role: .user, text: displayUserText))
    }
    if let imageData {
      let b64 = imageData.base64EncodedString()
      let content: [[String: Any]] = [
        ["type": "text", "text": apiUserContent],
        ["type": "image_url", "image_url": ["url": "data:\(imageMime);base64,\(b64)"]]
      ]
      apiMessages.append(["role": "user", "content": content])
    } else {
      if let systemPrompt, !systemPrompt.isEmpty {
        apiMessages.append(["role": "system", "content": systemPrompt])
      }
      apiMessages.append(["role": "user", "content": apiUserContent])
    }
    stream()
  }

  func sendFollowUp(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isStreaming else { return }
    messages.append(Message(role: .user, text: trimmed))
    apiMessages.append(["role": "user", "content": trimmed])
    stream()
  }

  func retry() {
    guard !isStreaming else { return }
    stream()
  }

  func cancel() {
    task?.cancel()
    task = nil
    isStreaming = false
  }

  private func stream() {
    errorText = nil
    isStreaming = true
    messages.append(Message(role: .assistant, text: ""))
    let index = messages.count - 1

    task = OpenAIService.shared.streamChat(
      messages: apiMessages,
      model: model,
      onDelta: { [weak self] delta in
        guard let self, self.messages.indices.contains(index) else { return }
        self.messages[index].text += delta
      },
      onComplete: { [weak self] result in
        guard let self else { return }
        self.isStreaming = false
        switch result {
        case .success(let raw):
          let full = OpenAIService.stripCodeFences(raw)
          if self.messages.indices.contains(index) { self.messages[index].text = full }
          if full.isEmpty {
            if self.messages.indices.contains(index) { self.messages.remove(at: index) }
            self.errorText = "沒有收到回應,請再試一次。"
          } else {
            self.apiMessages.append(["role": "assistant", "content": full])
            if self.autoCopyResult && !self.hasAutoCopied {
              self.hasAutoCopied = true
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(full, forType: .string)
            }
          }
        case .failure(let error):
          if self.messages.indices.contains(index), self.messages[index].text.isEmpty {
            self.messages.remove(at: index)
          }
          self.errorText = error.localizedDescription
        }
      }
    )
  }
}

// MARK: - Window manager（多視窗並存,手動關閉才消失）

enum ChatWindowManager {
  private static var windows: [ChatWindow] = []

  static func open(session: ChatSession) {
    let window = ChatWindow(session: session)
    windows.append(window)
    window.present(cascadeIndex: windows.count - 1)
  }

  static func remove(_ window: ChatWindow) {
    windows.removeAll { $0 === window }
  }
}

final class ChatWindow: NSPanel, NSWindowDelegate {
  private let session: ChatSession

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init(session: ChatSession) {
    self.session = session
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    title = session.title
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isReleasedWhenClosed = false
    appearance = NSAppearance(named: .darkAqua)
    titlebarAppearsTransparent = true
    backgroundColor = NSColor(srgbRed: 20/255, green: 20/255, blue: 26/255, alpha: 0.98)
    minSize = NSSize(width: 320, height: 220)
    delegate = self
    contentView = NSHostingView(rootView: ChatView(session: session))
  }

  func present(cascadeIndex: Int) {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame
      ?? NSScreen.main?.visibleFrame ?? .zero
    let offset = CGFloat(cascadeIndex % 6) * 28

    var x = mouse.x + 18 + offset
    var y = mouse.y - 18 - offset  // top-left 錨點
    x = min(max(x, screen.minX + 8), screen.maxX - frame.width - 8)
    y = min(max(y, screen.minY + frame.height + 8), screen.maxY - 8)
    setFrameTopLeftPoint(NSPoint(x: x, y: y))

    if #available(macOS 14, *) { NSApp.activate() }
    else { NSApp.activate(ignoringOtherApps: true) }
    makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    session.cancel()
    ChatWindowManager.remove(self)
  }
}

// MARK: - SwiftUI chat view

struct ChatView: View {
  @ObservedObject var session: ChatSession
  @State private var followUp = ""
  @State private var justCopied = false

  private let bg     = Color(red: 20/255, green: 20/255, blue: 26/255)
  private let accent = Color(red: 96/255, green: 165/255, blue: 250/255)

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(session.messages) { message in
              bubble(message)
            }
            if session.isStreaming && session.messages.last?.text.isEmpty == true {
              HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5).tint(accent)
                Text("思考中…")
                  .font(.system(size: 12))
                  .foregroundColor(.white.opacity(0.4))
              }
              .padding(.horizontal, 4)
            }
            if let error = session.errorText {
              errorBanner(error)
            }
            Color.clear.frame(height: 1).id("bottom")
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(session.$messages) { _ in
          proxy.scrollTo("bottom", anchor: .bottom)
        }
      }

      Rectangle()
        .fill(Color.white.opacity(0.07))
        .frame(height: 1)

      // 追問輸入列 + 複製
      HStack(spacing: 8) {
        TextField("追問…", text: $followUp, axis: .vertical)
          .lineLimit(1...4)  // 超過一行自動長高,最多 4 行
          .textFieldStyle(.plain)
          .font(.system(size: 12.5))
          .foregroundColor(.white.opacity(0.85))
          .disabled(session.isStreaming)
          .onSubmit(sendFollowUp)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(Color.white.opacity(0.05))
              .overlay(
                RoundedRectangle(cornerRadius: 8)
                  .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
              )
          )

        if !followUp.isEmpty {
          Button(action: sendFollowUp) {
            Image(systemName: "arrow.up.circle.fill")
              .font(.system(size: 18))
              .foregroundColor(accent)
          }
          .buttonStyle(.plain)
          .disabled(session.isStreaming)
        }

        Button(action: copyResult) {
          HStack(spacing: 4) {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
              .font(.system(size: 11))
            Text(justCopied ? "已複製" : "複製")
              .font(.system(size: 12, weight: .medium))
          }
          .foregroundColor(justCopied
            ? Color(red: 52/255, green: 211/255, blue: 153/255)
            : .white.opacity(0.6))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(Color.white.opacity(justCopied ? 0.04 : 0.07))
          )
        }
        .buttonStyle(.plain)
        .disabled(session.lastAssistantText.isEmpty)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
    }
    .background(bg)
  }

  // MARK: Subviews

  @ViewBuilder
  private func bubble(_ message: ChatSession.Message) -> some View {
    if message.role == .user {
      HStack {
        Spacer(minLength: 40)
        Text(message.text)
          .textSelection(.enabled)
          .font(.system(size: 12.5))
          .foregroundColor(.white.opacity(0.9))
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 10)
              .fill(accent.opacity(0.18))
          )
      }
    } else if !message.text.isEmpty {
      Text(message.text)
        .textSelection(.enabled)
        .font(.system(size: 13))
        .lineSpacing(4)
        .foregroundColor(.white.opacity(0.82))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func errorBanner(_ text: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 11))
        .foregroundColor(Color(red: 251/255, green: 146/255, blue: 60/255))
      Text(text)
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.7))
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("重試") { session.retry() }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(accent)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(red: 251/255, green: 146/255, blue: 60/255).opacity(0.08))
    )
  }

  // MARK: Actions

  private func sendFollowUp() {
    let text = followUp
    followUp = ""
    session.sendFollowUp(text)
  }

  private func copyResult() {
    let text = session.lastAssistantText
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    justCopied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
  }
}
