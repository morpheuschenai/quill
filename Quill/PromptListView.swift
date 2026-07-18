import SwiftUI
import AppKit

// MARK: - SVG icon loader

private func loadTemplateIcon(_ name: String) -> NSImage? {
  let img = NSImage(named: name)
    ?? Bundle.main.path(forResource: name, ofType: "svg").flatMap { NSImage(contentsOfFile: $0) }
  img?.isTemplate = true
  return img
}

// MARK: - Reusable icon view

private struct PromptIcon: View {
  let name: String
  var size: CGFloat = 14

  var body: some View {
    if let img = loadTemplateIcon(name) {
      Image(nsImage: img)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)
    } else {
      Image(systemName: "sparkles")
        .font(.system(size: size - 2))
    }
  }
}

// MARK: - Button styles

private struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundColor(Color(red: 10/255, green: 10/255, blue: 20/255))
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 7)
          .fill(Color(red: 96/255, green: 165/255, blue: 250/255)
            .opacity(configuration.isPressed ? 0.8 : 1))
      )
  }
}

private struct SecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundColor(.white.opacity(0.5))
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 7)
          .fill(Color.white.opacity(configuration.isPressed ? 0.11 : 0.07))
      )
  }
}

// MARK: - Main view

struct PromptListView: View {
  let prompts: [Prompt]
  let selectedText: String
  let isEditable: Bool
  var imageData: Data? = nil
  var imageMime: String = "image/png"
  /// 僅編輯情境使用:回傳完整結果以原地取代選取文字
  var onResult: (String) -> Void = { _ in }
  /// 選單應關閉時呼叫(結果已改在獨立視窗串流顯示)
  var onDismiss: () -> Void = {}

  @State private var isLoading   = false
  @State private var loadingId: UUID? = nil
  @State private var customPrompt = ""
  @State private var hoveredId: UUID? = nil

  // Design tokens
  private let bg      = Color(red: 20/255, green: 20/255, blue: 26/255)
  private let accent  = Color(red: 96/255, green: 165/255, blue: 250/255)

  var body: some View {
    VStack(spacing: 0) {

      // Preset prompts
      ForEach(prompts) { prompt in
        Button(action: { runPrompt(prompt) }) {
          HStack(spacing: 12) {
            // Colored icon container
            ZStack {
              RoundedRectangle(cornerRadius: 7)
                .fill(loadingId == prompt.id ? accent.opacity(0.2) : prompt.iconBackground)
                .frame(width: 28, height: 28)
              if loadingId == prompt.id {
                ProgressView()
                  .scaleEffect(0.55)
                  .tint(accent)
              } else {
                PromptIcon(name: prompt.iconName)
                  .foregroundColor(prompt.iconTint)
              }
            }

            Text(prompt.title)
              .font(.system(size: 13))
              .foregroundColor(.white.opacity(0.88))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(hoveredId == prompt.id
                ? Color.white.opacity(0.07)
                : Color.clear)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { h in hoveredId = h ? prompt.id : nil }
      }

      // Divider
      Rectangle()
        .fill(Color.white.opacity(0.07))
        .frame(height: 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)

      // Custom instruction row
      HStack(spacing: 10) {
        ZStack {
          RoundedRectangle(cornerRadius: 5)
            .fill(Color.white.opacity(0.06))
            .frame(width: 22, height: 22)
          if isLoading && loadingId == nil {
            ProgressView().scaleEffect(0.5).tint(.white.opacity(0.4))
          } else {
            PromptIcon(name: "custom-text", size: 11)
              .foregroundColor(.white.opacity(0.4))
          }
        }

        TextField("Custom instruction…", text: $customPrompt)
          .textFieldStyle(.plain)
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.6))
          .disabled(isLoading)
          .onSubmit { runCustomPrompt() }

        if !customPrompt.isEmpty {
          Button(action: runCustomPrompt) {
            Image(systemName: "arrow.up.circle.fill")
              .font(.system(size: 16))
              .foregroundColor(accent)
          }
          .buttonStyle(.plain)
          .disabled(isLoading)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.white.opacity(0.04))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
          )
      )
      .padding(.horizontal, 4)
      .padding(.bottom, 4)
    }
    .padding(.top, 6)
    .background(bg)
  }

  // MARK: - Actions

  private func runPrompt(_ prompt: Prompt) {
    guard !isLoading else { return }

    // 截圖:立即開啟串流結果視窗
    if let imageData {
      // title 比對是為既有安裝的舊設定檔補上 autoCopy 行為
      let autoCopy = prompt.autoCopy || prompt.title == "Extract text"
      let session = ChatSession.forImage(
        title: prompt.title, imageData: imageData, mime: imageMime, autoCopy: autoCopy
      )
      ChatWindowManager.open(session: session)
      session.begin(apiUserContent: prompt.systemPrompt, displayUserText: nil)
      onDismiss()
      return
    }

    // 唯讀文字:同樣開串流視窗
    guard isEditable else {
      let session = ChatSession.forText(title: prompt.title, systemPrompt: prompt.systemPrompt)
      ChatWindowManager.open(session: session)
      session.begin(apiUserContent: selectedText, displayUserText: nil)
      onDismiss()
      return
    }

    // 可編輯文字:等完整結果後原地取代
    isLoading = true
    loadingId = prompt.id
    OpenAIService.shared.complete(
      prompt: prompt.systemPrompt,
      text: selectedText,
      maxTokens: prompt.maxTokens
    ) { result in
      DispatchQueue.main.async {
        isLoading = false
        loadingId = nil
        switch result {
        case .success(let text): onResult(OpenAIService.stripCodeFences(text))
        case .failure(let error): showError(error)
        }
      }
    }
  }

  private func runCustomPrompt() {
    let instruction = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !instruction.isEmpty, !isLoading else { return }

    if let imageData {
      let session = ChatSession.forImage(title: "Quill", imageData: imageData, mime: imageMime)
      ChatWindowManager.open(session: session)
      session.begin(apiUserContent: instruction, displayUserText: instruction)
      onDismiss()
      return
    }

    guard isEditable else {
      let session = ChatSession.forText(
        title: "Quill",
        systemPrompt: "Follow the user's instruction on the given text."
      )
      ChatWindowManager.open(session: session)
      session.begin(
        apiUserContent: "Instruction: \(instruction)\n\nText: \(selectedText)",
        displayUserText: instruction
      )
      onDismiss()
      return
    }

    // 可編輯文字 + 自訂指令:原地取代
    isLoading = true
    loadingId = nil
    let systemPrompt = "Follow the user's instruction on the given text. Return only the result, no explanation."
    let userMessage  = "Instruction: \(instruction)\n\nText: \(selectedText)"
    OpenAIService.shared.complete(prompt: systemPrompt, text: userMessage) { result in
      DispatchQueue.main.async {
        isLoading = false
        switch result {
        case .success(let text): onResult(OpenAIService.stripCodeFences(text))
        case .failure(let error): showError(error)
        }
      }
    }
  }

  private func showError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Quill"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
