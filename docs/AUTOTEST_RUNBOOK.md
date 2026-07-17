# Quill 自動測試執行手冊(給新的 Cowork session)

> 給 Claude:使用者會要求你「照這份手冊自動測試 Quill」。請先完整讀完再動作。
> 測試執行請委派給低成本子代理(Agent tool, model: haiku),把本手冊的「測試步驟」整段貼進子代理 prompt;若子代理連續卡關兩次,由你(主模型)接手該步驟。

## 背景(30 秒看懂)

- Quill = macOS 選單列 App:選取文字或截圖 → 快捷鍵 → AI 動作 → 結果串流顯示在浮動視窗。
- 這次要驗證的是剛完成的改版:**串流輸出、多視窗、視窗內追問、圖片壓縮、錯誤重試、剪貼簿不被覆蓋**。
- App 已安裝在 **/Applications/Quill.app**(選單列圖示是 ✨,無 Dock 圖示)。
- 完整驗收清單:`docs/TEST_CHECKLIST.zh-TW.md`。上一個 session 已驗證:建置成功、可啟動。

## 前置(主模型做,不要給子代理)

1. `request_access`:**Quill、TextEdit、Preview、Finder、System Settings**(一次全要)。
   - 上個 session 的教訓:App 清單是 session 開始時的快照,所以這次 Quill 應該可以直接授權;若仍失敗,停下來告訴使用者,不要繞路。
2. 確認 Quill 在跑:選單列有 ✨ 圖示。沒有就 `open_application("Quill")`。
3. **權限檢查**:請使用者確認系統設定 → 隱私權與安全性 → 「輔助使用」和「螢幕錄製」都已勾選 /Applications 的 Quill(App 移過位置,舊授權可能失效)。這步需要使用者親手操作。
4. API key:Preferences 裡應已有(存於 Keychain)。若測試時報 key 錯誤,請使用者處理,不要碰 key 本身。

## 測試步驟(可整段交給 haiku 子代理)

每步都:執行 → 截圖 → 對照「預期」→ 記錄 PASS/FAIL + 一句話證據。

### T1 截圖 → 串流結果視窗
1. 按 `ctrl+alt+i`,畫面出現框選游標後,用 left_click_drag 框選螢幕上任一段有文字的區域(例如 Finder 視窗標題附近,約 400×200)。
2. 預期:滑鼠附近彈出動作選單(Extract text / Describe this / Summarize / Translate + 輸入框)。
3. 點 **Extract text**。
4. 預期:標題為 Extract text 的深色浮動視窗打開,文字**逐字增加**(連拍兩張截圖間隔 1 秒,內容應變多)→ 這就是串流。
5. 完成後視窗**不會自動消失**。

### T2 追問
1. 在 T1 視窗底部輸入框點一下,輸入「翻成英文」按 Enter。
2. 預期:出現使用者訊息泡泡,接著新的串流回覆(針對同一張截圖)。

### T3 多視窗
1. 不關 T1 視窗,重複 T1 用不同區域,點 **Summarize**。
2. 預期:第二個視窗打開,位置與第一個錯開,兩個同時存在。

### T4 複製鈕
1. 在任一結果視窗點「複製」。
2. 預期:按鈕短暫變成「已複製」。(有 clipboardRead 權限才驗證內容,否則看按鈕狀態即可)

### T5 文字流程(可編輯,原地取代)
1. 開 TextEdit 新文件,輸入:`this is a test sentnce with a typo.`
2. `cmd+a` 全選 → 按 `ctrl+alt+a`。
3. 預期:彈出選單(Fix the text / Make it formal / Translate)。
4. 點 **Fix the text**;預期:選單顯示 loading 後,TextEdit 裡的文字**直接被改正**,不開結果視窗。

### T6 文字流程(唯讀 → 串流視窗)
1. 用 Preview 開任一 PDF(Finder 裡找,或請使用者提供),選取一段文字。
2. 按 `ctrl+alt+a` → 點 **Summarize**。
3. 預期:開串流結果視窗(不是取代)。

### T7 剪貼簿保護
1. 在 TextEdit 打 `MARKER123`,選取後 `cmd+c`。
2. 跑一次 T6(或 T1)。
3. 回 TextEdit `cmd+v`;預期:貼出的是 `MARKER123`,沒被結果覆蓋。

### T8 取消截圖
1. 按 `ctrl+alt+i` → 按 `escape`。
2. 預期:安靜取消,無錯誤視窗。

### 錯誤處理測試(需使用者配合,子代理跳過)
把 API key 改成錯的 → 任一動作 → 視窗內應出現橘色錯誤條 + 重試鈕;改回後按重試應成功。

## 已知環境注意事項

- Xcode 是 click tier:只能點,不能打字。不需要動 Xcode,測試全程用 /Applications 的 Quill。
- 瀏覽器是 read tier:不要用 Safari/Chrome 當測試素材,用 TextEdit 和 Preview。
- Quill 面板彈出時 Quill 是 frontmost:所以 Quill 必須在授權清單內,否則所有點擊都會被擋。
- 測試中畫面上可能有使用者的個人文件,不要讀取或評論其內容。

## 結果回報格式

| # | 測試 | 結果 | 證據(一句話) |
|---|---|---|---|
| T1 | 截圖串流視窗 | PASS/FAIL | … |

FAIL 的項目附截圖說明,回報到對話裡;全部跑完後把結果表寫入 `docs/TEST_RESULTS_<日期>.md` 並 commit。
