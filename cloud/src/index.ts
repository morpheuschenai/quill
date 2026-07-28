/**
 * Railway 進入點:接上真實 Redis + 啟動 HTTP 服務。
 * 環境變數在 Railway 儀表板設定(見 README)。
 */
import { serve } from "@hono/node-server";
import Redis from "ioredis";
import { createApp, type QuillEnv } from "./server.ts";

const env: QuillEnv = {
  OPENAI_KEY: process.env.OPENAI_KEY || "",
  INSTALLATION_TOKEN_SECRET: process.env.INSTALLATION_TOKEN_SECRET || "",
  ANALYTICS_SALT: process.env.ANALYTICS_SALT || "",
  OPENAI_MODEL: process.env.OPENAI_MODEL,
  DAILY_LIMIT: process.env.DAILY_LIMIT,
  PRO_MONTHLY_LIMIT: process.env.PRO_MONTHLY_LIMIT,
  GLOBAL_DAILY_CAP: process.env.GLOBAL_DAILY_CAP,
  PRO_GLOBAL_DAILY_CAP: process.env.PRO_GLOBAL_DAILY_CAP,
  QUOTA_TIME_ZONE: process.env.QUOTA_TIME_ZONE,
  REGISTRATION_DAILY_LIMIT: process.env.REGISTRATION_DAILY_LIMIT,
  ADMIN_USERNAME: process.env.ADMIN_USERNAME,
  ADMIN_PASSWORD: process.env.ADMIN_PASSWORD,
  CHECKOUT_URL: process.env.CHECKOUT_URL,
  PAYMENT_WEBHOOK_SECRET: process.env.PAYMENT_WEBHOOK_SECRET,
  PORTALY_API_KEY: process.env.PORTALY_API_KEY,
  PORTALY_API_HOST: process.env.PORTALY_API_HOST,
  PORTALY_PLAN_ID: process.env.PORTALY_PLAN_ID,
  PORTALY_CALLBACK_SECRET: process.env.PORTALY_CALLBACK_SECRET,
  PORTALY_CALLBACK_URL: process.env.PORTALY_CALLBACK_URL,
  PORTALY_DISCOUNT_CODE: process.env.PORTALY_DISCOUNT_CODE,
  PORTALY_PROMO_END: process.env.PORTALY_PROMO_END,
  PORTALY_SUCCESS_URL: process.env.PORTALY_SUCCESS_URL,
  PORTALY_CANCEL_URL: process.env.PORTALY_CANCEL_URL,
  PORTALY_PORTAL_RETURN_URL: process.env.PORTALY_PORTAL_RETURN_URL,
};

if (!env.OPENAI_KEY || !env.INSTALLATION_TOKEN_SECRET || !env.ANALYTICS_SALT) {
  console.error("[quill-cloud] 缺少必要環境變數: OPENAI_KEY / INSTALLATION_TOKEN_SECRET / ANALYTICS_SALT");
  process.exit(1);
}

// Railway 提供 REDIS_URL;本機測試可用 redis://localhost:6379
const redis = new Redis(process.env.REDIS_URL || "redis://localhost:6379");

const app = createApp({ redis, env });
const port = parseInt(process.env.PORT || "8787", 10);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`[quill-cloud] listening on :${info.port}`);
});
