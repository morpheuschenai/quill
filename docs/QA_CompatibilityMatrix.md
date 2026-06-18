# Quill — App Compatibility Test Matrix

## 測試前準備
1. 啟動 Quill（確認選單列有 sparkles icon）
2. 每個 app 測試完填寫結果欄位
3. 結果代碼：✅ 全通 / ⚠️ 部分可用 / ❌ 完全失效

## 執行紀錄

### 2026-05-28 Codex computer-use 嘗試

- 狀態：第一次嘗試未執行 Tier 2-6，原因是工具層判斷不完整。
- 修正說明：Quill 是 menu bar-only / `LSUIElement` app，可能不會出現在 Computer Use app list，也沒有一般 key window 可供 `get_app_state("Quill")` attach；這不代表 Quill 沒啟動。
- 後續測試方式：不直接 attach Quill，改 attach 目標 app（例如 VS Code、Chrome、Preview），用截圖與座標驗證 floating icon、popover、ResultPanel。
- 注意：若需要檢查選單列 Quill 狀態，應以視覺截圖或 SystemUIServer/menu bar 為準。

### 2026-05-28 Tier 1 人工 smoke test

- TextEdit：✅ pass
- Notes：✅ pass
- Mail：✅ pass
- Messages：⚠️ partial，在輸入框測試時 icon / processing 會出現，但最終結果沒有替換回輸入框
- Reminders：✅ pass
- Calendar：✅ pass
- Pages：未安裝
- Keynote：未安裝
- Numbers：未安裝
- 補充：pass 案例在第 9 步完成後 icon 會自動消失，不需要額外點到別處，符合預期體驗。

## 測試步驟（每個 app 重複）
1. 打開目標 app，確認 Quill 偵測到 app 切換
2. 選取 5+ 個字的文字
3. 確認 floating icon 是否出現 → 填 **Icon**
4. 點擊 icon，選擇「Fix grammar」
5. 觀察結果是否正確取代或開 ResultPanel → 填 **Result**
6. 若失敗，記錄症狀 → 填 **備註**

---

## Tier 1 — Native macOS Apps（預期全通）

| App | Icon 出現 | 結果正確 | 取代方式 | 備註 |
|-----|-----------|---------|---------|------|
| TextEdit | ✅ | ✅ | AX write | 第 9 步後 icon 自動消失 |
| Notes | ✅ | ✅ | Paste | 第 9 步後 icon 自動消失 |
| Pages | N/A | N/A | | 未安裝 |
| Keynote（文字方塊）| N/A | N/A | | 未安裝 |
| Numbers（cell）| N/A | N/A | | 未安裝 |
| Mail（寫信視窗）| ✅ | ✅ | | 第 9 步後 icon 自動消失 |
| Messages | ✅ | ❌ | | 輸入框可觸發 processing，但最終結果沒有替換回輸入框 |
| Reminders | ✅ | ✅ | | 第 9 步後 icon 自動消失 |
| Calendar（備註欄）| ✅ | ✅ | | 第 9 步後 icon 自動消失 |

---

## Tier 2 — Electron / Third-party Apps（預期 paste fallback）

| App | Icon 出現 | 結果正確 | 取代方式 | 備註 |
|-----|-----------|---------|---------|------|
| VS Code | | | Paste | |
| Slack | | | Paste | |
| Notion desktop | | | Paste | |
| Discord | | | Paste | |
| Figma（文字層）| | | | |
| Linear | | | | |
| Obsidian | | | | |
| 1Password | | | | |

---

## Tier 3 — Microsoft Office

| App | Icon 出現 | 結果正確 | 取代方式 | 備註 |
|-----|-----------|---------|---------|------|
| Word | | | | |
| Outlook（寫信）| | | | |
| PowerPoint（文字方塊）| | | | |
| Excel（cell）| | | | |

---

## Tier 4 — Browsers（唯讀，預期開 ResultPanel）

| App | Icon 出現 | ResultPanel 出現 | 備註 |
|-----|-----------|----------------|------|
| Safari（網頁文字）| | | |
| Chrome（網頁文字）| | | |
| Firefox（網頁文字）| | | |
| Arc（網頁文字）| | | |
| Safari（input 欄位）| | | 可編輯？ |
| Chrome（input 欄位）| | | 可編輯？ |

---

## Tier 5 — PDF / 唯讀內容

| App | Icon 出現 | ResultPanel 出現 | 備註 |
|-----|-----------|----------------|------|
| Preview（PDF）| | | |
| Preview（圖片中的文字）| | | |
| Books | | | |
| Adobe Acrobat | | | |

---

## Tier 6 — 開發 / 終端機

| App | Icon 出現 | 結果 | 備註 |
|-----|-----------|------|------|
| Xcode（程式碼）| | | |
| Terminal（選取輸出）| | | |
| iTerm2 | | | |

---

## 常見失敗模式對照表

| 症狀 | 可能原因 | 分類 |
|------|---------|------|
| Icon 完全不出現 | AX 無法取得 focused element | ❌ 不支援 |
| Icon 出現但點擊後沒反應 | AX element 失效（選取已消失）| ⚠️ timing 問題 |
| 結果取代成上一次的剪貼簿內容 | Paste fallback 但 clipboard 沒清 | ⚠️ bug |
| ResultPanel 出現但內容錯誤 | API 回傳問題 | ⚠️ API |
| Icon 出現在錯誤位置 | 鼠標位置 offset | ⚠️ UI |
| Icon 不消失 | global click monitor 未觸發 | ⚠️ bug |

---

## 結果匯總（測試完填）

| Tier | 通過 | 部分 | 失敗 | 備註 |
|------|------|------|------|------|
| Tier 1 Native | 6/7 installed | 1/7 installed | 0/7 installed | Pages/Keynote/Numbers 未安裝；Messages processing 後未替換 |
| Tier 2 Electron | /8 | /8 | /8 | |
| Tier 3 Office | /4 | /4 | /4 | |
| Tier 4 Browsers | /6 | /6 | /6 | |
| Tier 5 PDF | /4 | /4 | /4 | |
| Tier 6 Dev | /3 | /3 | /3 | |
