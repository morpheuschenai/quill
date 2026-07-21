# Quill Cloud

代理 AI 的後端(部署於 Railway)。App 免 API key,使用者開箱即用。

```
Quill App ──(共享密鑰 + 裝置ID)──▶ Railway 服務(Hono)
                                        │
                                        ├ 共享密鑰驗證(擋非本 App 請求)
                                        ├ 裝置每日額度(Redis,預設 10 次/天)
                                        ├ 全域每日上限(Redis,預設 5000 次/天,保護錢包)
                                        │
                                        └ 全部走 OpenAI gpt-4o-mini(vision + 文字)
                                          OpenAI 原生相容格式,pass-through 即可
```

真實金鑰只存在 Railway 環境變數,永不進 App、不進 git。

## 部署到 Railway(約 10 分鐘)

前置:[Railway 帳號](https://railway.app)、一把 [OpenAI key](https://platform.openai.com/api-keys)。

1. **建立專案**:Railway → New Project → Deploy from GitHub repo,選這個 repo,Root Directory 設 `cloud/`。
2. **加 Redis**:專案內 → New → Database → Redis(Railway 會自動注入 `REDIS_URL`)。
3. **設環境變數**(專案 → Variables):
   ```
   QUILL_APP_SECRET = <自訂一組長隨機字串,要和 App 內建值相同>
   OPENAI_KEY       = <你的 OpenAI API key,platform.openai.com>
   ```
   選填(有預設值):`DAILY_LIMIT=10`、`GLOBAL_DAILY_CAP=5000`、`OPENAI_MODEL=gpt-4o-mini`
4. Railway 用 `npm start`(= `tsx src/index.ts`)自動啟動,產生一個 `*.up.railway.app` 網址。
5. 把網址 + `/v1` 填進 App 端 `CloudConfig.endpoint`,把 `QUILL_APP_SECRET` 填進 `CloudConfig.appSecret`。

## 本機測試

```sh
cd cloud
npm install
# 需要本機 Redis(brew install redis && redis-server),或跳過額度測試
QUILL_APP_SECRET=test-secret-123 OPENAI_KEY=你的key npm start
# 服務起在 http://localhost:8787
```

App 端把 `defaults write com.morpheus.quill quill_cloud_endpoint http://localhost:8787/v1`、
`CloudConfig.appSecret` 設為 `test-secret-123`,即可測整條鏈路。

## 單元測試(不需 Redis / 網路)

```sh
npm test   # mock Redis + mock fetch,驗證密鑰/額度/格式轉換,共 11 項
```

## 調整額度 / 煞車

- 改 Railway 的 `DAILY_LIMIT` / `GLOBAL_DAILY_CAP` 變數即可,服務會自動重啟。
- 想立刻停止對外:Railway 暫停服務,或把 `GLOBAL_DAILY_CAP` 設 `0`。
- `GLOBAL_DAILY_CAP` 是你 AI 花費的每日硬上限。
