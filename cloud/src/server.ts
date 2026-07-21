/**
 * Quill Cloud — Hono 服務(部署於 Railway)
 *
 * App 免 key,只送:
 *   Authorization: Bearer <QUILL_APP_SECRET>   共享密鑰
 *   X-Quill-Device: <匿名裝置 UUID>            每日額度用
 *
 * 免費期一律走 Claude(Anthropic),成本由 $100 Anthropic credit 出。
 * App 送 OpenAI 格式,後端轉成 Anthropic 格式再轉回來(見 anthropic.ts)。
 *
 * 三道防線:共享密鑰、裝置每日額度(Redis,預設 10)、全域每日上限(Redis)。
 *
 * createApp 接受可注入的 redis / fetchImpl,方便單元測試。
 */
import { Hono } from "hono";
import {
  buildAnthropicCall,
  anthropicStreamToOpenAI,
  anthropicToOpenAIResponse,
} from "./anthropic.ts";

export interface QuillEnv {
  QUILL_APP_SECRET: string;
  ANTHROPIC_KEY: string;
  ANTHROPIC_MODEL?: string;   // 預設 claude-haiku-4-5
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
  const model = env.ANTHROPIC_MODEL || "claude-haiku-4-5";

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
    const isStream = body?.stream === true;

    // ── 轉成 Anthropic 格式呼叫 Claude ──
    const call = buildAnthropicCall(body, env.ANTHROPIC_KEY, model);
    let upstream: Response;
    try {
      upstream = await doFetch(call.url, { method: "POST", headers: call.headers, body: call.body });
    } catch {
      return errJSON("Upstream connection failed.", 502);
    }

    if (!upstream.ok) {
      return errJSON(
        `AI 服務暫時無法回應(${upstream.status})。請稍後再試。`,
        upstream.status >= 500 ? 502 : 400
      );
    }

    if (isStream && upstream.body) {
      // Anthropic SSE → OpenAI SSE,邊收邊轉
      return new Response(anthropicStreamToOpenAI(upstream.body), {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      });
    }

    // 非串流:轉成 OpenAI 回應格式
    const json = await upstream.json();
    return new Response(JSON.stringify(anthropicToOpenAIResponse(json)), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  });

  return app;
}
