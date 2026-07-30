import Foundation
import Combine
import SwiftUI

// MARK: - Quill Cloud 設定

enum CloudConfig {
  /// 正式版只允許連到這個 HTTPS 端點。
  /// Debug 版可用 UserDefaults 覆寫做本機測試:
  /// `defaults write com.morpheus.quill quill_cloud_endpoint http://localhost:8787/v1`
  static let endpoint = "https://quill-production-ba4a.up.railway.app/v1"

  /// 每次安裝產生一次的隨機 ID。後端只保存其 HMAC，不保存原始值。
  static var installationID: String {
    let key = "quill_installation_id"
    if let v = UserDefaults.standard.string(forKey: key) { return v }
    let v = UUID().uuidString
    UserDefaults.standard.set(v, forKey: key)
    return v
  }
}

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
  /// 預設動作的本地化 key(使用者自訂的動作為 nil,顯示 title 原文)
  var titleKey: String?

  init(
    id: UUID = UUID(),
    title: String,
    titleKey: String? = nil,
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
    self.titleKey = titleKey
  }
}

// MARK: - Store

class PromptStore: ObservableObject {
  static let shared = PromptStore()

  @Published var editablePrompts: [PromptConfig]
  @Published var nonEditablePrompts: [PromptConfig]
  @Published var screenshotPrompts: [PromptConfig]
  @Published private(set) var shortcutRevision = 0

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

  // MARK: - Quill Cloud（免 key 開箱即用;進階用戶可關掉改自帶 key）

  /// 預設走 Cloud。關閉後改用自帶 API key(apiEndpoint + apiKey)。
  var useCloud: Bool {
    get {
      // 尚未設定過 → 預設 true
      (UserDefaults.standard.object(forKey: "quill_use_cloud") as? Bool) ?? true
    }
    set { UserDefaults.standard.set(newValue, forKey: "quill_use_cloud") }
  }

  /// Cloud endpoint。只有 Debug build 可被 UserDefaults 覆寫。
#if DEBUG
  var cloudEndpoint: String {
    get {
      let v = UserDefaults.standard.string(forKey: "quill_cloud_endpoint") ?? ""
      return v.isEmpty ? CloudConfig.endpoint : v
    }
    set { UserDefaults.standard.set(newValue, forKey: "quill_cloud_endpoint") }
  }
#else
  var cloudEndpoint: String { CloudConfig.endpoint }
#endif

  // Text selection hotkey — Ctrl(4096) + Option(2048) = 6144, kVK_ANSI_A = 0
  var textKeyCode: UInt32 {
    get {
      guard let v = UserDefaults.standard.object(forKey: "quill_text_hotkey_keycode") as? Int
      else { return 0 }
      return UInt32(v)
    }
    set {
      UserDefaults.standard.set(Int(newValue), forKey: "quill_text_hotkey_keycode")
      shortcutRevision &+= 1
    }
  }

  var textModifiers: UInt32 {
    get {
      guard let v = UserDefaults.standard.object(forKey: "quill_text_hotkey_modifiers") as? Int
      else { return 6144 }
      return UInt32(v)
    }
    set {
      UserDefaults.standard.set(Int(newValue), forKey: "quill_text_hotkey_modifiers")
      shortcutRevision &+= 1
    }
  }

  // Screenshot hotkey — Ctrl(4096) + Option(2048) = 6144, kVK_ANSI_Q = 12
  var screenshotKeyCode: UInt32 {
    get {
      guard let v = UserDefaults.standard.object(forKey: "quill_hotkey_keycode") as? Int
      else { return 12 }
      return UInt32(v)
    }
    set {
      UserDefaults.standard.set(Int(newValue), forKey: "quill_hotkey_keycode")
      shortcutRevision &+= 1
    }
  }

  var screenshotModifiers: UInt32 {
    get {
      guard let v = UserDefaults.standard.object(forKey: "quill_hotkey_modifiers") as? Int
      else { return 6144 }
      return UInt32(v)
    }
    set {
      UserDefaults.standard.set(Int(newValue), forKey: "quill_hotkey_modifiers")
      shortcutRevision &+= 1
    }
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

  // v6: 非中文內容改成翻譯至使用者選擇的 App／系統語言。
  private static let storageVersion = "v6"
  private static var editableKey:    String { "quill_prompts_editable_\(storageVersion)" }
  private static var nonEditableKey: String { "quill_prompts_noneditable_\(storageVersion)" }
  private static var screenshotKey:  String { "quill_prompts_screenshot_\(storageVersion)" }

  private init() {
    editablePrompts = Self.load(
      key: Self.editableKey,
      legacyKeys: ["quill_prompts_editable_v5", "quill_prompts_editable_v4"],
      defaults: Self.defaultEditable
    )
    nonEditablePrompts = Self.load(
      key: Self.nonEditableKey,
      legacyKeys: ["quill_prompts_noneditable_v5", "quill_prompts_noneditable_v4"],
      defaults: Self.defaultNonEditable
    )
    screenshotPrompts = Self.load(
      key: Self.screenshotKey,
      legacyKeys: ["quill_prompts_screenshot_v5", "quill_prompts_screenshot_v4"],
      defaults: Self.defaultScreenshot
    )
    save()
  }

  func save() {
    Self.persist(editablePrompts,    key: Self.editableKey)
    Self.persist(nonEditablePrompts, key: Self.nonEditableKey)
    Self.persist(screenshotPrompts,  key: Self.screenshotKey)
  }

  private static func load(
    key: String,
    legacyKeys: [String],
    defaults: [PromptConfig]
  ) -> [PromptConfig] {
    if let data = UserDefaults.standard.data(forKey: key),
       let configs = try? JSONDecoder().decode([PromptConfig].self, from: data) {
      return configs
    }
    let legacy = legacyKeys.lazy.compactMap { legacyKey -> [PromptConfig]? in
      guard let data = UserDefaults.standard.data(forKey: legacyKey) else { return nil }
      return try? JSONDecoder().decode([PromptConfig].self, from: data)
    }.first
    guard let legacy else { return defaults }

    // 保留使用者自訂與排序，只替換已知有問題的內建「翻譯」提示。
    return legacy.map { old in
      guard
        old.titleKey == "action.translate",
        var replacement = defaults.first(where: { $0.titleKey == "action.translate" })
      else { return old }
      replacement.id = old.id
      return replacement
    }
  }

  private static func persist(_ configs: [PromptConfig], key: String) {
    if let data = try? JSONEncoder().encode(configs) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }

  func toPrompt(_ c: PromptConfig) -> Prompt {
    let pair = Self.palette[c.colorIndex % Self.palette.count]
    let prompt = Self.promptRespectingAppLanguage(c.systemPrompt, titleKey: c.titleKey)
    return Prompt(
      title: c.titleKey.map { L10n.t($0) } ?? c.title,
      systemPrompt: prompt,
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

  /// 介面選擇繁體中文時，說明、摘要與自訂動作預設使用繁體中文。
  /// 翻譯、OCR、校對與改寫必須遵守原任務的輸出語言，因此不追加這條規則。
  static func promptRespectingAppLanguage(_ prompt: String, titleKey: String?) -> String {
    if titleKey == "action.translate" {
      let target = TranslationLanguageStore.shared.language.promptName
      return prompt + "\nTARGET_LANGUAGE: \(target)"
    }
    guard LocaleStore.shared.isZh else { return prompt }
    let preservesOrChoosesLanguage: Set<String> = [
      "action.extractText", "action.fixText", "action.makeFormal",
    ]
    guard titleKey == nil || !preservesOrChoosesLanguage.contains(titleKey!) else {
      return prompt
    }
    return prompt + "\nRespond in Traditional Chinese (繁體中文). Never use Simplified Chinese."
  }
}

// MARK: - Default configs

extension PromptStore {
  static let defaultEditable: [PromptConfig] = [
    PromptConfig(
      title: "Fix the text", titleKey: "action.fixText",
      systemPrompt: """
        You are a meticulous copy editor. Rewrite the user's text following ALL of these rules:
        - Correct EVERY spelling mistake and grammar error — including words inside quotes 「」"", brackets, or after arrows. Example: 「Fixinng the text」 must become 「Fixing the text」.
        - Remove filler words (um, uh, like, you know, basically, actually) and redundant repetition.
        - CRITICAL: preserve the exact language AND script of each part. Traditional Chinese (繁體字) must stay Traditional Chinese — NEVER convert it to Simplified Chinese. English stays English. Never translate anything.
        - Preserve all symbols and formatting exactly: markdown like **bold**, arrows →, brackets, quotes, line breaks.
        - Do not add new content. Keep meaning, tone, and length.
        - If a part is already correct, keep it character-for-character identical.
        Output ONLY the corrected text — no explanation, no added quotes, no code fences.
        """,
      maxTokens: 400, iconName: "fix_text", colorIndex: 1
    ),
    PromptConfig(
      title: "Make it formal", titleKey: "action.makeFormal",
      systemPrompt: "Rewrite the following text in a more formal, professional tone. Return only the rewritten text, no explanation.",
      maxTokens: 300, iconName: "make_formal", colorIndex: 3
    ),
    PromptConfig(
      title: "Translate", titleKey: "action.translate",
      systemPrompt: """
        Translate the following text according to these mandatory rules:
        - Traditional or Simplified Chinese input MUST be translated into natural English.
        - Never return Chinese when the input is Chinese.
        - Any other language MUST be translated into TARGET_LANGUAGE, supplied below.
        Return only the translated text. Do not explain, summarize, or repeat the source.
        """,
      maxTokens: 400, iconName: "translate", colorIndex: 2
    ),
  ]

  static let defaultNonEditable: [PromptConfig] = [
    PromptConfig(title: "Summarize", titleKey: "action.summarize",       systemPrompt: "Summarize the key points of the following text in bullet points. Be concise.",                                                                                                                        maxTokens: 500, iconName: "summarize",    colorIndex: 0),
    PromptConfig(title: "Explain this", titleKey: "action.explain",    systemPrompt: "Explain the following text in simple, plain language as if explaining to someone unfamiliar with the topic.",                                                                                         maxTokens: 500, iconName: "explain",      colorIndex: 4),
    PromptConfig(title: "Translate", titleKey: "action.translate",       systemPrompt: "Translate the following text according to these mandatory rules:\n- Traditional or Simplified Chinese input MUST be translated into natural English.\n- Never return Chinese when the input is Chinese.\n- Any other language MUST be translated into TARGET_LANGUAGE, supplied below.\nReturn only the translated text. Do not explain, summarize, or repeat the source.", maxTokens: 400, iconName: "translate",    colorIndex: 2),
    PromptConfig(title: "List action items", titleKey: "action.listActions", systemPrompt: "Extract all action items, tasks, and to-dos from the following text. Format as a bullet list.",                                                                                                     maxTokens: 300, iconName: "list-actions", colorIndex: 5),
  ]

  static let defaultScreenshot: [PromptConfig] = [
    PromptConfig(title: "Extract text", titleKey: "action.extractText",  systemPrompt: "Extract all visible text from this screenshot exactly as it appears, preserving structure and line breaks. Output plain text ONLY — never wrap the result in markdown, code fences (```), or quotes.", maxTokens: 800, iconName: "fix_text",  colorIndex: 1, autoCopy: true),
    PromptConfig(title: "Describe this", titleKey: "action.describe", systemPrompt: "Describe what you see in this screenshot concisely. Include layout, content, and any key information.",                                                                                                 maxTokens: 500, iconName: "explain",   colorIndex: 4),
    PromptConfig(title: "Summarize", titleKey: "action.summarize",     systemPrompt: "Summarize the key information visible in this screenshot in bullet points.",                                                                                                                            maxTokens: 400, iconName: "summarize", colorIndex: 0),
    PromptConfig(title: "Translate", titleKey: "action.translate",     systemPrompt: "Translate all visible text in this screenshot. Chinese text MUST become natural English; never return Chinese for Chinese source text. Any other language MUST become TARGET_LANGUAGE, supplied below. Return only the translated text, preserving the visible structure.", maxTokens: 600, iconName: "translate", colorIndex: 2),
  ]
}
