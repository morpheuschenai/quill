import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Window

class PreferencesPanel: NSWindow {
  private static var instance: PreferencesPanel?

  static func open() {
    if instance == nil {
      let win = PreferencesPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      win.title = "Quill"
      win.isReleasedWhenClosed = false
      win.appearance = NSAppearance(named: .darkAqua)
      win.backgroundColor = NSColor(srgbRed: 14/255, green: 14/255, blue: 18/255, alpha: 1)
      win.titlebarAppearsTransparent = true
      win.contentView = NSHostingView(rootView: PrefRootView())
      win.center()
      instance = win
    }
    if #available(macOS 14, *) { NSApp.activate() }
    else { NSApp.activate(ignoringOtherApps: true) }
    instance?.makeKeyAndOrderFront(nil)
  }
}

// MARK: - Window resize helper

private func resizeWindow(to size: CGSize) {
  guard let win = NSApp.windows.first(where: { $0 is PreferencesPanel }) else { return }
  var frame = win.frame
  let delta = size.height - frame.height
  frame.origin.y -= delta
  frame.size = size
  win.setFrame(frame, display: true, animate: true)
}

// MARK: - Design tokens

private let prefBg0:    Color = Color(red: 14/255,  green: 14/255,  blue: 18/255)
private let prefBg1:    Color = Color(red: 20/255,  green: 20/255,  blue: 26/255)
private let prefBorder: Color = Color.white.opacity(0.09)
private let prefHover:  Color = Color.white.opacity(0.07)
private let prefMuted:  Color = Color.white.opacity(0.38)
private let prefAccent: Color = Color(red: 96/255,  green: 165/255, blue: 250/255)

private func loadSVG(named name: String, size: CGFloat) -> NSImage? {
  guard let path = Bundle.main.path(forResource: name, ofType: "svg"),
        let raw = NSImage(contentsOfFile: path) else { return nil }
  let result = NSImage(size: NSSize(width: size, height: size))
  result.lockFocus()
  raw.draw(in: CGRect(x: 0, y: 0, width: size, height: size),
           from: CGRect(x: 0, y: 0, width: raw.size.width, height: raw.size.height),
           operation: .copy, fraction: 1.0)
  result.unlockFocus()
  result.isTemplate = true
  return result
}

private struct SVGIcon: View {
  let name: String
  let color: Color
  var size: CGFloat = 15

  var body: some View {
    Group {
      if let img = loadSVG(named: name, size: size) {
        Image(nsImage: img)
          .renderingMode(.template)
          .foregroundColor(color)
      }
    }
    .frame(width: size, height: size)
  }
}

// MARK: - Route

private enum Route: Hashable { case apiKey, prompts, textShortcut, screenshotShortcut, language }

// MARK: - Hotkey helpers

// 供 PreferencesPanel 與 OnboardingWindow 共用
let keyCodeMap: [UInt32: String] = [
  0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
  11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
  31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",
  45:"N",46:"M",
  18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",
  26:"7",27:"-",28:"8",29:"0",
  33:"[",30:"]",41:";",39:"'",43:",",44:"/",47:".",
  48:"⇥",49:"Space",51:"⌫",53:"⎋",
  96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",
  103:"F11",105:"F13",107:"F14",109:"F10",111:"F12",
  122:"F1",120:"F2",118:"F4",
]

func shortcutLabel(keyCode: UInt32, modifiers: UInt32) -> String {
  var parts = ""
  if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
  if modifiers & UInt32(optionKey)  != 0 { parts += "⌥" }
  if modifiers & UInt32(shiftKey)   != 0 { parts += "⇧" }
  if modifiers & UInt32(cmdKey)     != 0 { parts += "⌘" }
  parts += keyCodeMap[keyCode] ?? "?"
  return parts
}

private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
  var m: UInt32 = 0
  if flags.contains(.command) { m |= UInt32(cmdKey) }
  if flags.contains(.option)  { m |= UInt32(optionKey) }
  if flags.contains(.shift)   { m |= UInt32(shiftKey) }
  if flags.contains(.control) { m |= UInt32(controlKey) }
  return m
}

// MARK: - Root

private struct PrefRootView: View {
  @State private var path = NavigationPath()

  var body: some View {
    NavigationStack(path: $path) {
      PrefMainList(path: $path)
        .navigationDestination(for: Route.self) { r in
          switch r {
          case .language:          LanguageView()
          case .apiKey:            APIKeyView()
          case .prompts:           PromptsView()
          case .textShortcut:
            ShortcutView(
              title: L10n.t("pref.textShortcut"),
              description: L10n.t("pref.textShortcut.desc"),
              keyCode: PromptStore.shared.textKeyCode,
              modifiers: PromptStore.shared.textModifiers
            ) { kc, mods in TextCapture.shared.updateHotkey(keyCode: kc, modifiers: mods) }
          case .screenshotShortcut:
            ShortcutView(
              title: L10n.t("pref.shotShortcut"),
              description: L10n.t("pref.shotShortcut.desc"),
              keyCode: PromptStore.shared.screenshotKeyCode,
              modifiers: PromptStore.shared.screenshotModifiers
            ) { kc, mods in ScreenshotCapture.shared.updateHotkey(keyCode: kc, modifiers: mods) }
          }
        }
    }
    .frame(width: 420)
    .background(prefBg0)
    .environment(\.colorScheme, .dark)
  }
}

// MARK: - Main list

private struct PrefMainList: View {
  @Binding var path: NavigationPath
  @ObservedObject private var loc = LocaleStore.shared

  var body: some View {
    VStack(spacing: 0) {
      PrefRow(
        icon: "translate",
        iconColor: Color(red: 96/255, green: 165/255, blue: 250/255),
        label: L10n.t("lang.title"),
        detail: LocaleStore.shared.language.displayName
      ) { path.append(Route.language) }
      Divider().opacity(0.10).padding(.horizontal, 16)
      PrefRow(icon: "api_key", iconColor: prefAccent, label: L10n.t("pref.provider")) {
        path.append(Route.apiKey)
      }
      Divider().opacity(0.10).padding(.horizontal, 16)
      PrefRow(icon: "prompt", iconColor: Color(red: 167/255, green: 139/255, blue: 250/255), label: L10n.t("pref.prompts")) {
        path.append(Route.prompts)
      }
      Divider().opacity(0.10).padding(.horizontal, 16)
      PrefRow(
        icon: "custom-text",
        iconColor: Color(red: 251/255, green: 146/255, blue: 60/255),
        label: L10n.t("pref.textShortcut"),
        detail: OnboardingView.shortcutWords(
          keyCode:   PromptStore.shared.textKeyCode,
          modifiers: PromptStore.shared.textModifiers
        )
      ) { path.append(Route.textShortcut) }
      Divider().opacity(0.10).padding(.horizontal, 16)
      PrefRow(
        icon: "keyboard",
        iconColor: Color(red: 52/255, green: 211/255, blue: 153/255),
        label: L10n.t("pref.shotShortcut"),
        detail: OnboardingView.shortcutWords(
          keyCode:   PromptStore.shared.screenshotKeyCode,
          modifiers: PromptStore.shared.screenshotModifiers
        )
      ) { path.append(Route.screenshotShortcut) }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 12).fill(prefBg1))
    .padding(20)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(prefBg0)
    .onAppear { resizeWindow(to: CGSize(width: 420, height: 400)) }
  }
}

private struct PrefRow: View {
  let icon: String
  let iconColor: Color
  let label: String
  var detail: String? = nil
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 7)
            .fill(iconColor.opacity(0.15))
            .frame(width: 28, height: 28)
          SVGIcon(name: icon, color: iconColor, size: 15)
        }
        Text(label)
          .font(.system(size: 13))
          .foregroundColor(.white.opacity(0.88))
          .frame(maxWidth: .infinity, alignment: .leading)
        if let detail {
          Text(detail)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(prefMuted)
        }
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.white.opacity(0.22))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(RoundedRectangle(cornerRadius: 8).fill(hovered ? prefHover : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
  }
}

// MARK: - Provider & API Key view

private let providerPresets: [(label: String, endpoint: String, model: String)] = [
  ("OpenAI",     "https://api.openai.com/v1",      "gpt-4o-mini"),
  ("Groq",       "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile"),
  ("OpenRouter", "https://openrouter.ai/api/v1",   "openai/gpt-4o-mini"),
  ("Ollama",     "http://localhost:11434/v1",       "llama3.2"),
]

private struct APIKeyView: View {
  @State private var endpoint: String = PromptStore.shared.apiEndpoint
  @State private var model: String    = PromptStore.shared.textModel
  @State private var apiKey: String   = PromptStore.shared.apiKey
  @State private var isVisible = false
  @State private var saved = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Provider quick-select
      VStack(alignment: .leading, spacing: 6) {
        Text("Provider")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(prefMuted)
        HStack(spacing: 6) {
          ForEach(providerPresets, id: \.label) { preset in
            let selected = endpoint.trimmingCharacters(in: .init(charactersIn: "/")) ==
                           preset.endpoint.trimmingCharacters(in: .init(charactersIn: "/"))
                        && model == preset.model
            Button(preset.label) { endpoint = preset.endpoint; model = preset.model }
              .buttonStyle(.plain)
              .font(.system(size: 11, weight: selected ? .semibold : .regular))
              .foregroundColor(selected ? prefAccent : prefMuted)
              .padding(.horizontal, 10).padding(.vertical, 4)
              .background(
                RoundedRectangle(cornerRadius: 6)
                  .fill(selected ? prefAccent.opacity(0.12) : prefBg1)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .stroke(selected ? prefAccent.opacity(0.4) : prefBorder, lineWidth: 1)
              )
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 20)

      // Endpoint field
      fieldRow(label: "Endpoint") {
        TextField("https://api.openai.com/v1", text: $endpoint)
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.78))
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 20)
      .padding(.top, 14)

      // Model field
      fieldRow(label: "Model") {
        TextField("gpt-4o-mini", text: $model)
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.78))
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 20)
      .padding(.top, 10)

      // API Key field
      fieldRow(label: "API Key") {
        Group {
          if isVisible {
            TextField("sk-…", text: $apiKey)
          } else {
            SecureField("sk-…", text: $apiKey)
          }
        }
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
        .textFieldStyle(.plain)

        Button(action: { isVisible.toggle() }) {
          SVGIcon(name: isVisible ? "hide" : "view", color: .white.opacity(0.32), size: 14)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 20)
      .padding(.top, 10)

      Text("Stored locally. Not required for Ollama.")
        .font(.system(size: 11))
        .foregroundColor(prefMuted)
        .padding(.horizontal, 20)
        .padding(.top, 6)

      Spacer()

      HStack {
        if saved {
          Text(L10n.t("pref.saved"))
            .font(.system(size: 12))
            .foregroundColor(prefMuted)
            .transition(.opacity)
        }
        Spacer()
        Button("Save") {
          PromptStore.shared.apiEndpoint = endpoint
          PromptStore.shared.textModel   = model
          PromptStore.shared.apiKey      = apiKey
          withAnimation { saved = true }
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { saved = false }
          }
        }
        .buttonStyle(PrefPrimary())
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(width: 420, height: 380)
    .background(prefBg0)
    .navigationTitle("Provider & API Key")
    .onAppear { resizeWindow(to: CGSize(width: 420, height: 380)) }
  }

  private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(prefMuted)
      HStack(spacing: 8) {
        content()
      }
      .padding(.horizontal, 10).padding(.vertical, 9)
      .background(RoundedRectangle(cornerRadius: 8).fill(prefBg1))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(prefBorder, lineWidth: 1))
    }
  }
}

// MARK: - Tab bar

private struct PrefTabBar: View {
  @Binding var selection: Int
  let tabs: [String]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(tabs.indices, id: \.self) { i in
        Button(action: { selection = i }) {
          Text(tabs[i])
            .font(.system(size: 12, weight: selection == i ? .medium : .regular))
            .foregroundColor(selection == i ? .white.opacity(0.90) : prefMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .fill(selection == i ? Color.white.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(3)
    .background(RoundedRectangle(cornerRadius: 9).fill(prefBg1))
  }
}

// MARK: - Prompts view

private struct PromptsView: View {
  @ObservedObject private var store = PromptStore.shared
  @State private var category = 0
  @State private var editingConfig: PromptConfig? = nil
  @State private var showAdd = false

  // 分頁順序:截圖(主打)→ 可編輯文字 → 唯讀文字
  private var binding: Binding<[PromptConfig]> {
    switch category {
    case 0: return $store.screenshotPrompts
    case 1: return $store.editablePrompts
    default: return $store.nonEditablePrompts
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      PrefTabBar(selection: $category, tabs: [L10n.t("tab.screenshot"), L10n.t("tab.editable"), L10n.t("tab.readonly")])
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)

      Text("Customise the AI actions shown when you select text or capture a screenshot.")
        .font(.system(size: 12))
        .foregroundColor(prefMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)

      List {
        ForEach(binding) { $config in
          PromptRow(config: $config,
                    onEdit:   { editingConfig = config },
                    onDelete: {
                      binding.wrappedValue.removeAll { $0.id == config.id }
                      store.save()
                    })
          .listRowBackground(Color.clear)
          .listRowSeparatorTint(Color.white.opacity(0.07))
          .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
        }
        .onMove { from, to in
          binding.wrappedValue.move(fromOffsets: from, toOffset: to)
          store.save()
        }

        AddPromptRow { showAdd = true }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(prefBg0)
    }
    .frame(width: 420, height: 480)
    .background(prefBg0)
    .navigationTitle("Prompts")
    .onAppear { resizeWindow(to: CGSize(width: 420, height: 480)) }
    .sheet(item: $editingConfig) { config in
      EditSheet(config: config, isNew: false) { updated in
        if let i = binding.wrappedValue.firstIndex(where: { $0.id == updated.id }) {
          binding.wrappedValue[i] = updated
          store.save()
        }
        editingConfig = nil
      } onCancel: { editingConfig = nil }
    }
    .sheet(isPresented: $showAdd) {
      EditSheet(
        config: PromptConfig(title: "", systemPrompt: "", maxTokens: 400),
        isNew: true
      ) { newConfig in
        binding.wrappedValue.append(newConfig)
        store.save()
        showAdd = false
      } onCancel: { showAdd = false }
    }
  }
}

// MARK: - Prompt row

private struct AddPromptRow: View {
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Spacer().frame(width: 14)  // align with rearrange column
        SVGIcon(name: "add", color: prefAccent, size: 24)
          .frame(width: 32, height: 32)
        Text("Add Prompt")
          .font(.system(size: 13))
          .foregroundColor(prefAccent)
        Spacer()
      }
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(hovered ? prefHover : Color.clear)
    .onHover { hovered = $0 }
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
  }
}

private struct PromptRow: View {
  @Binding var config: PromptConfig
  let onEdit: () -> Void
  let onDelete: () -> Void
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 10) {
      SVGIcon(name: "rearrange", color: .white.opacity(0.22), size: 17)
      ZStack {
        RoundedRectangle(cornerRadius: 7)
          .fill(PromptStore.palette[config.colorIndex % PromptStore.palette.count].bg)
          .frame(width: 32, height: 32)
        SVGIcon(
          name: config.iconName,
          color: PromptStore.palette[config.colorIndex % PromptStore.palette.count].tint,
          size: 24
        )
      }
      Text(config.title)
        .font(.system(size: 13))
        .foregroundColor(.white.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
      if hovered {
        Button(action: onEdit) {
          SVGIcon(name: "edit", color: .white.opacity(0.40), size: 17)
        }.buttonStyle(.plain)
        Button(action: onDelete) {
          SVGIcon(name: "trash", color: Color(red: 251/255, green: 113/255, blue: 133/255), size: 17)
        }.buttonStyle(.plain)
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .contentShape(Rectangle())
    .background(RoundedRectangle(cornerRadius: 8).fill(hovered ? prefHover : Color.clear))
    .onHover { hovered = $0 }
  }
}

// MARK: - Edit / Add sheet

private struct EditSheet: View {
  @State var config: PromptConfig
  let isNew: Bool
  let onSave: (PromptConfig) -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(isNew ? "Add Prompt" : "Edit Prompt")
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(.white.opacity(0.88))
        .padding(.top, 4)

      fieldBlock(label: L10n.t("pref.title")) {
        TextField("e.g. Shorten this", text: $config.title)
          .textFieldStyle(.plain).font(.system(size: 13))
          .foregroundColor(.white.opacity(0.85))
      }

      fieldBlock(label: L10n.t("pref.instruction")) {
        TextEditor(text: $config.systemPrompt)
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.78))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 100)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Color").font(.system(size: 11, weight: .medium)).foregroundColor(prefMuted)
        HStack(spacing: 8) {
          ForEach(0..<PromptStore.palette.count, id: \.self) { i in
            Circle()
              .fill(PromptStore.palette[i].tint)
              .frame(width: 20, height: 20)
              .overlay(Circle().strokeBorder(Color.white, lineWidth: config.colorIndex == i ? 2 : 0))
              .onTapGesture { config.colorIndex = i }
          }
        }
      }

      Spacer()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel).buttonStyle(PrefSecondary())
        Button(isNew ? "Add" : "Save") { onSave(config) }
          .buttonStyle(PrefPrimary())
          .disabled(config.title.isEmpty || config.systemPrompt.isEmpty)
      }
    }
    .padding(24)
    .frame(width: 440, height: 400)
    .background(prefBg0)
    .environment(\.colorScheme, .dark)
  }

  private func fieldBlock<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(prefMuted)
      content()
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(prefBg1))
        .overlay(alignment: .center) { RoundedRectangle(cornerRadius: 8).stroke(prefBorder, lineWidth: 1) }
    }
  }
}

// MARK: - Shortcut view

private struct ShortcutView: View {
  let title: String
  let description: String
  @State private var keyCode: UInt32
  @State private var modifiers: UInt32
  private let saveHandler: (UInt32, UInt32) -> Void
  @State private var isRecording = false
  @State private var saved = false
  @State private var eventMonitor: Any? = nil

  init(title: String, description: String, keyCode: UInt32, modifiers: UInt32, onSave: @escaping (UInt32, UInt32) -> Void) {
    self.title = title
    self.description = description
    _keyCode   = State(initialValue: keyCode)
    _modifiers = State(initialValue: modifiers)
    self.saveHandler = onSave
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(description)
        .font(.system(size: 12))
        .foregroundColor(prefMuted)
        .padding(.horizontal, 20)
        .padding(.top, 20)

      HStack {
        Text(isRecording ? "Recording…" : shortcutLabel(keyCode: keyCode, modifiers: modifiers))
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(.white.opacity(isRecording ? 0.4 : 0.85))
          .frame(maxWidth: .infinity, alignment: .leading)
        Button(isRecording ? "Cancel" : "Click to record") {
          if isRecording { stopRecording() } else { startRecording() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundColor(prefAccent)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 12)
      .background(RoundedRectangle(cornerRadius: 8).fill(prefBg1))
      .overlay(alignment: .center) { RoundedRectangle(cornerRadius: 8).stroke(prefBorder, lineWidth: 1) }
      .padding(.horizontal, 20)
      .padding(.top, 12)

      Spacer()

      HStack {
        if saved {
          Text(L10n.t("pref.saved"))
            .font(.system(size: 12))
            .foregroundColor(prefMuted)
            .transition(.opacity)
        }
        Spacer()
        Button("Save") {
          saveHandler(keyCode, modifiers)
          withAnimation { saved = true }
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { saved = false }
          }
        }
        .buttonStyle(PrefPrimary())
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(width: 420, height: 260)
    .background(prefBg0)
    .navigationTitle(title)
    .onAppear { resizeWindow(to: CGSize(width: 420, height: 260)) }
    .onDisappear { stopRecording() }
  }

  private func startRecording() {
    isRecording = true
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == 53 { stopRecording(); return nil }  // Escape
      let mods = carbonModifiers(from: event.modifierFlags)
      guard mods != 0 else { return event }
      keyCode   = UInt32(event.keyCode)
      modifiers = mods
      stopRecording()
      return nil
    }
  }

  private func stopRecording() {
    isRecording = false
    if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
  }
}

// MARK: - Button styles

private struct PrefPrimary: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundColor(Color(red: 10/255, green: 10/255, blue: 20/255))
      .padding(.horizontal, 14).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 7).fill(prefAccent.opacity(configuration.isPressed ? 0.8 : 1)))
  }
}

private struct PrefSecondary: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundColor(.white.opacity(0.5))
      .padding(.horizontal, 14).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(configuration.isPressed ? 0.11 : 0.07)))
  }
}


// MARK: - Language

private struct LanguageView: View {
  @ObservedObject private var loc = LocaleStore.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(L10n.t("lang.title"))
          .font(.system(size: 15, weight: .semibold))
          .foregroundColor(.white)
        Text(L10n.t("lang.note"))
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.45))
      }
      .padding(.horizontal, 4)
      .padding(.bottom, 14)

      VStack(spacing: 0) {
        ForEach(Array(AppLanguage.allCases.enumerated()), id: \.element) { idx, lang in
          if idx > 0 { Divider().opacity(0.10).padding(.horizontal, 12) }
          Button {
            loc.language = lang
          } label: {
            HStack {
              Text(lang.displayName)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
              Spacer()
              if loc.language == lang {
                Image(systemName: "checkmark")
                  .font(.system(size: 12, weight: .bold))
                  .foregroundColor(prefAccent)
              }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .background(RoundedRectangle(cornerRadius: 10).fill(prefBg1))
    }
    .padding(20)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(prefBg0)
    .onAppear { resizeWindow(to: CGSize(width: 420, height: 300)) }
  }
}
