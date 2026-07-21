/**
 * Quill Cloud — Cloudflare Worker
 *
 * 代理 Gemini(OpenAI 相容端點)。App 不需 API key,只送:
 *   Authorization: Bearer <QUILL_APP_SECRET>   共享密鑰,擋隨手掃描
 *   X-Quill-Device: <匿名裝置 UUID>            用於每日額度
 *
 * 三道防線防止成本失控:
 *   1. 共享密鑰:非本 App 的請求直接 401
 *   2. 裝置每日額度:每個裝置每天 N 次(DAILY_LIMIT)
 *   3. 全域每日上限:所有裝置合計 GLOBAL_DAILY_CAP,超過回 503 保護錢包
 *
 * 真實金鑰只存在 Cloudflare Secret(GEMINI_KEY),永不進 App、不進 git。
 */

export interface Env {
  QUILL_KV: KVNamespace;
  GEMINI_KEY: string;          // wrangler secret
  QUILL_APP_SECRET: string;    // wrangler secret,與 App 內建值相同
  GEMINI_MODEL?: string;       // 預設 gemini-2.0-flash
  DAILY_LIMIT?: string;        // 每裝置每日次數,預設 20
  GLOBAL_DAILY_CAP?: string;   // 全域每日次數,預設 5000
}

const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";

function today(): string {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD (UTC)
}

function jsonError(message: string, status: number): Response {
  // 沿用 OpenAI 錯誤格式,App 的 parseAPIError 能直接解析
  return new Response(JSON.stringify({ error: { message } }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // CORS 預檢(給網頁版 demo 或未來用途)
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Headers": "Authorization, Content-Type, X-Quill-Device",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
        },
      });
    }

    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return new Response("ok", { status: 200 });
    }
    if (request.method !== "POST" || !url.pathname.endsWith("/chat/completions")) {
      return jsonError("Not found", 404);
    }

    // ── 防線 1:共享密鑰 ──
    const auth = request.headers.get("Authorization") || "";
    const token = auth.replace(/^Bearer\s+/i, "").trim();
    if (!env.QUILL_APP_SECRET || token !== env.QUILL_APP_SECRET) {
      return jsonError("Unauthorized client.", 401);
    }

    const device = (request.headers.get("X-Quill-Device") || "").trim();
    if (!device || device.length > 128) {
      return jsonError("Missing device id.", 400);
    }

    const dailyLimit = parseInt(env.DAILY_LIMIT || "20", 10);
    const globalCap = parseInt(env.GLOBAL_DAILY_CAP || "5000", 10);
    const day = today();
    const deviceKey = `usage:${device}:${day}`;
    const globalKey = `global:${day}`;

    // ── 防線 2:裝置每日額度 ──
    const deviceUsed = parseInt((await env.QUILL_KV.get(deviceKey)) || "0", 10);
    if (deviceUsed >= dailyLimit) {
      return jsonError(
        `今日免費額度已用完(每天 ${dailyLimit} 次)。明天再回來,或在偏好設定改用自己的 API key。`,
        429
      );
    }

    // ── 防線 3:全域每日上限(保護錢包)──
    const globalUsed = parseInt((await env.QUILL_KV.get(globalKey)) || "0", 10);
    if (globalUsed >= globalCap) {
      return jsonError("Quill Cloud 今日流量已滿,請稍後再試,或改用自己的 API key。", 503);
    }

    // 解析 body,強制改用 Gemini 模型(忽略 App 送來的 model)
    let body: any;
    try {
      body = await request.json();
    } catch {
      return jsonError("Invalid request body.", 400);
    }
    body.model = env.GEMINI_MODEL || "gemini-2.0-flash";
    const isStream = body.stream === true;

    // 先扣額度再轉發:即使串流中途斷線也已計數,避免被刷
    await bumpUsage(env, deviceKey, deviceUsed, globalKey, globalUsed);

    let upstream: Response;
    try {
      upstream = await fetch(GEMINI_BASE, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${env.GEMINI_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      });
    } catch (e: any) {
      return jsonError("Upstream connection failed.", 502);
    }

    if (!upstream.ok) {
      const text = await upstream.text();
      // 不把上游原文(可能含金鑰線索)回傳,給通用訊息
      return jsonError(
        `AI 服務暫時無法回應(${upstream.status})。請稍後再試。`,
        upstream.status >= 500 ? 502 : 400
      );
    }

    // 串流直接 pass-through;非串流原樣回傳
    const headers = new Headers({
      "Access-Control-Allow-Origin": "*",
      "Content-Type": isStream ? "text/event-stream" : "application/json",
    });
    return new Response(upstream.body, { status: 200, headers });
  },
};

async function bumpUsage(
  env: Env,
  deviceKey: string,
  deviceUsed: number,
  globalKey: string,
  globalUsed: number
): Promise<void> {
  // KV 值隔日自動過期(2 天 TTL 足以涵蓋 UTC 換日)
  const ttl = 60 * 60 * 48;
  await Promise.all([
    env.QUILL_KV.put(deviceKey, String(deviceUsed + 1), { expirationTtl: ttl }),
    env.QUILL_KV.put(globalKey, String(globalUsed + 1), { expirationTtl: ttl }),
  ]);
}
