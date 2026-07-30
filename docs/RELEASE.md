# Quill 發佈流程

## 帳號核准前：Beta

```sh
./scripts/build-beta.sh landing/Quill.zip
```

這會建立 macOS 13+、Apple Silicon + Intel 的 ad-hoc 測試版，並驗證架構、
最低系統、Sparkle 設定與壓縮檔完整性。Beta 仍會顯示 Apple 的未識別開發者警告。

## 已完成的一次性準備

- Sparkle 2 已接入 App，選單列有「檢查更新」。
- Feed：`https://quill.morpheuschen.com/appcast.xml`
- Sparkle 公鑰已寫入 `Quill/Info.plist`。
- 私鑰只在 macOS Keychain，account：`com.morpheus.quill`。
- Release 已啟用 Hardened Runtime 與必要 entitlement。

請另外把 Sparkle 私鑰安全備份到密碼管理器或離線加密儲存；不要放進 git。

## Apple Developer Program 核准後：一次性設定

1. Xcode → Settings → Accounts → Manage Certificates，建立
   `Developer ID Application`。
2. 建立 app-specific password，保存公證憑證：

   ```sh
   xcrun notarytool store-credentials quill-notary \
     --apple-id <APPLE_ID> \
     --team-id <TEAM_ID> \
     --password <APP_SPECIFIC_PASSWORD>
   ```

3. Railway 設定正式金流的 `CHECKOUT_URL` 與 `PAYMENT_WEBHOOK_SECRET`。

## 每次正式發佈

```sh
TEAM_ID=<TEAM_ID> \
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (<TEAM_ID>)" \
NOTARY_PROFILE=quill-notary \
./scripts/build-release.sh 0.2.0 2
```

腳本會建立 Universal archive、Developer ID 簽章、送 Apple 公證、staple，再輸出：

```text
dist/Quill-0.2.0.zip
```

把檔案上傳到 GitHub Release 後，產生已簽名的 Sparkle feed：

```sh
./scripts/prepare-update.sh \
  dist/Quill-0.2.0.zip \
  https://github.com/morpheuschenai/quill/releases/download/v0.2.0
```

檢查 `landing/appcast.xml` 後 commit、push。最後用前一版 Quill 按
「檢查更新」，完成一次真實升級再公告。

## 發佈閘門

- [ ] `npm test` 全部通過
- [ ] Xcode unit tests 全部通過
- [ ] `./scripts/verify-app.sh <release.zip> --distribution` 通過
- [ ] `docs/CLEAN_INSTALL_QA.zh-TW.md` 全部完成
- [ ] 隱私政策、條款、退款政策與結帳畫面內容一致
- [ ] 前一版 → 新版 Sparkle 更新成功
