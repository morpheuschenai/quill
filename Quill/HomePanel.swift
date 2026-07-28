import AppKit
import SwiftUI

private final class HomeNSPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func resignKey() {
    super.resignKey()
    orderOut(nil)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      orderOut(nil)
    } else {
      super.keyDown(with: event)
    }
  }
}

final class HomePanel {
  private static var panel: HomeNSPanel?

  static func open() {
    if panel == nil {
      let window = HomeNSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 224),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      window.isMovableByWindowBackground = true
      window.backgroundColor = .clear
      window.isOpaque = false
      window.hasShadow = true
      window.appearance = NSAppearance(named: .darkAqua)
      window.contentView = NSHostingView(rootView: HomeView())
      panel = window
    }

    if #available(macOS 14, *) { NSApp.activate() }
    else { NSApp.activate(ignoringOtherApps: true) }
    panel?.center()
    panel?.makeKeyAndOrderFront(nil)
  }

  static func close() {
    panel?.orderOut(nil)
  }
}

private struct HomeView: View {
  @ObservedObject private var billing = BillingService.shared
  @ObservedObject private var locale = LocaleStore.shared

  private let bg = Color(red: 14/255, green: 14/255, blue: 18/255)
  private let card = Color(red: 20/255, green: 20/255, blue: 26/255)
  private let border = Color.white.opacity(0.09)
  private let muted = Color.white.opacity(0.38)
  private let accent = Color(red: 96/255, green: 165/255, blue: 250/255)
  private let green = Color(red: 52/255, green: 211/255, blue: 153/255)

  var body: some View {
    VStack(spacing: 20) {
      HStack(spacing: 14) {
        captureCard
          .frame(maxWidth: .infinity)
        usageCard
          .frame(maxWidth: .infinity)
      }

      HStack {
        HStack(spacing: 8) {
          Circle()
            .fill(green)
            .frame(width: 7, height: 7)
            .shadow(color: green.opacity(0.28), radius: 5)
          Text(L10n.t("home.ready"))
            .font(.system(size: 11.5))
            .foregroundColor(muted)
        }

        Spacer()

        Button(L10n.t("menu.preferences")) {
          HomePanel.close()
          PreferencesPanel.open()
        }
        .buttonStyle(HomeSecondaryButtonStyle())
      }
    }
    .padding(36)
    .frame(width: 700, height: 224)
    .background(
      RoundedRectangle(cornerRadius: 18)
        .fill(bg)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(border))
    )
    .environment(\.colorScheme, .dark)
    .onAppear { billing.refresh() }
  }

  private var captureCard: some View {
    VStack(spacing: 13) {
      Button {
        HomePanel.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
          ScreenshotCapture.shared.capture()
        }
      } label: {
        HStack(spacing: 10) {
          Text(L10n.t("home.capture"))
            .font(.system(size: 14, weight: .semibold))
          Text(OnboardingView.shortcutWords(
            keyCode: PromptStore.shared.screenshotKeyCode,
            modifiers: PromptStore.shared.screenshotModifiers
          ))
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(Color(red: 10/255, green: 10/255, blue: 20/255).opacity(0.64))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 8).fill(accent))
        .foregroundColor(Color(red: 10/255, green: 10/255, blue: 20/255))
      }
      .buttonStyle(.plain)

      Text("\(L10n.t("home.textSelection"))：\(textShortcut)")
      .font(.system(size: 11))
      .foregroundColor(muted)
    }
    .padding(18)
    .background(RoundedRectangle(cornerRadius: 13).fill(card))
    .overlay(RoundedRectangle(cornerRadius: 13).stroke(border))
  }

  private var usageCard: some View {
    VStack(spacing: 0) {
      HStack {
        Text(billing.status?.plan == "pro" ? L10n.t("home.proUsage") : L10n.t("home.freeUsage"))
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Text("\(used) / \(limit)")
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundColor(muted)
      }
      .padding(.bottom, 13)

      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.08))
          Capsule()
            .fill(accent)
            .frame(width: geometry.size.width * usageFraction)
        }
      }
      .frame(height: 7)

      HStack {
        Text(L10n.t("home.remaining", remaining))
        Spacer()
        TimelineView(.periodic(from: .now, by: 60)) { _ in
          Text(resetText)
        }
      }
      .font(.system(size: 11))
      .foregroundColor(muted)
      .padding(.top, 10)
    }
    .padding(18)
    .background(RoundedRectangle(cornerRadius: 13).fill(card))
    .overlay(RoundedRectangle(cornerRadius: 13).stroke(border))
  }

  private var used: Int { billing.status?.used ?? 0 }
  private var limit: Int { billing.status?.limit ?? 10 }
  private var remaining: Int { billing.status?.remaining ?? 10 }
  private var textShortcut: String {
    OnboardingView.shortcutWords(
      keyCode: PromptStore.shared.textKeyCode,
      modifiers: PromptStore.shared.textModifiers
    )
  }

  private var usageFraction: CGFloat {
    guard limit > 0 else { return 0 }
    return min(1, max(0, CGFloat(used) / CGFloat(limit)))
  }

  private var resetText: String {
    guard let target = billing.status?.resetsAt else { return L10n.t("billing.dailyReset") }
    let seconds = max(0, Int(target.timeIntervalSinceNow))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return L10n.t("home.resetsDays", days, hours) }
    if hours > 0 { return L10n.t("home.resetsHours", hours, minutes) }
    return L10n.t("home.resetsMinutes", minutes)
  }
}

private struct HomeSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundColor(.white.opacity(configuration.isPressed ? 0.7 : 0.5))
      .padding(.horizontal, 13)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 7)
          .fill(Color.white.opacity(configuration.isPressed ? 0.11 : 0.07))
      )
  }
}
