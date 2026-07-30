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
  private static let panelSize = NSSize(width: 360, height: 360)

  static func open() {
    if panel == nil {
      let window = HomeNSPanel(
        contentRect: NSRect(origin: .zero, size: panelSize),
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
    positionNearDock()
    panel?.makeKeyAndOrderFront(nil)
  }

  static func close() {
    panel?.orderOut(nil)
  }

  private static func positionNearDock() {
    guard let panel else { return }
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
      ?? NSScreen.main
      ?? NSScreen.screens.first
    guard let screen else {
      panel.center()
      return
    }

    let full = screen.frame
    let visible = screen.visibleFrame
    let bottomInset = visible.minY - full.minY
    let leftInset = visible.minX - full.minX
    let rightInset = full.maxX - visible.maxX
    let gap: CGFloat = 14
    let origin: NSPoint

    if leftInset > bottomInset, leftInset > rightInset, leftInset > 20 {
      origin = NSPoint(x: visible.minX + gap, y: visible.midY - panelSize.height / 2)
    } else if rightInset > bottomInset, rightInset > 20 {
      origin = NSPoint(x: visible.maxX - panelSize.width - gap, y: visible.midY - panelSize.height / 2)
    } else {
      origin = NSPoint(x: visible.midX - panelSize.width / 2, y: visible.minY + gap)
    }
    panel.setFrameOrigin(origin)
  }
}

private func loadHomeAsset(named name: String, size: CGFloat) -> NSImage? {
  guard let path = Bundle.main.path(forResource: name, ofType: "svg"),
        let raw = NSImage(contentsOfFile: path) else { return nil }
  let result = NSImage(size: NSSize(width: size, height: size))
  result.lockFocus()
  raw.draw(
    in: CGRect(x: 0, y: 0, width: size, height: size),
    from: CGRect(origin: .zero, size: raw.size),
    operation: .copy,
    fraction: 1
  )
  result.unlockFocus()
  result.isTemplate = true
  return result
}

private struct HomeAssetIcon: View {
  let name: String
  let color: Color
  let size: CGFloat

  var body: some View {
    Group {
      if let image = loadHomeAsset(named: name, size: size) {
        Image(nsImage: image)
          .renderingMode(.template)
          .foregroundColor(color)
      }
    }
    .frame(width: size, height: size)
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

  var body: some View {
    VStack(spacing: 16) {
      actionStack
      usageCard
      HStack {
        Spacer()

        Button(L10n.t("home.preferences")) {
          HomePanel.close()
          PreferencesPanel.open()
        }
        .buttonStyle(HomeSecondaryButtonStyle())
      }
    }
    .padding(24)
    .frame(width: 360, height: 360)
    .background(
      RoundedRectangle(cornerRadius: 18)
        .fill(bg)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(border))
    )
    .environment(\.colorScheme, .dark)
    .onAppear { billing.refresh() }
  }

  private var actionStack: some View {
    VStack(spacing: 12) {
      VStack(spacing: 8) {
        Button {
          HomePanel.close()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            ScreenshotCapture.shared.capture()
          }
        } label: {
          HStack(spacing: 11) {
            ZStack {
              RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 10/255, green: 10/255, blue: 20/255).opacity(0.10))
                .frame(width: 34, height: 34)
              HomeAssetIcon(
                name: "camera",
                color: Color(red: 10/255, green: 10/255, blue: 20/255),
                size: 19
              )
            }
            Text(L10n.t("home.capture"))
              .font(.system(size: 14, weight: .semibold))
            Spacer()
          }
          .padding(.horizontal, 14)
          .frame(height: 54)
          .background(RoundedRectangle(cornerRadius: 9).fill(accent))
          .foregroundColor(Color(red: 10/255, green: 10/255, blue: 20/255))
        }
        .buttonStyle(.plain)
        functionMeta(text: L10n.t("home.captureHint"), shortcut: screenshotShortcut)
      }

      VStack(spacing: 8) {
        HStack(spacing: 11) {
          ZStack {
            RoundedRectangle(cornerRadius: 8)
              .fill(Color.white.opacity(0.07))
              .frame(width: 34, height: 34)
            HomeAssetIcon(name: "custom-text", color: .white.opacity(0.62), size: 19)
          }
          Text(L10n.t("home.textSelection"))
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.82))
          Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 9).fill(card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(border))
        functionMeta(text: L10n.t("home.textHint"), shortcut: textShortcut)
      }
    }
  }

  private func functionMeta(text: String, shortcut: String) -> some View {
    HStack {
      Text(text)
      Spacer()
      Text(shortcut)
        .fontWeight(.medium)
    }
    .font(.system(size: 10.5))
    .foregroundColor(muted)
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
  private var screenshotShortcut: String {
    OnboardingView.shortcutWords(
      keyCode: PromptStore.shared.screenshotKeyCode,
      modifiers: PromptStore.shared.screenshotModifiers
    )
  }
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
