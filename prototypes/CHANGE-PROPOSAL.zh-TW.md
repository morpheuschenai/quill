# Quill 修改提案（確認後才執行）

> 狀態：提案，不包含正式程式、網站或 Railway 變更。

## 建議執行順序

1. 修正公開下載檔的系統與 CPU 相容性。
2. 修正 Cloud 額度安全與計數方式。
3. 建立匿名指標與升級意願漏斗。
4. 修復 Sparkle 更新流程。
5. 更新官網平台標示與隱私說明。
6. 隔離測試環境並增加發佈檢查。

---

## A. 公開 ZIP 與官網相容性聲明不符

### 現況

- 公開 ZIP 最低需求是 macOS 26.4。
- 執行檔只有 `arm64`。
- 官網宣稱 macOS 13+、Intel 與 Apple Silicon 都支援。

### 建議修改

- 將 App 與測試 target 的 Deployment Target 統一設為 macOS 13.0。
- 以 Release / Archive 產生 Universal binary（`arm64 + x86_64`）。
- 使用 Developer ID Application 簽章並完成 Apple notarization。
- 發佈前自動驗證：
  - `LSMinimumSystemVersion == 13.0`
  - `lipo -archs` 同時包含 `arm64` 與 `x86_64`
  - `codesign --verify --deep --strict`
  - `spctl` 驗證通過
- 重新產生並上傳 ZIP 或 DMG。

### 驗收

- macOS 13、目前最新版 macOS 各測一次。
- Apple Silicon 與 Intel Mac 各測一次；若沒有 Intel 實機，至少先做 Universal binary 與 CI 驗證。

---

## B. 每日額度可透過更換裝置 ID 繞過

### 現況

- 共用密鑰存在公開客戶端中，不能視為真正的秘密。
- 裝置 ID 是可自行修改的 UserDefaults UUID。

### 建議修改

- 立即輪替目前已公開的 Cloud 密鑰。
- 新增安裝註冊端點，由伺服器簽發每個安裝實例的 token。
- 伺服器同時套用：
  - installation token 限額
  - IP / 網段的溫和 rate limit
  - 全域成本硬上限
- 分析用途只保存 `HMAC(serverSalt, installationID)`，不保存原始裝置 ID。
- 未來建立帳號／訂閱後，以帳號 entitlement 作為正式付費額度來源。

### 注意

純客戶端資訊都能被逆向；免費 beta 可以提高濫用成本，但不能靠 App 內的共享密鑰建立真正身分。

---

## C. 無效或失敗請求也會消耗額度

### 現況

Redis 計數發生在 request body 驗證與 OpenAI 呼叫之前。

### 建議修改

- 先完成 Authorization、device token、JSON schema 與必要欄位驗證。
- 只有準備真正送往上游的請求才增加額度。
- 將用量拆成兩種：
  - `attempted_upstream`：確實送往 OpenAI 的請求
  - `completed`：成功取得結果
- 免費額度採 `attempted_upstream`，因為請求送出後通常已產生成本。
- 本機驗證失敗、Redis 失敗、未送到 OpenAI 的連線失敗不扣額度。
- `quota_reached` 只在 `deviceUsed === limit + 1` 時記錄一次，重試不重複統計。

---

## D. 台灣使用者於早上 8 點換日

### 建議修改

- Railway 新增 `QUOTA_TIME_ZONE=Asia/Taipei`。
- Redis day key 使用明確產品時區產生。
- 429 response 一併回傳 `resets_at` ISO timestamp。
- App 顯示「明天 00:00 重置」或依 timestamp 顯示實際時間。

---

## E. Sparkle 自動更新無法使用

### 現況

- `appcast.xml` 回傳 404。
- `SUPublicEDKey` 尚未設定。

### 建議修改

- 產生 Sparkle EdDSA 金鑰，私鑰只存 Keychain。
- 將公鑰加入 App Info.plist。
- 建立並部署 `landing/appcast.xml`。
- 每次 Release 自動簽署更新檔並更新 appcast。
- 發佈前從前一版 App 實測「檢查更新 → 下載 → 安裝 → 重啟」。
- 在流程完成前，暫時隱藏「檢查更新」選單，避免提供壞掉的功能。

---

## F. 隱私說明與 Cloud 現況不一致

### 建議修改

README 與官網改為明確說明：

- 預設 Quill Cloud 會透過 Railway proxy 將請求送往 OpenAI。
- 不儲存截圖、選取文字、Prompt 或 AI 回覆。
- 只收集匿名、彙總的產品事件。
- 說明事件名稱、用途、保存期限與退出方式。
- 自帶 API Key 模式是否繞過 Quill Cloud，需依實際程式行為明確描述。

---

## G. 測試會受本機語言偏好影響

### 建議修改

- 測試開始前固定 locale，結束後恢復。
- 錯誤處理測試優先驗證 error code 與語意 key，不直接比對目前 UI 語言的英文片段。
- 新增測試：
  - 第 10 次成功、第 11 次 429
  - Retry 不增加 `quota_reached` unique count
  - 無效 JSON 不扣額度
  - UTC 跨日但台北尚未跨日時不重置
  - Release artifact 的最低系統版本與 CPU architectures

---

## H. 匿名使用指標與購買意願

### 建議收集的事件

| 事件 | 觸發時機 | 是否唯一計數 |
|---|---|---|
| `app_active` | 每日第一次成功 Cloud 請求 | 每裝置／每日一次 |
| `quota_reached` | 第一次超過每日限額 | 每裝置／每日一次 |
| `upgrade_clicked` | 點擊「查看升級方案」 | 每裝置／每日一次 |
| `checkout_started` | 進入付款流程 | 每 checkout 一次 |
| `purchase_completed` | 付款 webhook 確認 | 每訂單一次 |

### 不收集

- 截圖或圖片
- 選取文字
- Prompt
- AI 回覆
- API Key

### 儲存方式

- 原始裝置 ID 先經伺服器 HMAC 後才用於去重。
- Redis 使用每日 Set 去重、每日 Hash 保存彙總。
- 匿名事件最多保留 90 天；長期只留每日總數。
- 若日後需要 cohort、留存分析，再移至專用分析資料庫。

### 在哪裡查看

- 建議網址：`https://quill.morpheuschen.com/admin/metrics`
- 必須登入或使用伺服器端 admin session，不把管理 token 放在前端。
- 頁面包含：
  - 活躍裝置
  - 達到每日限額的唯一裝置
  - 升級意願
  - 完成購買
  - 每日趨勢
  - 限額 → 意願 → 購買漏斗
- Prototype：`prototypes/metrics-dashboard.html`

---

## I. 官網清楚標示 Mac-only

### 建議修改

- 頁面最上方加入「Mac 專用 App」公告。
- 品牌標示改為「Quill for Mac」。
- 主標第一句直接出現「在你的 Mac 上」。
- 所有下載 CTA 改為「下載 Quill for Mac」或「免費下載 Mac 版」。
- CTA 下方立即列出 macOS 版本與 CPU 支援，不只放在 FAQ。
- 手機瀏覽時：
  - 不顯示可直接安裝的錯誤暗示
  - 顯示「Quill 需要安裝在 Mac 上」
  - 提供「寄送／複製 Mac 下載連結」
- Open Graph description 也加入「Mac App」，避免朋友從 LINE、Messenger 預覽時誤會。

### 上線前依賴

必須先完成 A 的 Release 相容性修正，才能聲稱「macOS 13+、Intel + Apple Silicon」。

### Prototype

`prototypes/macos-only-landing.html`

