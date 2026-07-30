# Quill Cloud

部署於 Railway 的 AI proxy。App 會先取得每個安裝實例的短期簽章 token，再用 token 存取每天 10 次的免費額度。

```
Quill App ──(installation token)──▶ Railway / Hono
                                           ├─ token + 每裝置每日額度
                                           ├─ IP 註冊速率限制
                                           ├─ 全域每日成本上限
                                           ├─ 匿名使用／限額／升級指標
                                           └─ OpenAI gpt-4o-mini
```

## 隱私界線

- 不儲存截圖、選取文字、Prompt、AI 回覆或 API Key。
- 安裝 ID 只在伺服器以 HMAC 後用於去重；Redis 不保存原始 ID。
- 匿名事件最多保存 90 天。
- 管理頁需 HTTP Basic Authentication，不把管理密碼放在前端。

## Railway 環境變數

必要：

```text
OPENAI_KEY=<OpenAI API key>
INSTALLATION_TOKEN_SECRET=<至少 32 bytes 的隨機字串>
ANALYTICS_SALT=<另一組至少 32 bytes 的隨機字串>
ADMIN_USERNAME=<管理頁帳號>
ADMIN_PASSWORD=<管理頁長密碼>
# 僅用於全站成本上限與匿名指標的日期分組。
# 每位使用者的免費額度會依 App 註冊時提供的當地時區重置。
QUOTA_TIME_ZONE=Asia/Taipei
```

選填：

```text
DAILY_LIMIT=10
PRO_MONTHLY_LIMIT=600
GLOBAL_DAILY_CAP=5000
PRO_GLOBAL_DAILY_CAP=5000
REGISTRATION_DAILY_LIMIT=20
OPENAI_MODEL=gpt-4o-mini
PORTALY_API_KEY=<以 pcs_test_ 開頭的測試 key；KYC 通過後再換 live key>
PORTALY_API_HOST=https://portaly.ai
PORTALY_PLAN_ID=<Quill Pro plan id>
PORTALY_CALLBACK_SECRET=<Portaly callback secret>
PORTALY_CALLBACK_URL=https://<Railway domain>/v1/webhooks/portaly
PORTALY_DISCOUNT_CODE=LAUNCH149
PORTALY_PROMO_END=2026-08-31T15:59:59.000Z
PORTALY_SUCCESS_URL=https://quill.morpheuschen.com/checkout.html?status=success
PORTALY_CANCEL_URL=https://quill.morpheuschen.com/checkout.html?status=canceled
PORTALY_PORTAL_RETURN_URL=https://quill.morpheuschen.com/checkout.html?status=managed
```

App 透過已簽章的 installation token 呼叫 `POST /v1/billing/checkout` 建立
Portaly hosted checkout。付款結果只以驗證過簽章的
`POST /v1/webhooks/portaly` callback 為準，不以瀏覽器 redirect 判斷成功。

已綁定訂閱的裝置可呼叫 `POST /v1/billing/portal`，由伺服器依
`subscriptionId` 建立 30 分鐘有效的 Portaly 管理頁。API key 不會傳到 App，
也不接受未驗證的 Email 查詢他人訂閱。

可用以下方式各產生一組密鑰：

```sh
openssl rand -hex 32
```

部署後，指標頁位於：

```text
https://<Railway domain>/admin/metrics
```

瀏覽器會要求輸入 `ADMIN_USERNAME` 與 `ADMIN_PASSWORD`。

## 本機測試

```sh
cd cloud
npm install
OPENAI_KEY=test \
INSTALLATION_TOKEN_SECRET=test-installation-secret \
ANALYTICS_SALT=test-analytics-salt \
ADMIN_USERNAME=owner \
ADMIN_PASSWORD=local-password \
QUOTA_TIME_ZONE=Asia/Taipei \
npm start
```

本機需有 Redis，預設網址為 `redis://localhost:6379`。App 可用以下設定指向本機：

```sh
defaults write com.morpheus.quill quill_cloud_endpoint http://localhost:8787/v1
```

## 單元測試

```sh
npm test
```

測試使用 mock Redis 與 mock OpenAI，不會連線外部服務。
