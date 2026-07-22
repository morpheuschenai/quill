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
  private static let table: [String: (String, String)] = [
    // 語言
    "lang.system": ("跟隨系統", "Follow system"),
    "lang.title": ("語言", "Language"),
    "lang.note": ("切換後介面立即更新", "Interface updates immediately"),

    // 偏好設定
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
    "pref.title": ("名稱", "Title"),
    "pref.instruction": ("指令", "Instruction"),
    "tab.screenshot": ("截圖", "Screenshot"),
    "tab.editable": ("可編輯文字", "Editable"),
    "tab.readonly": ("唯讀文字", "Read-only"),

    // 選單列
    "menu.preferences": ("偏好設定…", "Preferences…"),
    "menu.onboarding": ("設定引導…", "Setup Guide…"),
    "menu.checkUpdates": ("檢查更新…", "Check for Updates…"),
    "menu.quit": ("結束 Quill", "Quit Quill"),

    // Onboarding — 共用
    "ob.back": ("上一步", "Back"),
    "ob.next": ("下一步", "Next"),
    "ob.skip": ("略過", "Skip"),
    "ob.start": ("開始使用 Quill", "Start using Quill"),
    "ob.relaunch": ("已勾選,重新啟動 Quill", "Granted — restart Quill"),

    // Onboarding — 歡迎
    "ob.welcome.title": ("歡迎使用 Quill", "Welcome to Quill"),
    "ob.welcome.sub": ("對你看到的任何東西,直接跟 AI 互動。", "Ask AI about anything you can see."),
    "ob.welcome.shot.title": ("截圖問 AI", "Ask AI about your screen"),
    "ob.welcome.shot.desc": ("框選畫面 → 萃取文字、翻譯、解釋,結果當場出現",
                             "Frame any area → extract text, translate, explain — answers appear right there"),
    "ob.welcome.text.title": ("選字改文字", "Rewrite selected text"),
    "ob.welcome.text.desc": ("選取文字 → 修正、改語氣、翻譯,直接取代原文",
                             "Select text → fix, change tone, translate — replaced in place"),
    "ob.welcome.hint": ("快捷鍵可隨時在偏好設定修改", "Shortcuts can be changed in Preferences"),

    // Onboarding — 輔助使用
    "ob.ax.title": ("允許「輔助使用」", "Allow Accessibility"),
    "ob.ax.why": ("Quill 需要這個權限才能讀取你選取的文字,並在原位置替換結果。我們只讀取你主動選取的內容,其他一概不碰。",
                  "Quill needs this to read your selected text and replace it in place. It only ever reads what you actively select."),
    "ob.ax.how": ("點下方按鈕 → 在系統設定找到 Quill → 打開開關",
                  "Click below → find Quill in System Settings → turn the switch on"),
    "ob.ax.button": ("開啟輔助使用設定", "Open Accessibility settings"),

    // Onboarding — 螢幕錄製
    "ob.screen.title": ("允許「螢幕錄製」", "Allow Screen Recording"),
    "ob.screen.why": ("截圖功能需要這個權限,否則拍到的畫面不會包含視窗內容。截圖只在你按下快捷鍵時發生,且只送往 AI 服務取得回覆。",
                      "Screenshots need this, otherwise captures won't include window contents. Capture only happens when you press the hotkey."),
    "ob.screen.how": ("點下方按鈕 → 在系統設定勾選 Quill → 回到這裡按「重新啟動」。",
                      "Click below → check Quill in System Settings → come back and click Restart."),
    "ob.screen.button": ("開啟螢幕錄製設定", "Open Screen Recording settings"),

    // Onboarding — 權限共用
    "ob.perm.done": ("設定完成,可以進入下一步。", "All set — you can continue."),
    "ob.perm.copyPath": ("清單裡沒有 Quill?複製 App 路徑", "Quill not in the list? Copy app path"),
    "ob.perm.copied": ("已複製,到設定按「+」貼上路徑", "Copied — click + in Settings and paste"),

    // Onboarding — 試試看
    "ob.try.title": ("現在試一次", "Try it now"),
    "ob.try.sub": ("按下快捷鍵,把下面這句英文框起來,看 AI 怎麼回你。",
                   "Press the hotkey and frame the sentence below to see what AI does."),
    "ob.try.sample": ("The quarterly report shows a 23% increase in recurring revenue.",
                      "The quarterly report shows a 23% increase in recurring revenue."),
    "ob.try.hint": ("→ 拖曳框選上面那句話", "→ then drag to frame the sentence above"),
    "ob.try.pickAction": ("已框選!在彈出的選單挑一個動作,例如「翻譯」",
                          "Framed! Now pick an action from the menu — try Translate"),
    "ob.try.done": ("成功了!", "Nice — it works!"),
    "ob.try.doneSub": ("這就是 Quill:看到什麼都能框起來問。在任何 App 都能這樣用。",
                       "That's Quill: frame anything you see and ask. Works in every app."),

    // Onboarding — 完成
    "ob.ready.title": ("一切就緒,免費開通", "You're all set — free to use"),
    "ob.ready.sub": ("Quill Cloud 已為你開通,直接開始截圖問 AI。",
                     "Quill Cloud is activated. Start asking AI about your screen."),
    "ob.ready.quota": ("每天 10 次免費額度,每日重置", "10 free uses per day, resets daily"),
    "ob.ready.privacy": ("內容不留存、不訓練", "Your content is never stored or used for training"),
    "ob.ready.advanced": ("進階:想改用自己的 API key?到選單列 → 偏好設定 切換即可。",
                          "Advanced: prefer your own API key? Switch it in Preferences."),

    // 結果視窗
    "result.followUp": ("追問…", "Ask a follow-up…"),
    "result.copy": ("複製", "Copy"),
    "result.copied": ("已複製", "Copied"),
    "result.thinking": ("思考中…", "Thinking…"),
    "result.retry": ("重試", "Retry"),
    "result.empty": ("沒有收到回應,請再試一次。", "No response received. Please try again."),

    // 動作選單
    "menu.custom": ("自訂指令…", "Custom instruction…"),

    // 預設動作名稱
    "action.fixText": ("修正文字", "Fix the text"),
    "action.makeFormal": ("改成正式語氣", "Make it formal"),
    "action.translate": ("翻譯", "Translate"),
    "action.summarize": ("摘要", "Summarize"),
    "action.explain": ("解釋這是什麼", "Explain this"),
    "action.listActions": ("列出待辦事項", "List action items"),
    "action.extractText": ("擷取文字", "Extract text"),
    "action.describe": ("描述畫面", "Describe this"),

    // 錯誤
    "err.screenshotRead": ("截圖讀取失敗,請再試一次。", "Failed to read the screenshot. Please try again."),
    "err.screenshotLaunch": ("無法啟動截圖工具:", "Couldn't start the screenshot tool: "),
    "err.noKey": ("尚未設定 API key。到偏好設定加入,或改用 Quill Cloud。",
                  "No API key set. Add one in Preferences, or use Quill Cloud."),
    "err.invalidKey": ("API key 無效,請到偏好設定檢查。", "Invalid API key. Check it in Preferences."),
    "err.rateLimited": ("請求太頻繁,稍後再試。", "Rate limited. Try again in a moment."),
    "err.service": ("AI 服務暫時無法回應,請稍後再試。", "AI service is unavailable. Please try again later."),
    "err.tooLong": ("選取的內容太長,試試選短一點。", "Selection is too long. Try a shorter passage."),
  ]
}
