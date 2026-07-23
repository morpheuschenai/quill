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
QUOTA_TIME_ZONE=Asia/Taipei
```

選填：

```text
DAILY_LIMIT=10
GLOBAL_DAILY_CAP=5000
REGISTRATION_DAILY_LIMIT=20
OPENAI_MODEL=gpt-4o-mini
PAYMENT_WEBHOOK_SECRET=<付款 webhook 專用密鑰>
```

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
