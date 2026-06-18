# Quill — Phase 0 Setup

## 在 Xcode 建立專案（一次性設定）

### Step 1：建立新專案
1. 打開 Xcode → File → New → Project
2. 選 **macOS → App**
3. 填入：
   - Product Name: `Quill`
   - Bundle Identifier: `com.morpheus.quill`
   - Interface: `SwiftUI`
   - Language: `Swift`
4. 存到 `/Users/morpheus/Documents/Claude/Quill/`（覆蓋現有資料夾）

### Step 2：替換預設檔案
1. 刪除 Xcode 預設建立的 `ContentView.swift`
2. 把 `Sources/Quill/` 裡的所有 `.swift` 檔拖進 Xcode 的檔案列表
3. 把 `Sources/Quill/Info.plist` 拖進去（Xcode 13+ 預設不建 Info.plist，需手動加）

### Step 3：設定 Info.plist
1. 在 Xcode 左側點選 Project → Target → Info
2. 確認有加入：
   - `NSAccessibilityUsageDescription`（內容已在 Info.plist 裡）
   - `LSUIElement` = YES

### Step 4：設定 Entitlements
1. Target → Signing & Capabilities
2. 點「+」→ 取消勾選 App Sandbox（Phase 0 先關掉）
3. 勾選 Network → Outgoing Connections (Client)

### Step 5：填入 OpenAI API Key
打開 `OpenAIService.swift`，找到這行：
```swift
private let apiKey = "YOUR_OPENAI_API_KEY_HERE"
```
換成你的真實 API key。

---

## 驗收測試（Phase 0 目標）

跑起來後，在以下 4 個 app 選取文字，確認浮動圖示出現：

| App | 預期行為 | Editable? |
|---|---|---|
| TextEdit | 圖示出現，點選後文字被取代 | ✅ 是 |
| Notes | 圖示出現，點選後文字被取代 | ✅ 是 |
| Safari（網頁文章） | 圖示出現，結果在浮動視窗顯示 | ❌ 否 |
| PDF（預覽程式） | 圖示出現，結果在浮動視窗顯示 | ❌ 否 |

如果 Chrome / Notion 有問題，是預期內的（這些 app 的 Accessibility 支援較複雜，Phase 1 再處理）。

---

## 檔案結構

```
Sources/Quill/
├── QuillApp.swift          # @main entry point
├── AppDelegate.swift       # App 生命週期、menu bar、權限檢查
├── AccessibilityMonitor.swift  # 核心：偵測文字選取
├── FloatingIconPanel.swift     # 浮動圖示 + popover
├── PromptListView.swift        # Prompt 選單 UI
├── Prompt.swift                # 預設 prompt 定義
├── OpenAIService.swift         # API 呼叫（Phase 0 hardcoded key）
├── ResultPanel.swift           # 不可編輯文字的結果視窗
├── Info.plist
└── Quill.entitlements
```
