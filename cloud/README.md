# Quill Cloud

代理 Gemini 的極簡後端。App 免 API key,使用者開箱即用。

```
Quill App ──(共享密鑰 + 裝置ID)──▶ Cloudflare Worker ──(你的 Gemini key)──▶ Gemini Flash
                                        │
                                        ├ 共享密鑰驗證(擋非本 App 請求)
                                        ├ 裝置每日額度(KV,預設 20 次/天)
                                        └ 全域每日上限(KV,預設 5000 次/天,保護錢包)
```

真實金鑰只存在 Cloudflare Secret,永不進 App、不進 git。

## 首次部署(約 10 分鐘,免信用卡)

前置:一個 [Cloudflare 帳號](https://dash.cloudflare.com/sign-up)(免費)、一把 [Gemini API key](https://aistudio.google.com/apikey)。

```sh
cd cloud
npm install
npx wrangler login                       # 瀏覽器授權你的 Cloudflare 帳號

# 建立額度計數用的 KV,把輸出的 id 貼進 wrangler.toml 的 REPLACE_WITH_KV_ID
npx wrangler kv namespace create QUILL_KV

# 設兩個機密
npx wrangler secret put GEMINI_KEY       # 貼上 Gemini API key
npx wrangler secret put QUILL_APP_SECRET # 自訂一組長隨機字串,要和 App 內建值相同

npx wrangler deploy                      # 部署,得到 https://quill-cloud.<你的子網域>.workers.dev
```

把部署網址填進 App 端 `PromptStore.defaultCloudEndpoint`,把 `QUILL_APP_SECRET` 填進 App 端 `CloudConfig.appSecret`(見 App 專案)。

## 本機測試

```sh
cd cloud
npm install
# 建 .dev.vars 放本機機密(此檔已被 .gitignore 忽略):
printf 'GEMINI_KEY=你的key\nQUILL_APP_SECRET=test-secret-123\n' > .dev.vars
npx wrangler dev                         # 起在 http://localhost:8787
```

App 端把 Cloud endpoint 暫時指向 `http://localhost:8787/v1`、共享密鑰用 `test-secret-123`,即可測整條鏈路。

## 調整額度

改 `wrangler.toml` 的 `DAILY_LIMIT` / `GLOBAL_DAILY_CAP` / `GEMINI_MODEL` 後重新 `deploy`,不需改程式。

## 監控與煞車

- `npm run tail` 即時看請求日誌。
- 想立刻停止對外服務:Cloudflare 儀表板停用 Worker,或把 `GLOBAL_DAILY_CAP` 設成 `0` 後 deploy。
- Cloudflare 免費方案每日 100k 次請求;搭配 `GLOBAL_DAILY_CAP` 你的 Gemini 花費有硬上限。
