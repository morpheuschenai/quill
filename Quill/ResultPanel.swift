import AppKit
import SwiftUI

class ResultPanel: NSPanel {
  private static var shared: ResultPanel?

  static func show(text: String) {
    if shared == nil { shared = ResultPanel() }
    shared?.display(text: text)
  }

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.level = .floating
    self.title = "Quill"
    self.collectionBehavior = [.canJoinAllSpaces]
    self.isReleasedWhenClosed = false
    self.appearance = NSAppearance(named: .darkAqua)
    self.titlebarAppearsTransparent = true
    self.backgroundColor = NSColor(
      srgbRed: 20/255, green: 20/255, blue: 26/255, alpha: 0.98
    )
  }

  func display(text: String) {
    let view = ResultView(text: text) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      ResultPanel.shared?.orderOut(nil)
    } onDismiss: {
      ResultPanel.shared?.orderOut(nil)
    }
    contentView = NSHostingView(rootView: view)
    center()
    orderFront(nil)
  }
}

// MARK: - SwiftUI view

struct ResultView: View {
  let text: String
  let onCopy: () -> Void
  let onDismiss: () -> Void

  private let bg     = Color(red: 20/255, green: 20/255, blue: 26/255)
  private let accent = Color(red: 96/255, green: 165/255, blue: 250/255)

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        Text(text)
          .textSelection(.enabled)
          .font(.system(size: 13))
          .lineSpacing(4)
          .foregroundColor(.white.opacity(0.78))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
      }

      Rectangle()
        .fill(Color.white.opacity(0.07))
        .frame(height: 1)

      HStack(spacing: 8) {
        Spacer()
        Button("Dismiss", action: onDismiss)
          .buttonStyle(QuillSecondaryStyle())
        Button("Copy & Close", action: onCopy)
          .buttonStyle(QuillPrimaryStyle())
          .keyboardShortcut(.return)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }
    .background(bg)
  }
}

// MARK: - Button styles

private struct QuillPrimaryStyle: ButtonStyle {
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

private struct QuillSecondaryStyle: ButtonStyle {
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
