import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Window

final class OnboardingWindow: NSWindow {
  private static var instance: OnboardingWindow?
  private static let doneKey = "quill_onboarding_done_v1"
  static let resumeKey = "quill_onboarding_resume_step"

  static var shouldShowOnLaunch: Bool {
    // 尚未完成引導,或剛因權限重啟需要接續
    !UserDefaults.standard.bool(forKey: doneKey) || resumeStep != nil
  }

  /// 因權限重啟而要接續的步驟(取出後即清除)
  static var resumeStep: Int? {
    guard let v = UserDefaults.standard.object(forKey: resumeKey) as? Int else { return nil }
    return v
  }

  static func consumeResumeStep() -> Int? {
    let v = resumeStep
    UserDefaults.standard.removeObject(forKey: resumeKey)
    return v
  }

  static func markDone() {
    UserDefaults.standard.set(true, forKey: doneKey)
  }

  /// macOS 規定:螢幕錄製權限變更後 App 必須重啟才生效。
  /// 重啟前記住要回到哪一步,啟動時自動重開引導,使用者不需自己找選單列。
  static func relaunchApp(resumeStep: Int) {
    UserDefaults.standard.set(resumeStep, forKey: resumeKey)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", Bundle.main.bundlePath]
    try? task.run()
    NSApp.terminate(nil)
  }

  static func open() {
    if instance == nil { instance = OnboardingWindow(startStep: consumeResumeStep() ?? 0) }
    if #available(macOS 14, *) { NSApp.activate() }
    else { NSApp.activate(ignoringOtherApps: true) }
    instance?.center()
    instance?.makeKeyAndOrderFront(nil)
  }

  private init(startStep: Int) {
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
    contentView = NSHostingView(rootView: OnboardingView(startStep: startStep) { [weak self] in
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
  var startStep: Int = 0
  let onFinish: () -> Void

  @StateObject private var state = OnboardingState()
  @ObservedObject private var loc = LocaleStore.shared
  @ObservedObject private var usage = UsageTracker.shared
  @State private var step = 0
  @State private var pathCopied = false

  private let bg     = Color(red: 20/255, green: 20/255, blue: 26/255)
  private let accent = Color(red: 96/255, green: 165/255, blue: 250/255)
  private let green  = Color(red: 52/255, green: 211/255, blue: 153/255)
  private let totalSteps = 5

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 20)

      Group {
        switch step {
        case 0: welcomeStep
        case 1: accessibilityStep
        case 2: screenStep
        case 3: tryItStep
        default: apiKeyStep
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 48)

      // 進度點 + 導覽列
      HStack {
        Button(L10n.t("ob.back")) { step -= 1 }
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
          // 螢幕錄製尚未生效時,主按鈕就是「重新啟動」(macOS 規定必須重啟)
          if step == 2 && !state.screenGranted {
            OnboardingWindow.relaunchApp(resumeStep: 2)
            return
          }
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
    .onAppear {
      step = startStep          // 因權限重啟時,直接回到原本那一步
      state.startPolling()
    }
    .onDisappear { state.stopPolling() }
  }

  private var nextButtonTitle: String {
    if step == totalSteps - 1 { return L10n.t("ob.start") }
    switch step {
    case 1: return state.accessibilityGranted ? L10n.t("ob.next") : L10n.t("ob.skip")
    // 螢幕錄製:勾選後一定要重啟才生效,所以直接把主按鈕變成重新啟動
    case 2: return state.screenGranted ? L10n.t("ob.next") : L10n.t("ob.relaunch")
    case 3: return usage.didCompleteOnce ? L10n.t("ob.next") : L10n.t("ob.skip")
    default: return L10n.t("ob.next")
    }
  }

  private func finish() {
    // Cloud 模式免 key;不再於 onboarding 收集 API key
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
      Text(L10n.t("ob.welcome.title"))
        .font(.system(size: 26, weight: .bold))
        .foregroundColor(.white)
      Text(L10n.t("ob.welcome.sub"))
        .font(.system(size: 14))
        .foregroundColor(.white.opacity(0.6))

      VStack(alignment: .leading, spacing: 14) {
        // 顯示使用者實際設定的快捷鍵(可能已在 Preferences 改過)
        hotkeyRow(
          svg: "camera",
          keys: Self.shortcutWords(
            keyCode: PromptStore.shared.screenshotKeyCode,
            modifiers: PromptStore.shared.screenshotModifiers
          ),
          title: L10n.t("ob.welcome.shot.title"), desc: L10n.t("ob.welcome.shot.desc")
        )
        hotkeyRow(
          svg: "custom-text",
          keys: Self.shortcutWords(
            keyCode: PromptStore.shared.textKeyCode,
            modifiers: PromptStore.shared.textModifiers
          ),
          title: L10n.t("ob.welcome.text.title"), desc: L10n.t("ob.welcome.text.desc")
        )
      }
      .padding(20)
      .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))

      Text(L10n.t("ob.welcome.hint"))
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.35))
    }
  }

  /// 快捷鍵的「文字版」:一般用戶不見得看得懂 ⌃⌥ 符號,直接寫字。
  static func shortcutWords(keyCode: UInt32, modifiers: UInt32) -> String {
    var parts: [String] = []
    if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
    if modifiers & UInt32(optionKey)  != 0 { parts.append("Option") }
    if modifiers & UInt32(shiftKey)   != 0 { parts.append("Shift") }
    if modifiers & UInt32(cmdKey)     != 0 { parts.append("Command") }
    parts.append(keyCodeMap[keyCode] ?? "?")
    return parts.joined(separator: " + ")
  }

  /// 載入 bundle 內的 SVG 圖示(template 模式,可套色)
  static func svgIcon(_ name: String) -> NSImage? {
    guard let path = Bundle.main.path(forResource: name, ofType: "svg"),
          let img = NSImage(contentsOfFile: path) else { return nil }
    img.isTemplate = true
    return img
  }

  private func hotkeyRow(svg: String, keys: String, title: String, desc: String) -> some View {
    HStack(spacing: 14) {
      Group {
        if let img = Self.svgIcon(svg) {
          Image(nsImage: img).renderingMode(.template).resizable().scaledToFit()
        } else {
          Image(systemName: "sparkles").resizable().scaledToFit()
        }
      }
      .frame(width: 20, height: 20)
      .foregroundColor(accent)
      .frame(width: 26)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
          Text(keys)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 7)
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
      title: L10n.t("ob.ax.title"),
      granted: state.accessibilityGranted,
      why: L10n.t("ob.ax.why"),
      how: L10n.t("ob.ax.how"),
      buttonTitle: L10n.t("ob.ax.button"),
      action: state.requestAccessibility
    )
  }

  private var screenStep: some View {
    permissionStep(
      icon: "camera.viewfinder",
      title: L10n.t("ob.screen.title"),
      granted: state.screenGranted,
      why: L10n.t("ob.screen.why"),
      how: L10n.t("ob.screen.how"),
      buttonTitle: L10n.t("ob.screen.button"),
      action: state.requestScreenRecording
    )
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
      Text(title)
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
        Button(pathCopied ? L10n.t("ob.perm.copied") : L10n.t("ob.perm.copyPath")) {
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
        Text(L10n.t("ob.perm.done"))
          .font(.system(size: 12))
          .foregroundColor(green.opacity(0.8))
      }
    }
  }

  private var tryItStep: some View {
    VStack(spacing: 16) {
      ZStack {
        Circle()
          .fill((usage.didCompleteOnce ? green : accent).opacity(0.15))
          .frame(width: 76, height: 76)
        Group {
          if usage.didCompleteOnce {
            Image(systemName: "checkmark").resizable().scaledToFit()
          } else if let img = Self.svgIcon("camera") {
            Image(nsImage: img).renderingMode(.template).resizable().scaledToFit()
          } else {
            Image(systemName: "camera.viewfinder").resizable().scaledToFit()
          }
        }
        .frame(width: 30, height: 30)
        .foregroundColor(usage.didCompleteOnce ? green : accent)
      }

      Text(usage.didCompleteOnce ? L10n.t("ob.try.done") : L10n.t("ob.try.title"))
        .font(.system(size: 21, weight: .bold))
        .foregroundColor(.white)

      Text(usage.didCompleteOnce ? L10n.t("ob.try.doneSub") : L10n.t("ob.try.sub"))
        .font(.system(size: 13))
        .foregroundColor(.white.opacity(0.6))
        .multilineTextAlignment(.center)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 400)

      if !usage.didCompleteOnce {
        // 讓使用者框選的示範句(跟官網 demo 同一招:看不懂 → 框起來 → 秒懂)
        Text(L10n.t("ob.try.sample"))
          .font(.system(size: 14))
          .italic()
          .foregroundColor(.white.opacity(0.85))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .frame(maxWidth: 420)
          .background(
            RoundedRectangle(cornerRadius: 10)
              .fill(accent.opacity(0.10))
              .overlay(
                RoundedRectangle(cornerRadius: 10)
                  .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                  .foregroundColor(accent.opacity(0.55))
              )
          )

        if usage.didCaptureOnce {
          // 已框選但還沒看到 AI 回覆:提示選一個動作
          HStack(spacing: 7) {
            ProgressView().scaleEffect(0.5).tint(accent)
            Text(L10n.t("ob.try.pickAction"))
              .font(.system(size: 12.5))
              .foregroundColor(accent.opacity(0.9))
          }
        } else {
          HStack(spacing: 8) {
            Text(Self.shortcutWords(
              keyCode: PromptStore.shared.screenshotKeyCode,
              modifiers: PromptStore.shared.screenshotModifiers
            ))
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))

            Text(L10n.t("ob.try.hint"))
              .font(.system(size: 12))
              .foregroundColor(.white.opacity(0.5))
          }
        }
      }
    }
  }

  private var apiKeyStep: some View {
    VStack(spacing: 16) {
      ZStack {
        Circle().fill(green.opacity(0.15)).frame(width: 76, height: 76)
        Image(systemName: "checkmark")
          .font(.system(size: 30, weight: .bold))
          .foregroundColor(green)
      }
      Text(L10n.t("ob.ready.title"))
        .font(.system(size: 21, weight: .bold))
        .foregroundColor(.white)

      Text(L10n.t("ob.ready.sub"))
        .font(.system(size: 13))
        .foregroundColor(.white.opacity(0.6))
        .multilineTextAlignment(.center)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 380)

      VStack(alignment: .leading, spacing: 10) {
        readyRow(svg: "shopping-cart", text: L10n.t("ob.ready.quota"))
        readyRow(svg: "lock", text: L10n.t("ob.ready.privacy"))
      }
      .padding(16)
      .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))

      Text(L10n.t("ob.ready.advanced"))
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.35))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func readyRow(svg: String, text: String) -> some View {
    HStack(spacing: 10) {
      Group {
        if let img = Self.svgIcon(svg) {
          Image(nsImage: img).renderingMode(.template).resizable().scaledToFit()
        } else {
          Image(systemName: "checkmark").resizable().scaledToFit()
        }
      }
      .frame(width: 16, height: 16)
      .foregroundColor(green)
      .frame(width: 18)
      Text(text)
        .font(.system(size: 13))
        .foregroundColor(.white.opacity(0.8))
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
