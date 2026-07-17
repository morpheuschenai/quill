# 新版體驗測試清單(⌘R 後逐項打勾)

> 這批改動我無法在你的 Mac 上編譯,若 Xcode 報錯,把錯誤訊息貼給我即可。

## 截圖流程(主打)
- [ ] `Ctrl+Opt+I` 框選一段畫面 → 動作選單出現在**滑鼠附近**(不是螢幕中央)
- [ ] 點「Extract text」→ 結果視窗打開,文字**逐字串流**出現(不再白屏等待)
- [ ] 結果視窗**不會自動消失**,要按 ✕ 才關
- [ ] 在視窗輸入框追問(例:「翻成英文」)→ 針對同一張截圖繼續回答
- [ ] 再截一張圖開新視窗 → **兩個視窗並存**,位置錯開
- [ ] 按「複製」→ 顯示「已複製」,貼上內容正確

## 文字流程
- [ ] TextEdit 選字 + `Ctrl+Opt+A` → 「Fix the text」→ 文字**原地被取代**(行為不變)
- [ ] Safari 網頁選字 + `Ctrl+Opt+A` → 「Summarize」→ 開串流視窗(不再是舊面板)
- [ ] 做完動作後,剪貼簿裡原本的內容**沒有被覆蓋**

## 錯誤處理
- [ ] Preferences 把 API key 改成錯的 → 執行動作 → 視窗內出現橘色錯誤條 + 「重試」
- [ ] 改回正確 key → 按「重試」→ 正常出結果
- [ ] 截圖按 Esc 取消 → 無任何反應(正確,不該跳錯誤)

## 成本驗證(可選)
- [ ] 截一張全螢幕 Retina 圖,到 OpenAI usage 頁面看該次請求 token 數
      (壓縮後長邊 ≤1568px、JPEG,應比之前的全解析度 PNG 低很多)

## 單元測試
```sh
xcodebuild test -project Quill/Quill.xcodeproj -scheme Quill \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
既有測試只用到未變動的函式,應全數通過。
