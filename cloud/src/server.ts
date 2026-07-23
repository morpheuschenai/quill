/**
 * Quill Cloud — Hono service deployed on Railway.
 *
 * Privacy boundary:
 * - screenshots, selected text, prompts and AI replies are proxied, never stored;
 * - analytics only use a server-HMACed installation identifier;
 * - raw analytics expire after 90 days.
 */
import { createHmac, timingSafeEqual } from "node:crypto";
import { Hono } from "hono";

export interface QuillEnv {
  OPENAI_KEY: string;
  INSTALLATION_TOKEN_SECRET: string;
  ANALYTICS_SALT: string;
  OPENAI_MODEL?: string;
  DAILY_LIMIT?: string;
  GLOBAL_DAILY_CAP?: string;
  QUOTA_TIME_ZONE?: string;
  REGISTRATION_DAILY_LIMIT?: string;
  ADMIN_USERNAME?: string;
  ADMIN_PASSWORD?: string;
  PAYMENT_WEBHOOK_SECRET?: string;
}

export interface RedisLike {
  incr(key: string): Promise<number>;
  expire(key: string, seconds: number): Promise<unknown>;
  sadd(key: string, ...members: string[]): Promise<number>;
  scard(key: string): Promise<number>;
  eval(script: string, numberOfKeys: number, ...args: Array<string | number>): Promise<unknown>;
}

export interface Deps {
  redis: RedisLike;
  env: QuillEnv;
  fetchImpl?: typeof fetch;
  now?: () => Date;
}

type MetricEvent =
  | "app_active"
  | "quota_reached"
  | "upgrade_clicked"
  | "checkout_started"
  | "purchase_completed";

const OPENAI_URL = "https://api.openai.com/v1/chat/completions";
const RAW_RETENTION_SECONDS = 60 * 60 * 24 * 91;
const INSTALLATION_TOKEN_TTL_SECONDS = 60 * 60 * 24 * 180;

const QUOTA_SCRIPT = `
local deviceUsed = tonumber(redis.call("GET", KEYS[1]) or "0")
local globalUsed = tonumber(redis.call("GET", KEYS[2]) or "0")
local deviceLimit = tonumber(ARGV[1])
local globalLimit = tonumber(ARGV[2])
local ttl = tonumber(ARGV[3])
if deviceUsed >= deviceLimit then return {2, deviceUsed, globalUsed} end
if globalUsed >= globalLimit then return {3, deviceUsed, globalUsed} end
deviceUsed = redis.call("INCR", KEYS[1])
globalUsed = redis.call("INCR", KEYS[2])
if deviceUsed == 1 then redis.call("EXPIRE", KEYS[1], ttl) end
if globalUsed == 1 then redis.call("EXPIRE", KEYS[2], ttl) end
return {1, deviceUsed, globalUsed}
`;

function jsonError(message: string, status: number, extras: Record<string, unknown> = {}): Response {
  return new Response(JSON.stringify({ error: { message, ...extras } }), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

function base64url(value: string): string {
  return Buffer.from(value, "utf8").toString("base64url");
}

function unbase64url(value: string): string | null {
  try {
    return Buffer.from(value, "base64url").toString("utf8");
  } catch {
    return null;
  }
}

function signature(value: string, secret: string): string {
  return createHmac("sha256", secret).update(value).digest("base64url");
}

function safeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
}

function issueInstallationToken(installationID: string, secret: string, now: Date): string {
  const expiresAt = Math.floor(now.getTime() / 1000) + INSTALLATION_TOKEN_TTL_SECONDS;
  const payload = base64url(JSON.stringify({ installationID, expiresAt }));
  return `${payload}.${signature(payload, secret)}`;
}

function verifyInstallationToken(token: string, secret: string, now: Date): string | null {
  const [payload, suppliedSignature, extra] = token.split(".");
  if (!payload || !suppliedSignature || extra || !safeEqual(signature(payload, secret), suppliedSignature)) {
    return null;
  }
  const decoded = unbase64url(payload);
  if (!decoded) return null;
  try {
    const parsed = JSON.parse(decoded);
    if (
      typeof parsed.installationID !== "string" ||
      !isInstallationID(parsed.installationID) ||
      typeof parsed.expiresAt !== "number" ||
      parsed.expiresAt <= Math.floor(now.getTime() / 1000)
    ) {
      return null;
    }
    return parsed.installationID;
  } catch {
    return null;
  }
}

function isInstallationID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function dayInTimeZone(date: Date, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const part = (type: string) => parts.find((item) => item.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

function timeZoneOffsetMs(date: Date, timeZone: string): number {
  const value = new Intl.DateTimeFormat("en", {
    timeZone,
    timeZoneName: "longOffset",
  }).formatToParts(date).find((part) => part.type === "timeZoneName")?.value ?? "GMT+00:00";
  const match = value.match(/GMT([+-])(\d{2}):(\d{2})/);
  if (!match) return 0;
  const minutes = Number(match[2]) * 60 + Number(match[3]);
  return (match[1] === "-" ? -1 : 1) * minutes * 60 * 1000;
}

function nextResetISO(day: string, timeZone: string): string {
  const [year, month, date] = day.split("-").map(Number);
  const nextLocalMidnightAsUTC = Date.UTC(year, month - 1, date + 1);
  let candidate = new Date(nextLocalMidnightAsUTC);
  candidate = new Date(nextLocalMidnightAsUTC - timeZoneOffsetMs(candidate, timeZone));
  candidate = new Date(nextLocalMidnightAsUTC - timeZoneOffsetMs(candidate, timeZone));
  return candidate.toISOString();
}

function previousDays(now: Date, timeZone: string, count: number): string[] {
  const result: string[] = [];
  for (let offset = count - 1; offset >= 0; offset--) {
    result.push(dayInTimeZone(new Date(now.getTime() - offset * 86_400_000), timeZone));
  }
  return result;
}

function clientIP(request: Request): string {
  return (
    request.headers.get("cf-connecting-ip") ||
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    "unknown"
  );
}

function adminAuthorized(request: Request, env: QuillEnv): boolean {
  if (!env.ADMIN_USERNAME || !env.ADMIN_PASSWORD) return false;
  const auth = request.headers.get("authorization") || "";
  if (!auth.startsWith("Basic ")) return false;
  try {
    const [username, password] = Buffer.from(auth.slice(6), "base64").toString("utf8").split(":");
    return safeEqual(username || "", env.ADMIN_USERNAME) && safeEqual(password || "", env.ADMIN_PASSWORD);
  } catch {
    return false;
  }
}

function adminChallenge(): Response {
  return new Response("Authentication required.", {
    status: 401,
    headers: { "WWW-Authenticate": 'Basic realm="Quill Metrics"', "Cache-Control": "no-store" },
  });
}

function metricsPage(): string {
  return `<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Quill 使用指標</title>
<style>
:root{color-scheme:dark;--bg:#0d1015;--panel:#151a22;--line:#2a313d;--text:#eef2f7;--muted:#8f9aaa;--blue:#78a9ff;--orange:#ffb86b;--green:#67d7aa}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 75% 0,#1c2940 0,transparent 32%),var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{width:min(1120px,calc(100% - 32px));margin:0 auto;padding:48px 0 72px}header{display:flex;justify-content:space-between;gap:24px;align-items:end;margin-bottom:28px}
.eyebrow{font:600 12px ui-monospace,SFMono-Regular,monospace;letter-spacing:.14em;color:var(--blue);text-transform:uppercase}h1{font-size:clamp(28px,5vw,48px);margin:8px 0 0;letter-spacing:-.04em}select{background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:9px;padding:10px 12px}
.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}.card,.panel{background:rgba(21,26,34,.88);border:1px solid var(--line);border-radius:14px;padding:18px}
.label{color:var(--muted);font-size:13px}.value{font:650 34px ui-monospace,SFMono-Regular,monospace;margin-top:10px}.value.orange{color:var(--orange)}.value.green{color:var(--green)}
.grid{display:grid;grid-template-columns:1.7fr 1fr;gap:12px;margin-top:12px}.panel h2{font-size:15px;margin:0 0 18px}.bars{height:260px;display:flex;align-items:end;gap:5px;border-bottom:1px solid var(--line)}
.bar{flex:1;min-width:3px;background:linear-gradient(var(--blue),#315ea9);border-radius:4px 4px 0 0;position:relative}.bar:hover:after{content:attr(data-tip);position:absolute;bottom:calc(100% + 7px);left:50%;transform:translateX(-50%);background:#05070a;padding:5px 7px;border-radius:6px;font-size:11px;white-space:nowrap}
.funnel{display:grid;gap:12px}.step{border-left:3px solid var(--blue);padding:9px 12px;background:#10151d}.step:nth-child(2){width:78%;border-color:var(--orange)}.step:nth-child(3){width:55%;border-color:var(--green)}
.step b{display:block;font:650 24px ui-monospace,SFMono-Regular,monospace}.step span{font-size:12px;color:var(--muted)}.privacy{margin-top:12px;color:var(--muted);font-size:12px;line-height:1.6}
@media(max-width:760px){header{align-items:start;flex-direction:column}.cards{grid-template-columns:1fr 1fr}.grid{grid-template-columns:1fr}}@media(max-width:430px){.cards{grid-template-columns:1fr}}
</style></head><body><main>
<header><div><div class="eyebrow">Private · Anonymous</div><h1>Quill 使用指標</h1></div><select id="range"><option value="7">最近 7 天</option><option value="30" selected>最近 30 天</option><option value="90">最近 90 天</option></select></header>
<section class="cards"><div class="card"><div class="label">活躍裝置</div><div class="value" id="active">—</div></div><div class="card"><div class="label">達到每日限額</div><div class="value orange" id="quota">—</div></div><div class="card"><div class="label">查看升級方案</div><div class="value" id="upgrade">—</div></div><div class="card"><div class="label">完成購買</div><div class="value green" id="purchase">—</div></div></section>
<section class="grid"><div class="panel"><h2>每日活躍趨勢</h2><div class="bars" id="bars"></div></div><div class="panel"><h2>限額 → 意願 → 購買</h2><div class="funnel"><div class="step"><b id="fQuota">—</b><span>達到限額</span></div><div class="step"><b id="fUpgrade">—</b><span>查看升級</span></div><div class="step"><b id="fPurchase">—</b><span>完成購買</span></div></div></div></section>
<p class="privacy">不收集截圖、選取文字、Prompt、AI 回覆或 API Key。裝置識別只以伺服器 HMAC 後的匿名值進行每日去重；原始事件最多保存 90 天。</p>
</main><script>
const ids={app_active:"active",quota_reached:"quota",upgrade_clicked:"upgrade",purchase_completed:"purchase"};
async function load(){const days=document.querySelector("#range").value;const r=await fetch("/admin/metrics/data?days="+days);if(!r.ok)throw new Error("讀取失敗");const d=await r.json();
Object.entries(ids).forEach(([event,id])=>document.querySelector("#"+id).textContent=d.totals[event].toLocaleString());
document.querySelector("#fQuota").textContent=d.totals.quota_reached.toLocaleString();document.querySelector("#fUpgrade").textContent=d.totals.upgrade_clicked.toLocaleString();document.querySelector("#fPurchase").textContent=d.totals.purchase_completed.toLocaleString();
const max=Math.max(1,...d.days.map(x=>x.app_active));document.querySelector("#bars").innerHTML=d.days.map(x=>'<div class="bar" style="height:'+Math.max(2,x.app_active/max*100)+'%" data-tip="'+x.date+' · '+x.app_active+'"></div>').join("")}
document.querySelector("#range").addEventListener("change",()=>load().catch(alert));load().catch(alert);
</script></body></html>`;
}

export function createApp({ redis, env, fetchImpl, now = () => new Date() }: Deps): Hono {
  const app = new Hono();
  const doFetch = fetchImpl ?? fetch;
  const dailyLimit = Number.parseInt(env.DAILY_LIMIT || "10", 10);
  const globalCap = Number.parseInt(env.GLOBAL_DAILY_CAP || "5000", 10);
  const registrationLimit = Number.parseInt(env.REGISTRATION_DAILY_LIMIT || "20", 10);
  const model = env.OPENAI_MODEL || "gpt-4o-mini";
  const timeZone = env.QUOTA_TIME_ZONE || "Asia/Taipei";

  const hashIdentity = (installationID: string): string =>
    createHmac("sha256", env.ANALYTICS_SALT).update(installationID).digest("hex");

  const recordUnique = async (event: MetricEvent, day: string, identity: string): Promise<void> => {
    const key = `metrics:${event}:${day}`;
    await redis.sadd(key, identity);
    await redis.expire(key, RAW_RETENTION_SECONDS);
  };

  const authenticateInstallation = (request: Request): string | null => {
    const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
    return verifyInstallationToken(token, env.INSTALLATION_TOKEN_SECRET, now());
  };

  app.get("/health", (c) => c.json({ ok: true, timeZone }));

  app.post("/v1/installations", async (c) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return jsonError("Invalid request body.", 400);
    }
    const installationID = (body as { installation_id?: unknown })?.installation_id;
    if (typeof installationID !== "string" || !isInstallationID(installationID)) {
      return jsonError("Invalid installation id.", 400);
    }
    const day = dayInTimeZone(now(), timeZone);
    const ipHash = createHmac("sha256", env.ANALYTICS_SALT).update(clientIP(c.req.raw)).digest("hex");
    const registrationKey = `registration:${ipHash}:${day}`;
    const used = await redis.incr(registrationKey);
    if (used === 1) await redis.expire(registrationKey, RAW_RETENTION_SECONDS);
    if (used > registrationLimit) return jsonError("Too many installation registrations.", 429);
    return json({
      token: issueInstallationToken(installationID, env.INSTALLATION_TOKEN_SECRET, now()),
      expires_in: INSTALLATION_TOKEN_TTL_SECONDS,
    }, 201);
  });

  app.post("/v1/events", async (c) => {
    const installationID = authenticateInstallation(c.req.raw);
    if (!installationID) return jsonError("Unauthorized installation.", 401);
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return jsonError("Invalid request body.", 400);
    }
    const event = (body as { event?: unknown })?.event;
    if (event !== "upgrade_clicked" && event !== "checkout_started") {
      return jsonError("Unsupported event.", 400);
    }
    await recordUnique(event, dayInTimeZone(now(), timeZone), hashIdentity(installationID));
    return new Response(null, { status: 204 });
  });

  app.post("/v1/webhooks/purchase", async (c) => {
    const supplied = (c.req.header("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
    if (!env.PAYMENT_WEBHOOK_SECRET || !safeEqual(supplied, env.PAYMENT_WEBHOOK_SECRET)) {
      return jsonError("Unauthorized webhook.", 401);
    }
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return jsonError("Invalid request body.", 400);
    }
    const orderID = (body as { order_id?: unknown })?.order_id;
    if (typeof orderID !== "string" || orderID.length < 4 || orderID.length > 128) {
      return jsonError("Invalid order id.", 400);
    }
    await recordUnique(
      "purchase_completed",
      dayInTimeZone(now(), timeZone),
      createHmac("sha256", env.ANALYTICS_SALT).update(`order:${orderID}`).digest("hex")
    );
    return new Response(null, { status: 204 });
  });

  app.post("/v1/chat/completions", async (c) => {
    const installationID = authenticateInstallation(c.req.raw);
    if (!installationID) return jsonError("Unauthorized installation.", 401);

    let body: any;
    try {
      body = await c.req.json();
    } catch {
      return jsonError("Invalid request body.", 400);
    }
    if (!body || !Array.isArray(body.messages) || body.messages.length === 0) {
      return jsonError("Missing messages.", 400);
    }
    body.model = model;
    const isStream = body.stream === true;

    const currentDay = dayInTimeZone(now(), timeZone);
    const anonymousID = hashIdentity(installationID);
    const deviceKey = `usage:${anonymousID}:${currentDay}`;
    const globalKey = `global:${currentDay}`;

    let quotaResult: number[];
    try {
      quotaResult = (await redis.eval(
        QUOTA_SCRIPT,
        2,
        deviceKey,
        globalKey,
        dailyLimit,
        globalCap,
        RAW_RETENTION_SECONDS
      )) as number[];
    } catch {
      return jsonError("Usage service is temporarily unavailable.", 503);
    }

    if (Number(quotaResult[0]) === 2) {
      await recordUnique("quota_reached", currentDay, anonymousID);
      return jsonError(
        `今日免費額度已用完（每天 ${dailyLimit} 次）。明天 00:00 重置，或查看升級方案。`,
        429,
        { code: "daily_quota_reached", resets_at: nextResetISO(currentDay, timeZone) }
      );
    }
    if (Number(quotaResult[0]) === 3) {
      return jsonError("Quill Cloud 今日流量已滿，請稍後再試，或改用自己的 API key。", 503);
    }

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
      return jsonError("Upstream connection failed.", 502);
    }
    if (!upstream.ok) {
      return jsonError(
        `AI 服務暫時無法回應（${upstream.status}）。請稍後再試。`,
        upstream.status >= 500 ? 502 : 400
      );
    }

    await recordUnique("app_active", currentDay, anonymousID);
    return new Response(upstream.body, {
      status: 200,
      headers: { "Content-Type": isStream ? "text/event-stream" : "application/json" },
    });
  });

  app.get("/admin/metrics", (c) => {
    if (!adminAuthorized(c.req.raw, env)) return adminChallenge();
    return c.html(metricsPage(), 200, { "Cache-Control": "no-store" });
  });

  app.get("/admin/metrics/data", async (c) => {
    if (!adminAuthorized(c.req.raw, env)) return adminChallenge();
    const requestedDays = Number.parseInt(c.req.query("days") || "30", 10);
    const count = [7, 30, 90].includes(requestedDays) ? requestedDays : 30;
    const dates = previousDays(now(), timeZone, count);
    const events: MetricEvent[] = [
      "app_active",
      "quota_reached",
      "upgrade_clicked",
      "checkout_started",
      "purchase_completed",
    ];
    const days = await Promise.all(dates.map(async (date) => {
      const entries = await Promise.all(events.map(async (event) =>
        [event, await redis.scard(`metrics:${event}:${date}`)] as const
      ));
      return { date, ...Object.fromEntries(entries) };
    }));
    const totals = Object.fromEntries(events.map((event) => [
      event,
      days.reduce((sum, day) => sum + Number(day[event]), 0),
    ]));
    return json({ timeZone, days, totals });
  });

  return app;
}
