/**
 * Railway 進入點:接上真實 Redis + 啟動 HTTP 服務。
 * 環境變數在 Railway 儀表板設定(見 README)。
 */
import { serve } from "@hono/node-server";
import Redis from "ioredis";
import { createApp, type QuillEnv } from "./server.ts";

const env: QuillEnv = {
  QUILL_APP_SECRET: process.env.QUILL_APP_SECRET || "",
  ANTHROPIC_KEY: process.env.ANTHROPIC_KEY || "",
  ANTHROPIC_MODEL: process.env.ANTHROPIC_MODEL,
  DAILY_LIMIT: process.env.DAILY_LIMIT,
  GLOBAL_DAILY_CAP: process.env.GLOBAL_DAILY_CAP,
};

if (!env.QUILL_APP_SECRET || !env.ANTHROPIC_KEY) {
  console.error("[quill-cloud] 缺少必要環境變數:QUILL_APP_SECRET / ANTHROPIC_KEY");
  process.exit(1);
}

// Railway 提供 REDIS_URL;本機測試可用 redis://localhost:6379
const redis = new Redis(process.env.REDIS_URL || "redis://localhost:6379");

const app = createApp({ redis, env });
const port = parseInt(process.env.PORT || "8787", 10);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`[quill-cloud] listening on :${info.port}`);
});
