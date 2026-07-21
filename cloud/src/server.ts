/**
 * Quill Cloud — Hono 服務(部署於 Railway)
 *
 * App 免 key,只送:
 *   Authorization: Bearer <QUILL_APP_SECRET>   共享密鑰
 *   X-Quill-Device: <匿名裝置 UUID>            每日額度用
 *
 * 免費期一律走 OpenAI(gpt-4o-mini,vision + 文字同一顆)。
 * OpenAI 原生就是 OpenAI 相容格式,所以只需覆寫 model + 換上游 key,pass-through。
 *
 * 三道防線:共享密鑰、裝置每日額度(Redis,預設 10)、全域每日上限(Redis)。
 *
 * createApp 接受可注入的 redis / fetchImpl,方便單元測試。
 */
import { Hono } from "hono";

export interface QuillEnv {
  QUILL_APP_SECRET: string;
  OPENAI_KEY: string;
  OPENAI_MODEL?: string;      // 預設 gpt-4o-mini
  DAILY_LIMIT?: string;       // 每裝置每日,預設 10
  GLOBAL_DAILY_CAP?: string;  // 全域每日,預設 5000
}

export interface RedisLike {
  incr(key: string): Promise<number>;
  expire(key: string, seconds: number): Promise<unknown>;
}

export interface Deps {
  redis: RedisLike;
  env: QuillEnv;
  fetchImpl?: typeof fetch;
}

const OPENAI_URL = "https://api.openai.com/v1/chat/completions";

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

function errJSON(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: { message } }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export function createApp({ redis, env, fetchImpl }: Deps): Hono {
  const app = new Hono();
  const doFetch = fetchImpl ?? fetch;
  const dailyLimit = parseInt(env.DAILY_LIMIT || "10", 10);
  const globalCap = parseInt(env.GLOBAL_DAILY_CAP || "5000", 10);
  const model = env.OPENAI_MODEL || "gpt-4o-mini";

  app.get("/health", (c) => c.text("ok"));

  app.post("/v1/chat/completions", async (c) => {
    // ── 防線 1:共享密鑰 ──
    const token = (c.req.header("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
    if (!env.QUILL_APP_SECRET || token !== env.QUILL_APP_SECRET) {
      return errJSON("Unauthorized client.", 401);
    }
    const device = (c.req.header("X-Quill-Device") || "").trim();
    if (!device || device.length > 128) {
      return errJSON("Missing device id.", 400);
    }

    const day = today();
    const deviceKey = `usage:${device}:${day}`;
    const globalKey = `global:${day}`;

    // ── 防線 2:裝置每日額度 ──
    const deviceUsed = await redis.incr(deviceKey);
    if (deviceUsed === 1) await redis.expire(deviceKey, 60 * 60 * 48);
    if (deviceUsed > dailyLimit) {
      return errJSON(
        `今日免費額度已用完(每天 ${dailyLimit} 次)。明天再回來,或在偏好設定改用自己的 API key。`,
        429
      );
    }

    // ── 防線 3:全域每日上限 ──
    const globalUsed = await redis.incr(globalKey);
    if (globalUsed === 1) await redis.expire(globalKey, 60 * 60 * 48);
    if (globalUsed > globalCap) {
      return errJSON("Quill Cloud 今日流量已滿,請稍後再試,或改用自己的 API key。", 503);
    }

    let body: any;
    try {
      body = await c.req.json();
    } catch {
      return errJSON("Invalid request body.", 400);
    }
    body.model = model; // 統一模型,忽略 App 送來的
    const isStream = body?.stream === true;

    let upstream: Response;
    try {
      upstream = await doFetch(OPENAI_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env.OPENAI_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      });
    } catch {
      return errJSON("Upstream connection failed.", 502);
    }

    if (!upstream.ok) {
      // 不回傳上游原文(可能含金鑰線索)
      return errJSON(
        `AI 服務暫時無法回應(${upstream.status})。請稍後再試。`,
        upstream.status >= 500 ? 502 : 400
      );
    }

    // OpenAI 相容:串流與非串流都原樣 pass-through
    return new Response(upstream.body, {
      status: 200,
      headers: { "Content-Type": isStream ? "text/event-stream" : "application/json" },
    });
  });

  return app;
}
