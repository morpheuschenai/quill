# Quill 發佈流程(Developer ID 直接發佈 + Sparkle 更新)

> 前置:Apple Developer Program 帳號、Xcode 已登入該帳號。
> 一次性設定做完後,之後每版只要跑「每次發佈」段落。

## 一次性設定

1. **Sparkle 金鑰**(在 Mac 上執行一次):
   ```sh
   # 從 DerivedData 或 SPM checkout 找到 Sparkle 的 bin/generate_keys
   ./generate_keys
   ```
   - 公鑰:填入 `Quill/Quill/Info.plist` 的 `SUPublicEDKey`
   - 私鑰:自動存入 Keychain(名稱 "Private key for signing Sparkle updates")。**絕不放進 git**
2. **Developer ID 憑證**:Xcode → Settings → Accounts → Manage Certificates → 建立「Developer ID Application」
3. **notarytool 憑證**:
   ```sh
   xcrun notarytool store-credentials quill-notary \
     --apple-id <APPLE_ID> --team-id <TEAM_ID> --password <app-specific-password>
   ```

## 每次發佈

1. 更新版號:`CFBundleShortVersionString`(如 0.2.0)與 `CFBundleVersion`(遞增整數)
2. Archive:Xcode → Product → Archive → Distribute App → Direct Distribution(Developer ID + 公證),匯出 Quill.app
3. 打包 DMG:
   ```sh
   brew install create-dmg
   create-dmg --volname "Quill" --app-drop-link 400 120 \
     --window-size 600 300 --icon Quill.app 150 120 \
     Quill-<版號>.dmg <匯出資料夾>/
   ```
4. 簽更新檔並產生 appcast:
   ```sh
   ./sign_update Quill-<版號>.dmg          # 輸出 edSignature 與 length
   ```
   把輸出填入 `landing/appcast.xml` 的新 `<item>`(範本見下),commit push——
   GitHub Pages 會部署到 https://quill.morpheuschen.com/appcast.xml
5. DMG 上傳到 GitHub Releases,`enclosure url` 指向該下載連結
6. 舊版 App 的「檢查更新…」應能看到新版 → 測試升級流程後再公告

## appcast.xml 範本

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Quill Updates</title>
    <item>
      <title>0.2.0</title>
      <pubDate>Wed, 01 Jan 2026 12:00:00 +0800</pubDate>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/morpheuschenai/quill/releases/download/v0.2.0/Quill-0.2.0.dmg"
        sparkle:edSignature="<sign_update 的輸出>"
        length="<sign_update 的輸出>"
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
```

## 發佈前檢查清單

- [ ] `SUPublicEDKey` 已填入 Info.plist
- [ ] README 隱私段落已更新(Cloud 版上線時)
- [ ] 完整跑過 docs/TEST_CHECKLIST.zh-TW.md
- [ ] DMG 在乾淨的使用者帳號測過:雙擊安裝 → onboarding → 權限 → 第一次截圖成功
