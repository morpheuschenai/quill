import Foundation
import Combine
import SwiftUI

// MARK: - Data model

struct PromptConfig: Codable, Identifiable {
  var id: UUID
  var title: String
  var systemPrompt: String
  var maxTokens: Int
  var iconName: String
  var colorIndex: Int
  /// 完成後自動把結果複製到剪貼簿(OCR 情境用);optional 以相容舊資料
  var autoCopy: Bool?

  init(
    id: UUID = UUID(),
    title: String,
    systemPrompt: String,
    maxTokens: Int = 400,
    iconName: String = "custom-text",
    colorIndex: Int = 0,
    autoCopy: Bool? = nil
  ) {
    self.id = id
    self.title = title
    self.systemPrompt = systemPrompt
    self.maxTokens = maxTokens
    self.iconName = iconName
    self.colorIndex = colorIndex
    self.autoCopy = autoCopy
  }
}

// MARK: - Store

class PromptStore: ObservableObject {
  static let shared = PromptStore()

  @Published var editablePrompts: [PromptConfig]
  @Published var nonEditablePrompts: [PromptConfig]
  @Published var screenshotPrompts: [PromptConfig]

  // 存於 Keychain（KeychainStore 會自動搬移舊版 UserDefaults 明文 key）
  var apiKey: String {
    get { KeychainStore.apiKey }
    set { KeychainStore.apiKey = newValue }
  }

  // MARK: - Models（之後可加進 Preferences UI）

  static let defaultTextModel   = "gpt-4o-mini"
  static let defaultVisionModel = "gpt-4o"

  var textModel: String {
    get {
      let v = UserDefaults.standard.string(forKey: "quill_text_model") ?? ""
      return v.isEmpty ? Self.defaultTextModel : v
    }
    set { UserDefaults.standard.set(newValue, forKey: "quill_text_model") }
  }

  var visionModel: String {
    get {
      let v = UserDefaults.standard.string(forKey: "quill_vision_model") ?? ""
      return v.isEmpty ? Self.defaultVisionModel : v
    }
    set { UserDefaults.standard.set(newValue, forKey: "quill_vision_model") }
  }

  static let defaultEndpoint = "https://api.openai.com/v1"

  var apiEndpoint: String {
    get {
      let v = UserDefaults.standard.string(forKey: "quill_api_endpoint") ?? ""
      return v.isEmpty ? Self.defaultEndpoint : v
    }
    set { UserDefaults.standard.set(newValue, forKey: "quill_api_endpoint") }
  }

  // Text selection hotkey — Ctrl(4096) + Option(2048) = 6144, kVK_ANSI_A = 0
  var textKeyCode: UInt32 {
    get {
      guard let v = UserDefaults.standard.object(forKey: "quill_text_hotkey_keycode") as? Int
      else { return 0 }
      return UInt32(v)
    }
    set { UserDefaults.standard.set(Int(newValue), forKey: "quill_text_hotkey_keycode") }
  }

  var textModifiers: UInt32 {
    get {
      guard let v = UserDefaults.standard.object(forKey: "quill_text_hotkey_modifiers") as? Int
      else { return 6144 }
      return UInt32(v)
    }
    set { UserDefaults.standard.set(Int(newValue), forKey: "quill_text_hotkey_modifiers") }
  }

  // Screenshot hotkey — Ctrl(4096) + Option(2048) = 6144, kVK_ANSI_I = 34
  var screenshotKeyCode: UInt32 {
    get {
      guard let v = UserDefaults.standard.object(forKey: "quill_hotkey_keycode") as? Int
      else { return 34 }
      return UInt32(v)
    }
    set { UserDefaults.standard.set(Int(newValue), forKey: "quill_hotkey_keycode") }
  }

  var screenshotModifiers: UInt32 {
    get {
      guard let v = UserDefaults.standard.object(forKey: "quill_hotkey_modifiers") as? Int
      else { return 6144 }
      return UInt32(v)
    }
    set { UserDefaults.standard.set(Int(newValue), forKey: "quill_hotkey_modifiers") }
  }

  // 6-colour palette: index maps to (iconTint, iconBackground)
  static let palette: [(tint: Color, bg: Color)] = [
    (Color(red: 96/255,  green: 165/255, blue: 250/255), Color(red: 96/255,  green: 165/255, blue: 250/255).opacity(0.15)), // 0 blue
    (Color(red: 52/255,  green: 211/255, blue: 153/255), Color(red: 52/255,  green: 211/255, blue: 153/255).opacity(0.15)), // 1 green
    (Color(red: 167/255, green: 139/255, blue: 250/255), Color(red: 167/255, green: 139/255, blue: 250/255).opacity(0.15)), // 2 purple
    (Color(red: 251/255, green: 191/255, blue: 36/255),  Color(red: 251/255, green: 191/255, blue: 36/255).opacity(0.12)),  // 3 yellow
    (Color(red: 34/255,  green: 211/255, blue: 238/255), Color(red: 34/255,  green: 211/255, blue: 238/255).opacity(0.15)), // 4 cyan
    (Color(red: 251/255, green: 146/255, blue: 60/255),  Color(red: 251/255, green: 146/255, blue: 60/255).opacity(0.12)),  // 5 orange
  ]

  // v2:2026-07 prompt 品質修正(Fix the text 強化、OCR 禁用 markdown、autoCopy)
  // 換 key 讓既有安裝拿到新預設;舊自訂 prompt 不遷移(此階段可接受)
  private init() {
    editablePrompts    = Self.load(key: "quill_prompts_editable_v2",    defaults: Self.defaultEditable)
    nonEditablePrompts = Self.load(key: "quill_prompts_noneditable_v2", defaults: Self.defaultNonEditable)
    screenshotPrompts  = Self.load(key: "quill_prompts_screenshot_v2",  defaults: Self.defaultScreenshot)
  }

  func save() {
    Self.persist(editablePrompts,    key: "quill_prompts_editable_v2")
    Self.persist(nonEditablePrompts, key: "quill_prompts_noneditable_v2")
    Self.persist(screenshotPrompts,  key: "quill_prompts_screenshot_v2")
  }

  private static func load(key: String, defaults: [PromptConfig]) -> [PromptConfig] {
    guard let data = UserDefaults.standard.data(forKey: key),
          let configs = try? JSONDecoder().decode([PromptConfig].self, from: data)
    else { return defaults }
    return configs
  }

  private static func persist(_ configs: [PromptConfig], key: String) {
    if let data = try? JSONEncoder().encode(configs) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }

  func toPrompt(_ c: PromptConfig) -> Prompt {
    let pair = Self.palette[c.colorIndex % Self.palette.count]
    return Prompt(
      title: c.title,
      systemPrompt: c.systemPrompt,
      iconName: c.iconName,
      maxTokens: c.maxTokens,
      iconTint: pair.tint,
      iconBackground: pair.bg,
      autoCopy: c.autoCopy ?? false
    )
  }

  var editableAsPrompts: [Prompt]    { editablePrompts.map(toPrompt) }
  var nonEditableAsPrompts: [Prompt] { nonEditablePrompts.map(toPrompt) }
  var screenshotAsPrompts: [Prompt]  { screenshotPrompts.map(toPrompt) }
}

// MARK: - Default configs

extension PromptStore {
  static let defaultEditable: [PromptConfig] = [
    PromptConfig(
      title: "Fix the text",
      systemPrompt: """
        You are a meticulous copy editor. Rewrite the user's text with these rules:
        - Correct EVERY spelling mistake and grammar error.
        - Remove filler words (um, uh, like, you know, basically, actually, just) and redundant repetition.
        - Keep the original language, meaning, tone, and approximate length. Do not add new content.
        - If the text is already correct, return it unchanged.
        Output ONLY the corrected text — no explanation, no quotes, no markdown.
        """,
      maxTokens: 400, iconName: "fix_text", colorIndex: 1
    ),
    PromptConfig(
      title: "Make it formal",
      systemPrompt: "Rewrite the following text in a more formal, professional tone. Return only the rewritten text, no explanation.",
      maxTokens: 300, iconName: "make_formal", colorIndex: 3
    ),
    PromptConfig(
      title: "Translate",
      systemPrompt: """
        Detect the language of the following text.
        - If it is Chinese (Traditional or Simplified), translate it to English.
        - If it is English or any other language, translate it to Traditional Chinese.
        Return only the translation, no explanation.
        """,
      maxTokens: 400, iconName: "translate", colorIndex: 2
    ),
  ]

  static let defaultNonEditable: [PromptConfig] = [
    PromptConfig(title: "Summarize",       systemPrompt: "Summarize the key points of the following text in bullet points. Be concise.",                                                                                                                        maxTokens: 500, iconName: "summarize",    colorIndex: 0),
    PromptConfig(title: "Explain this",    systemPrompt: "Explain the following text in simple, plain language as if explaining to someone unfamiliar with the topic.",                                                                                         maxTokens: 500, iconName: "explain",      colorIndex: 4),
    PromptConfig(title: "Translate",       systemPrompt: "Detect the language of the following text.\n- If it is Chinese (Traditional or Simplified), translate it to English.\n- If it is English or any other language, translate it to Traditional Chinese.\nReturn only the translation, no explanation.", maxTokens: 400, iconName: "translate",    colorIndex: 2),
    PromptConfig(title: "List action items", systemPrompt: "Extract all action items, tasks, and to-dos from the following text. Format as a bullet list.",                                                                                                     maxTokens: 300, iconName: "list-actions", colorIndex: 5),
  ]

  static let defaultScreenshot: [PromptConfig] = [
    PromptConfig(title: "Extract text",  systemPrompt: "Extract all visible text from this screenshot exactly as it appears, preserving structure and line breaks. Output plain text ONLY — never wrap the result in markdown, code fences (```), or quotes.", maxTokens: 800, iconName: "fix_text",  colorIndex: 1, autoCopy: true),
    PromptConfig(title: "Describe this", systemPrompt: "Describe what you see in this screenshot concisely. Include layout, content, and any key information.",                                                                                                 maxTokens: 500, iconName: "explain",   colorIndex: 4),
    PromptConfig(title: "Summarize",     systemPrompt: "Summarize the key information visible in this screenshot in bullet points.",                                                                                                                            maxTokens: 400, iconName: "summarize", colorIndex: 0),
    PromptConfig(title: "Translate",     systemPrompt: "Detect the language of the text in this screenshot. If Chinese, translate to English. If English or other, translate to Traditional Chinese. Return only the translation.",                             maxTokens: 600, iconName: "translate", colorIndex: 2),
  ]
}
