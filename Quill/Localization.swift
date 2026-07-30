import Foundation
import Combine
import SwiftUI

/// App 語言。跟隨系統時依系統偏好判斷是否為中文。
enum AppLanguage: String, CaseIterable {
  case system, zhHant = "zh-Hant", en

  var displayName: String {
    switch self {
    case .system: return L10n.t("lang.system")
    case .zhHant: return "繁體中文"
    case .en:     return "English"
    }
  }

  /// 實際生效的語言(system 會解析成 zhHant 或 en)
  var resolved: AppLanguage {
    guard self == .system else { return self }
    let pref = Locale.preferredLanguages.first ?? "en"
    return pref.hasPrefix("zh") ? .zhHant : .en
  }
}

/// 翻譯的預設目標語言，刻意與介面／系統語言分開。
/// 中文來源仍固定翻成英文；非中文來源才使用這個偏好。
enum TranslationLanguage: String, CaseIterable {
  case zhHant = "zh-Hant", en

  var displayName: String {
    switch self {
    case .zhHant: return "繁體中文"
    case .en:     return "English"
    }
  }

  var promptName: String {
    switch self {
    case .zhHant: return "Traditional Chinese (繁體中文)"
    case .en:     return "English"
    }
  }
}

/// 記錄引導「試試看」頁的進度。
/// 只有「AI 真的回覆完成」才算成功——光是框選還沒體驗到價值。
final class UsageTracker: ObservableObject {
  static let shared = UsageTracker()
  /// 已框選截圖(進行中)
  @Published var didCaptureOnce = false
  /// 已收到 AI 的完整回覆(真正的成功)
  @Published var didCompleteOnce = false
  private init() {}

  func markCaptured() {
    DispatchQueue.main.async { self.didCaptureOnce = true }
  }

  func markCompleted() {
    DispatchQueue.main.async { self.didCompleteOnce = true }
  }
}

/// 語言設定中心。切換時發出 objectWillChange,SwiftUI 介面即時重繪。
final class LocaleStore: ObservableObject {
  static let shared = LocaleStore()
  private static let key = "quill_app_language"

  @Published var language: AppLanguage {
    didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.key) }
  }

  private init() {
    let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppLanguage.system.rawValue
    language = AppLanguage(rawValue: raw) ?? .system
  }

  var isZh: Bool { language.resolved == .zhHant }
}

final class TranslationLanguageStore: ObservableObject {
  static let shared = TranslationLanguageStore()
  private static let key = "quill_translation_language"
  private static let onboardingDoneKey = "quill_onboarding_done_v1"

  @Published var language: TranslationLanguage {
    didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.key) }
  }

  private init() {
    let defaults = UserDefaults.standard
    if let raw = defaults.string(forKey: Self.key),
       let saved = TranslationLanguage(rawValue: raw) {
      language = saved
      return
    }

    // 既有使用者第一次升級時沿用目前介面語言；全新安裝預設繁體中文。
    if defaults.bool(forKey: Self.onboardingDoneKey) {
      language = LocaleStore.shared.language.resolved == .zhHant ? .zhHant : .en
    } else {
      language = .zhHant
    }
    defaults.set(language.rawValue, forKey: Self.key)
  }
}

/// 極簡本地化:L10n.t("key") 依目前語言回傳字串。
/// 用自訂表而非 .strings,是為了讓「切換語言」即時生效、不需重啟 App。
enum L10n {
  static func t(_ key: String) -> String {
    let zh = LocaleStore.shared.isZh
    guard let pair = table[key] else { return key }
    return zh ? pair.0 : pair.1
  }

  /// 帶參數版本:L10n.t("quota.used", 10)
  static func t(_ key: String, _ args: CVarArg...) -> String {
    String(format: t(key), arguments: args)
  }

  // key: (繁體中文, English)
  /// 拆成多個小字典再合併——單一大型字典字面值會讓 Swift 型別檢查逾時。
  private static let table: [String: (String, String)] = {
    var t: [String: (String, String)] = [:]
    for d in [g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12, g13, g14, g15] { t.merge(d) { a, _ in a } }
    return t
  }()

  // 語言
  private static let g1: [String: (String, String)] = [
    "lang.system": ("跟隨系統", "Follow system"),
    "lang.title": ("語言", "Language"),
    "lang.interface": ("介面語言", "Interface language"),
    "lang.interface.note": ("切換後介面立即更新", "The interface updates immediately"),
    "lang.translation": ("預設翻譯語言", "Default translation language"),
    "lang.translation.note": ("非中文內容會翻成這個語言；中文固定翻成英文",
                              "Non-Chinese content translates to this language; Chinese always translates to English"),
    "lang.onboarding.choose": ("顯示語言", "Display language"),
  ]

  // 偏好設定
  private static let g2: [String: (String, String)] = [
    "pref.provider": ("AI 服務與 API Key", "Provider & API Key"),
    "pref.prompts": ("動作與提示", "Prompts"),
    "pref.textShortcut": ("選字快捷鍵", "Text Shortcut"),
    "pref.textShortcut.desc": ("設定在任何 App 叫出選字選單的快捷鍵。",
                               "Set the shortcut to trigger the text selection menu in any app."),
    "pref.shotShortcut": ("截圖快捷鍵", "Screenshot Shortcut"),
    "pref.shotShortcut.desc": ("設定在任何 App 啟動截圖框選的快捷鍵。",
                               "Set the shortcut to start an interactive screenshot capture."),
    "pref.providerLabel": ("服務商", "Provider"),
    "pref.endpoint": ("端點網址", "Endpoint"),
    "pref.model": ("模型", "Model"),
    "pref.apiKey": ("API Key", "API Key"),
    "pref.keyNote": ("儲存在本機 Keychain。使用 Ollama 時不需填。",
                     "Stored locally in Keychain. Not required for Ollama."),
    "pref.saved": ("已儲存", "Saved"),
    "pref.shortcutConflict": ("快捷鍵已被其他 App 使用", "Shortcut is already in use"),
    "pref.title": ("名稱", "Title"),
    "pref.instruction": ("指令", "Instruction"),
    "pref.advanced": ("進階設定", "Advanced"),
    "billing.title": ("方案與用量", "Plan & Usage"),
    "billing.free": ("免費", "Free"),
    "billing.freePlan": ("免費方案", "Free plan"),
    "billing.remaining": ("次可用", "uses left"),
    "billing.dailyReset": ("每日自動重置", "Resets daily"),
    "billing.resetsIn": ("重置於", "Resets in"),
    "billing.offerBadge": ("8/31 前限定", "ENDS AUG 31"),
    "billing.offerTitle": ("首月 NT$149", "First month NT$149"),
    "billing.offerDetail": ("第 2 個月起 NT$199／月，可隨時取消。優惠只適用第一個計費週期。",
                            "Then NT$199/month. Cancel anytime. The offer applies to your first billing cycle only."),
    "billing.regularTitle": ("NT$199／月", "NT$199/month"),
    "billing.regularDetail": ("每月自動續訂，可隨時取消。", "Renews monthly. Cancel anytime."),
    "billing.proQuota": ("每個計費週期 600 次", "600 uses per billing cycle"),
    "billing.upgrade": ("安全升級至 Pro", "Upgrade securely to Pro"),
    "billing.secure": ("由 Portaly 安全處理付款 · Quill 不保存卡號", "Secure payment by Portaly · Quill never stores card details"),
    "billing.renews": ("訂閱將以 NT$199／月自動續訂，可在下方管理。", "Renews at NT$199/month. Manage it below."),
    "billing.cancelPending": ("已取消自動續訂；Pro 可使用到目前計費週期結束。", "Renewal canceled. Pro stays active until the current period ends."),
    "billing.manage": ("管理訂閱與付款紀錄", "Manage subscription & payments"),
    "billing.error": ("暫時無法讀取方案，請稍後再試。", "Unable to load your plan. Please try again."),
    "pref.intro.screenshot": ("按下截圖快捷鍵、框選畫面後,會出現這些動作。",
                              "Actions shown after you capture a screen area."),
    "pref.intro.editable": ("在可輸入的地方(信件、備忘錄、輸入框)選取文字時,會出現這些動作。結果直接取代原文。",
                            "Actions shown when you select text in an editable field. Results replace the text in place."),
    "pref.intro.readonly": ("在不能編輯的地方(網頁、PDF)選取文字時,會出現這些動作。結果顯示在浮動視窗。",
                            "Actions shown when you select text in read-only content. Results appear in a floating window."),
    "pref.addPrompt": ("新增動作", "Add Prompt"),
    "pref.editPrompt": ("編輯動作", "Edit Prompt"),
    "pref.color": ("顏色", "Color"),
    "tab.screenshot": ("截圖", "Screenshot"),
    "tab.editable": ("可編輯文字", "Editable"),
    "tab.readonly": ("唯讀文字", "Read-only"),
  ]

  // 選單列
  private static let g3: [String: (String, String)] = [
    "menu.open": ("開啟 Quill", "Open Quill"),
    "menu.preferences": ("偏好設定", "Preferences"),
    "menu.onboarding": ("設定引導", "Setup Guide"),
    "menu.checkUpdates": ("檢查更新", "Check for Updates"),
    "menu.updateAvailable": ("有可用更新", "Update Available"),
    "menu.quit": ("結束 Quill", "Quit Quill"),
  ]

  // Onboarding — 共用
  private static let g4: [String: (String, String)] = [
    "ob.back": ("上一步", "Back"),
    "ob.next": ("下一步", "Next"),
    "ob.skip": ("略過", "Skip"),
    "ob.start": ("開始使用 Quill", "Start using Quill"),
    "ob.relaunch": ("重新啟動", "Restart"),
  ]

  // Onboarding — 歡迎
  private static let g5: [String: (String, String)] = [
    "ob.welcome.title": ("歡迎使用 Quill", "Welcome to Quill"),
    "ob.welcome.sub": ("框選畫面或文字，直接問 AI。", "Ask AI about your screen or selected text."),
    "ob.welcome.shot.title": ("截圖問 AI", "Ask AI about your screen"),
    "ob.welcome.shot.desc": ("框選畫面，立即取得答案",
                             "Frame any area and get an answer"),
    "ob.welcome.text.title": ("選字改文字", "Rewrite selected text"),
    "ob.welcome.text.desc": ("選取文字，直接修正或翻譯",
                             "Select text to rewrite or translate it"),
    "ob.welcome.hint": ("快捷鍵可隨時在偏好設定修改", "Shortcuts can be changed in Preferences"),
  ]

  // Onboarding — 輔助使用
  private static let g6: [String: (String, String)] = [
    "ob.ax.title": ("允許「輔助使用」", "Allow Accessibility"),
    "ob.ax.why": ("讓 Quill 讀取並處理你主動選取的文字。",
                  "Lets Quill work with text you select."),
    "ob.ax.how": ("開啟設定，找到 Quill 並打開開關。",
                  "Open Settings and turn on Quill."),
    "ob.ax.retry": ("若 Quill 已開啟但仍未偵測：先關閉再開啟。仍無效時，按「−」移除 Quill，再用「+」重新加入。",
                    "If Quill is already on, turn it off and on. If it still is not detected, remove Quill with −, then add it again with +."),
    "ob.ax.button": ("開啟輔助使用設定", "Open Accessibility settings"),
  ]

  // Onboarding — 螢幕錄製
  private static let g7: [String: (String, String)] = [
    "ob.screen.title": ("允許「螢幕錄製」", "Allow Screen Recording"),
    "ob.screen.why": ("讓 Quill 擷取你主動框選的畫面。",
                      "Lets Quill capture the area you select."),
    "ob.screen.how": ("在系統設定開啟 Quill，然後回來重新啟動。",
                      "Turn on Quill in Settings, then return and restart."),
    "ob.screen.button": ("開啟螢幕錄製設定", "Open Screen Recording settings"),
    "ob.screen.buttonAgain": ("重新開啟螢幕錄製設定", "Open Screen Recording settings again"),
    "ob.screen.openFirst": ("請先開啟上方設定", "Open the settings above first"),
    "ob.screen.notDetected": ("尚未偵測到權限", "Permission not detected"),
    "ob.screen.retry": ("重新啟動後仍未偵測到權限。請再次開啟設定，確認 Quill 的開關已打開。",
                        "Permission was not detected after restart. Open Settings again and make sure Quill is enabled."),
    "ob.screen.finishing": ("完成系統授權…", "Finishing setup…"),
  ]

  // Onboarding — 權限共用
  private static let g8: [String: (String, String)] = [
    "ob.perm.done": ("完成", "Ready"),
    "ob.perm.copyPath": ("清單裡沒有 Quill？複製 App 路徑", "Quill not in the list? Copy app path"),
    "ob.perm.copied": ("已複製 App 路徑", "App path copied"),
    "ob.perm.copyHelp": ("在系統設定按「+」→ 在檔案選擇視窗按 Command + Shift + G → 貼上路徑 → 選擇 Quill",
                         "In Settings click + → in the file picker press Command + Shift + G → paste the path → select Quill"),
  ]

  // Onboarding — 試試看
  private static let g9: [String: (String, String)] = [
    "ob.try.title": ("現在試一次", "Try it now"),
    "ob.try.sub": ("用快捷鍵框選下面這句話。",
                   "Use the shortcut to frame the sentence below."),
    "ob.try.sample": ("The quarterly report shows a 23% increase in recurring revenue.",
                      "The quarterly report shows a 23% increase in recurring revenue."),
    "ob.try.hint": ("拖曳框選上面的句子", "Drag to frame the sentence above"),
    "ob.try.pickAction": ("選一個動作，例如「翻譯」",
                          "Choose an action, such as Translate"),
    "ob.try.done": ("成功", "It works"),
    "ob.try.doneSub": ("現在你可以在任何 App 使用 Quill。",
                       "Quill is ready in every app."),
  ]

  // Onboarding — 完成
  private static let g10: [String: (String, String)] = [
    "ob.ready.title": ("Quill 已就緒", "Quill is ready"),
    "ob.ready.sub": ("開始框選畫面，直接問 AI。",
                     "Frame anything and ask AI."),
    "ob.ready.quota": ("每天 10 次免費額度,每日重置", "10 free uses per day, resets daily"),
    "ob.ready.privacy": ("內容不留存、不訓練", "Your content is never stored or used for training"),
    "ob.ready.advanced": ("進階:想改用自己的 API key?到選單列 → 偏好設定 切換即可。",
                          "Advanced: prefer your own API key? Switch it in Preferences."),
  ]

  // 結果視窗
  private static let g11: [String: (String, String)] = [
    "result.followUp": ("追問…", "Ask a follow-up…"),
    "result.copy": ("複製", "Copy"),
    "result.copied": ("已複製", "Copied"),
    "result.thinking": ("思考中…", "Thinking…"),
    "result.retry": ("重試", "Retry"),
    "result.upgrade": ("查看升級方案", "View upgrade options"),
    "result.empty": ("沒有收到回應,請再試一次。", "No response received. Please try again."),
  ]

  // 動作選單
  private static let g12: [String: (String, String)] = [
    "menu.custom": ("自訂指令…", "Custom instruction…"),
  ]

  // 預設動作名稱
  private static let g13: [String: (String, String)] = [
    "action.fixText": ("修正文字", "Fix the text"),
    "action.makeFormal": ("改成正式語氣", "Make it formal"),
    "action.translate": ("翻譯", "Translate"),
    "action.summarize": ("摘要", "Summarize"),
    "action.explain": ("解釋這是什麼", "Explain this"),
    "action.listActions": ("列出待辦事項", "List action items"),
    "action.extractText": ("擷取文字", "Extract text"),
    "action.describe": ("描述畫面", "Describe this"),
  ]

  // 錯誤
  private static let g14: [String: (String, String)] = [
    "err.screenshotRead": ("截圖讀取失敗,請再試一次。", "Failed to read the screenshot. Please try again."),
    "err.screenshotLaunch": ("無法啟動截圖工具:", "Couldn't start the screenshot tool: "),
    "err.noKey": ("尚未設定 API key。到偏好設定加入,或改用 Quill Cloud。",
                  "No API key set. Add one in Preferences, or use Quill Cloud."),
    "err.invalidKey": ("API key 無效,請到偏好設定檢查。", "Invalid API key. Check it in Preferences."),
    "err.rateLimited": ("請求太頻繁,稍後再試。", "Rate limited. Try again in a moment."),
    "err.service": ("AI 服務暫時無法回應,請稍後再試。", "AI service is unavailable. Please try again later."),
    "err.tooLong": ("選取的內容太長,試試選短一點。", "Selection is too long. Try a shorter passage."),
    "err.cloudActivation": ("Quill Cloud 啟用失敗，請確認網路後再試一次。",
                            "Quill Cloud activation failed. Check your connection and try again."),
  ]

  // Dock 首頁
  private static let g15: [String: (String, String)] = [
    "home.capture": ("截圖問 AI", "Ask AI with a screenshot"),
    "home.captureHint": ("框選你想了解的畫面", "Select an area you want to understand"),
    "home.textSelection": ("處理選取文字", "Work with selected text"),
    "home.textHint": ("翻譯、改寫或摘要選取內容", "Translate, rewrite, or summarize selected text"),
    "home.freeUsage": ("今日免費用量", "Free usage today"),
    "home.proUsage": ("本期 Pro 用量", "Pro usage this period"),
    "home.remaining": ("剩餘 %d 次", "%d remaining"),
    "home.resetsDays": ("%d 天 %d 小時後重置", "Resets in %dd %dh"),
    "home.resetsHours": ("%d 小時 %d 分後重置", "Resets in %dh %dm"),
    "home.resetsMinutes": ("%d 分後重置", "Resets in %dm"),
    "home.ready": ("已在背景待命", "Ready in the background"),
    "home.preferences": ("偏好設定", "Settings"),
  ]
}
