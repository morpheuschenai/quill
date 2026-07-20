import AppKit
import ApplicationServices
import Combine
import SwiftUI

// MARK: - Window

final class OnboardingWindow: NSWindow {
  private static var instance: OnboardingWindow?
  private static let doneKey = "quill_onboarding_done_v1"

  static var shouldShowOnLaunch: Bool {
    !UserDefaults.standard.bool(forKey: doneKey)
  }

  static func markDone() {
    UserDefaults.standard.set(true, forKey: doneKey)
  }

  static func open() {
    if instance == nil { instance = OnboardingWindow() }
    if #available(macOS 14, *) { NSApp.activate() }
    else { NSApp.activate(ignoringOtherApps: true) }
    instance?.center()
    instance?.makeKeyAndOrderFront(nil)
  }

  private init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    title = ""
    isReleasedWhenClosed = false
    appearance = NSAppearance(named: .darkAqua)
    titlebarAppearsTransparent = true
    backgroundColor = NSColor(srgbRed: 20/255, green: 20/255, blue: 26/255, alpha: 1)
    contentView = NSHostingView(rootView: OnboardingView { [weak self] in
      OnboardingWindow.markDone()
      self?.close()
    })
  }
}

// MARK: - Permission state(每秒輪詢,使用者在系統設定勾完回來就看到 ✓)

final class OnboardingState: ObservableObject {
  @Published var accessibilityGranted = AXIsProcessTrusted()
  @Published var screenGranted = CGPreflightScreenCaptureAccess()
  @Published var hasAPIKey = !PromptStore.shared.apiKey.isEmpty

  private var timer: Timer?

  func startPolling() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.accessibilityGranted = AXIsProcessTrusted()
      self.screenGranted = CGPreflightScreenCaptureAccess()
    }
  }

  func stopPolling() {
    timer?.invalidate()
    timer = nil
  }

  func requestAccessibility() {
    // 觸發系統的加入提示,並直接開設定頁
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    )
  }

  func requestScreenRecording() {
    _ = CGRequestScreenCaptureAccess()
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    )
  }

  func saveAPIKey(_ key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    PromptStore.shared.apiKey = trimmed
    hasAPIKey = true
  }
}

// MARK: - Main view

struct OnboardingView: View {
  let onFinish: () -> Void

  @StateObject private var state = OnboardingState()
  @State private var step = 0
  @State private var apiKeyInput = ""
  @State private var pathCopied = false

  private let bg     = Color(red: 20/255, green: 20/255, blue: 26/255)
  private let accent = Color(red: 96/255, green: 165/255, blue: 250/255)
  private let green  = Color(red: 52/255, green: 211/255, blue: 153/255)
  private let totalSteps = 4

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 20)

      Group {
        switch step {
        case 0: welcomeStep
        case 1: accessibilityStep
        case 2: screenStep
        default: apiKeyStep
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 48)

      // 進度點 + 導覽列
      HStack {
        Button("上一步") { step -= 1 }
          .buttonStyle(OnboardingSecondaryStyle())
          .opacity(step > 0 ? 1 : 0)

        Spacer()

        HStack(spacing: 7) {
          ForEach(0..<totalSteps, id: \.self) { i in
            Circle()
              .fill(i == step ? accent : Color.white.opacity(0.15))
              .frame(width: 7, height: 7)
          }
        }

        Spacer()

        Button(nextButtonTitle) {
          if step < totalSteps - 1 { step += 1 } else { finish() }
        }
        .buttonStyle(OnboardingPrimaryStyle())
        .keyboardShortcut(.return)
      }
      .padding(.horizontal, 28)
      .padding(.bottom, 22)
      .padding(.top, 10)
    }
    .frame(width: 560, height: 500)
    .background(bg)
    .onAppear { state.startPolling() }
    .onDisappear { state.stopPolling() }
  }

  private var nextButtonTitle: String {
    if step == totalSteps - 1 { return "開始使用 Quill" }
    switch step {
    case 1: return state.accessibilityGranted ? "下一步" : "略過"
    case 2: return state.screenGranted ? "下一步" : "略過"
    default: return "下一步"
    }
  }

  private func finish() {
    state.saveAPIKey(apiKeyInput)
    state.stopPolling()
    onFinish()
  }

  // MARK: Steps

  private var welcomeStep: some View {
    VStack(spacing: 18) {
      // 真實 App icon,和 Dock/Finder 一致
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .scaledToFit()
        .frame(width: 76, height: 76)
      Text("歡迎使用 Quill")
        .font(.system(size: 26, weight: .bold))
        .foregroundColor(.white)
      Text("對你看到的任何東西,直接跟 AI 互動。")
        .font(.system(size: 14))
        .foregroundColor(.white.opacity(0.6))

      VStack(alignment: .leading, spacing: 14) {
        // 顯示使用者實際設定的快捷鍵(可能已在 Preferences 改過)
        hotkeyRow(
          icon: "camera.viewfinder",
          keys: shortcutLabel(
            keyCode: PromptStore.shared.screenshotKeyCode,
            modifiers: PromptStore.shared.screenshotModifiers
          ),
          title: "截圖問 AI", desc: "框選畫面 → 萃取文字、翻譯、解釋,結果當場出現"
        )
        hotkeyRow(
          icon: "text.cursor",
          keys: shortcutLabel(
            keyCode: PromptStore.shared.textKeyCode,
            modifiers: PromptStore.shared.textModifiers
          ),
          title: "選字改文字", desc: "選取文字 → 修正、改語氣、翻譯,直接取代原文"
        )
      }
      .padding(20)
      .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))

      Text("快捷鍵可隨時在 Preferences 修改")
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.35))
    }
  }

  private func hotkeyRow(icon: String, keys: String, title: String, desc: String) -> some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 18))
        .foregroundColor(accent)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
          Text(keys)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
        }
        Text(desc)
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.5))
      }
    }
  }

  private var accessibilityStep: some View {
    permissionStep(
      icon: "hand.raised.fill",
      title: "允許「輔助使用」",
      granted: state.accessibilityGranted,
      why: "Quill 需要這個權限才能讀取你選取的文字,並在原位置替換結果。我們只讀取你主動選取的內容,其他一概不碰。",
      how: "點下方按鈕 → 在系統設定找到 Quill → 打開開關",
      buttonTitle: "開啟輔助使用設定",
      action: state.requestAccessibility
    )
  }

  private var screenStep: some View {
    VStack(spacing: 12) {
      permissionStep(
        icon: "camera.viewfinder",
        title: "允許「螢幕錄製」",
        granted: state.screenGranted,
        why: "截圖功能需要這個權限,否則拍到的畫面不會包含視窗內容。截圖只在你按下快捷鍵時發生,且只送往你設定的 AI 服務。",
        how: "點下方按鈕 → 勾選 Quill → 回來點「重新啟動」讓權限生效。",
        buttonTitle: "開啟螢幕錄製設定",
        action: state.requestScreenRecording
      )
      // macOS 規定:螢幕錄製權限變更後,App 必須重啟才生效
      Button("已勾選?重新啟動 Quill 讓權限生效") {
        Self.relaunchApp()
      }
      .buttonStyle(OnboardingSecondaryStyle())
    }
  }

  private static func relaunchApp() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", Bundle.main.bundlePath]
    try? task.run()
    NSApp.terminate(nil)
  }

  private func permissionStep(
    icon: String, title: String, granted: Bool,
    why: String, how: String, buttonTitle: String,
    action: @escaping () -> Void
  ) -> some View {
    VStack(spacing: 16) {
      ZStack {
        Circle()
          .fill((granted ? green : accent).opacity(0.15))
          .frame(width: 76, height: 76)
        Image(systemName: granted ? "checkmark" : icon)
          .font(.system(size: 30, weight: granted ? .bold : .regular))
          .foregroundColor(granted ? green : accent)
      }
      Text(granted ? "\(title) — 已完成" : title)
        .font(.system(size: 21, weight: .bold))
        .foregroundColor(.white)
      Text(why)
        .font(.system(size: 13))
        .foregroundColor(.white.opacity(0.6))
        .multilineTextAlignment(.center)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)

      if !granted {
        Text(how)
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.45))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        Button(buttonTitle, action: action)
          .buttonStyle(OnboardingPrimaryStyle())
        // 清單裡沒有 Quill 時的逃生口:點「+」手動加入,路徑先複製好
        Button(pathCopied ? "已複製,到設定按「+」貼上路徑" : "清單裡沒有 Quill?複製 App 路徑") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(Bundle.main.bundlePath, forType: .string)
          pathCopied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 4) { pathCopied = false }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundColor(pathCopied
          ? Color(red: 52/255, green: 211/255, blue: 153/255)
          : .white.opacity(0.4))
      } else {
        Text("設定完成,可以進入下一步。")
          .font(.system(size: 12))
          .foregroundColor(green.opacity(0.8))
      }
    }
  }

  private var apiKeyStep: some View {
    VStack(spacing: 16) {
      Image(systemName: "key.fill")
        .font(.system(size: 34))
        .foregroundColor(accent)
      Text("連接 AI 服務")
        .font(.system(size: 21, weight: .bold))
        .foregroundColor(.white)

      if state.hasAPIKey && apiKeyInput.isEmpty {
        Text("已偵測到 API key,直接開始即可。想更換的話貼上新的 key 就會覆蓋。")
          .font(.system(size: 13))
          .foregroundColor(green.opacity(0.85))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("貼上你的 OpenAI API key(儲存在 macOS Keychain,只用來直連 AI 服務,不會經過任何其他伺服器)。")
          .font(.system(size: 13))
          .foregroundColor(.white.opacity(0.6))
          .multilineTextAlignment(.center)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
      }

      SecureField("sk-…", text: $apiKeyInput)
        .textFieldStyle(.plain)
        .font(.system(size: 13, design: .monospaced))
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(0.05))
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
        )
        .frame(maxWidth: 360)

      Button("前往 platform.openai.com 取得 API key") {
        NSWorkspace.shared.open(URL(string: "https://platform.openai.com/api-keys")!)
      }
      .buttonStyle(.plain)
      .font(.system(size: 12))
      .foregroundColor(accent)

      Text("也支援任何 OpenAI 相容服務(Groq、OpenRouter、本機 Ollama),可稍後在 Preferences 修改。")
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.35))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Button styles

struct OnboardingPrimaryStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundColor(Color(red: 10/255, green: 10/255, blue: 20/255))
      .padding(.horizontal, 18)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(Color(red: 96/255, green: 165/255, blue: 250/255)
            .opacity(configuration.isPressed ? 0.8 : 1))
      )
  }
}

struct OnboardingSecondaryStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundColor(.white.opacity(0.5))
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.white.opacity(configuration.isPressed ? 0.11 : 0.07))
      )
  }
}
