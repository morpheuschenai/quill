# Quill — AI 動作，就在你需要的地方

在任何 Mac App 選取文字，按快捷鍵，直接修正、翻譯或摘要 — 不需要離開你正在用的 App。

<!-- 截圖待補：![Quill 選單](docs/screenshot.png) -->

**Quill Cloud**（即將推出）— 不需 API Key，不需任何技術設定。[加入候補名單 →](https://tally.so/r/68VMRP)

**開放原始碼**— 自備 API Key，自行編譯。說明如下。

[English](README.md)

---

## 如何運作

1. **選取文字** — 在任何 App 都行，Mail、備忘錄、Chrome、Slack、PDF 皆支援。
2. **按 Control + Option + A** — Quill 選單直接彈出在選取文字旁。
3. **選一個動作** — 可編輯的文字直接在原位改寫；唯讀內容則顯示在浮動面板。

## 功能

- **就地改寫** — 修文法、改語氣、翻譯，直接取代選取的文字。
- **分析任何內容** — 對網頁、PDF、唯讀文字做摘要、解釋或擷取待辦事項。
- **截圖 AI** — 按 Control+Option+I，框選畫面區域，擷取文字或描述內容。
- **自訂 Prompt** — 在偏好設定加入任意數量的自訂動作與 system prompt。

## 兩種使用方式

### Quill Cloud · 即將推出

下載後雙擊即可安裝。不需 API Key、不需 Xcode、不需任何技術設定。

[加入候補名單 →](https://tally.so/r/68VMRP) — 前 50 位會員獲贈一個月免費使用。

### 開放原始碼 · 現在可用

自備 API Key，完全掌控，MIT 授權，每行程式碼都可在 GitHub 查核。

需要 Xcode + Apple Developer 帳號。編譯說明如下。

---

## 從原始碼建立

```sh
git clone https://github.com/morpheuschenai/quill.git
open quill/Quill/Quill.xcodeproj
```

1. Build and run（**⌘R**）。
2. 依提示開啟**輔助使用**權限 — 系統設定 → 隱私權與安全性 → 輔助使用。
3. 開啟偏好設定（menu bar 圖示 → Preferences），貼上你的 [OpenAI API Key](https://platform.openai.com/api-keys)。

## 設定

| 項目 | 預設 | 位置 |
|---|---|---|
| 文字動作快捷鍵 | Control+Option+A | 偏好設定 |
| 截圖快捷鍵 | Control+Option+I | 偏好設定 |
| 文字模型 | `gpt-4o-mini` | `defaults write com.morpheus.quill quill_text_model <model>` |
| Vision 模型 | `gpt-4o` | `defaults write com.morpheus.quill quill_vision_model <model>` |

Quill 支援任何 OpenAI 相容端點 — OpenAI、Groq、OpenRouter，或本機 Ollama。

## 隱私

Quill 沒有自己的伺服器。你的選取內容直接送到你設定的 AI 模型，不經任何中間站。

- **零追蹤。** 沒有使用數據、沒有分析、什麼紀錄都不收集。
- **API Key 存在 macOS Keychain。** 不會被記錄或傳送。
- **剪貼板安全。** 若透過剪貼板備援讀取文字，完成後自動還原原本的內容。

## 已知限制

- 少數 App 既不提供 Accessibility 資訊、也擋掉模擬複製，這類 App 無法觸發。
- 唯讀情境（PDF、瀏覽器頁面）的結果顯示在浮動面板，不會取代原文。
- Chrome 及 Electron App 的就地改寫目前會退回結果面板。

## 開發

```sh
xcodebuild test -project Quill/Quill.xcodeproj -scheme Quill \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

QA 紀錄與相容性矩陣見 [docs/](docs/)。

## 授權

[MIT](LICENSE)
