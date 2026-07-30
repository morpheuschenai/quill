/**
 * Quill Cloud — Hono service deployed on Railway.
 *
 * Privacy boundary:
 * - screenshots, selected text, prompts and AI replies are proxied, never stored;
 * - analytics only use a server-HMACed installation identifier;
 * - raw analytics expire after 90 days.
 */
import { createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { secureHeaders } from "hono/secure-headers";
import { verifyPortalyCallback } from "./portalyCallback.mjs";

export interface QuillEnv {
  OPENAI_KEY: string;
  INSTALLATION_TOKEN_SECRET: string;
  ANALYTICS_SALT: string;
  OPENAI_MODEL?: string;
  DAILY_LIMIT?: string;
  PRO_MONTHLY_LIMIT?: string;
  GLOBAL_DAILY_CAP?: string;
  PRO_GLOBAL_DAILY_CAP?: string;
  QUOTA_TIME_ZONE?: string;
  REGISTRATION_DAILY_LIMIT?: string;
  ADMIN_USERNAME?: string;
  ADMIN_PASSWORD?: string;
  CHECKOUT_URL?: string;
  PAYMENT_WEBHOOK_SECRET?: string;
  PORTALY_API_KEY?: string;
  PORTALY_API_HOST?: string;
  PORTALY_PLAN_ID?: string;
  PORTALY_CALLBACK_SECRET?: string;
  PORTALY_CALLBACK_URL?: string;
  PORTALY_DISCOUNT_CODE?: string;
  PORTALY_PROMO_END?: string;
  PORTALY_SUCCESS_URL?: string;
  PORTALY_CANCEL_URL?: string;
  PORTALY_PORTAL_RETURN_URL?: string;
}

export interface RedisLike {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, ...args: Array<string | number>): Promise<unknown>;
  incr(key: string): Promise<number>;
  expire(key: string, seconds: number): Promise<unknown>;
  sadd(key: string, ...members: string[]): Promise<number>;
  scard(key: string): Promise<number>;
  sunion(...keys: string[]): Promise<string[]>;
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
const CHECKOUT_SESSION_TTL_SECONDS = 60 * 60 * 24;

interface SubscriptionRecord {
  subscriptionId: string;
  sessionId: string;
  planId: string;
  mode: "live" | "test";
  status: string;
  periodStart: string;
  periodEnd: string;
  currentAmount: number | null;
  cancelAtPeriodEnd: boolean;
  cancelEffectiveAt: string | null;
}

interface InstallationIdentity {
  installationID: string;
  timeZone: string;
}

const MAX_REQUEST_BYTES = 10 * 1024 * 1024;

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

function issueInstallationToken(
  installationID: string,
  timeZone: string,
  secret: string,
  now: Date
): string {
  const expiresAt = Math.floor(now.getTime() / 1000) + INSTALLATION_TOKEN_TTL_SECONDS;
  const payload = base64url(JSON.stringify({ installationID, timeZone, expiresAt }));
  return `${payload}.${signature(payload, secret)}`;
}

function verifyInstallationToken(
  token: string,
  secret: string,
  now: Date,
  fallbackTimeZone: string
): InstallationIdentity | null {
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
    return {
      installationID: parsed.installationID,
      timeZone: isValidTimeZone(parsed.timeZone) ? parsed.timeZone : fallbackTimeZone,
    };
  } catch {
    return null;
  }
}

function isInstallationID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function isValidTimeZone(value: unknown): value is string {
  if (typeof value !== "string" || value.length === 0 || value.length > 64) return false;
  try {
    new Intl.DateTimeFormat("en", { timeZone: value }).format();
    return true;
  } catch {
    return false;
  }
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

function validISO(value: unknown): value is string {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function addOneMonthISO(value: string): string {
  const date = new Date(value);
  const originalDay = date.getUTCDate();
  date.setUTCDate(1);
  date.setUTCMonth(date.getUTCMonth() + 1);
  const lastDay = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 0)).getUTCDate();
  date.setUTCDate(Math.min(originalDay, lastDay));
  return date.toISOString();
}

function parseSubscription(raw: string | null): SubscriptionRecord | null {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as Partial<SubscriptionRecord>;
    if (
      typeof parsed.subscriptionId !== "string" ||
      typeof parsed.sessionId !== "string" ||
      typeof parsed.planId !== "string" ||
      (parsed.mode !== "live" && parsed.mode !== "test") ||
      typeof parsed.status !== "string" ||
      !validISO(parsed.periodStart) ||
      !validISO(parsed.periodEnd)
    ) {
      return null;
    }
    return {
      subscriptionId: parsed.subscriptionId,
      sessionId: parsed.sessionId,
      planId: parsed.planId,
      mode: parsed.mode,
      status: parsed.status,
      periodStart: parsed.periodStart,
      periodEnd: parsed.periodEnd,
      currentAmount: typeof parsed.currentAmount === "number" ? parsed.currentAmount : null,
      cancelAtPeriodEnd: parsed.cancelAtPeriodEnd === true,
      cancelEffectiveAt: validISO(parsed.cancelEffectiveAt) ? parsed.cancelEffectiveAt : null,
    };
  } catch {
    return null;
  }
}

function subscriptionHasAccess(record: SubscriptionRecord | null, date: Date): record is SubscriptionRecord {
  if (!record || Date.parse(record.periodEnd) <= date.getTime()) return false;
  return ["active", "cancel_requested", "past_due"].includes(record.status);
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

function checkoutURL(env: QuillEnv): string {
  const fallback = "https://quill.morpheuschen.com/checkout.html?status=coming-soon";
  if (!env.CHECKOUT_URL) return fallback;
  try {
    const url = new URL(env.CHECKOUT_URL);
    return url.protocol === "https:" ? url.toString() : fallback;
  } catch {
    return fallback;
  }
}

function portalyMode(apiKey: string | undefined): "live" | "test" | null {
  if (apiKey?.startsWith("pcs_live_")) return "live";
  if (apiKey?.startsWith("pcs_test_")) return "test";
  return null;
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
.cards{display:grid;grid-template-columns:repeat(5,1fr);gap:12px}.card,.panel{background:rgba(21,26,34,.88);border:1px solid var(--line);border-radius:14px;padding:18px}
.label{color:var(--muted);font-size:13px}.value{font:650 34px ui-monospace,SFMono-Regular,monospace;margin-top:10px}.value.orange{color:var(--orange)}.value.green{color:var(--green)}
.grid{display:grid;grid-template-columns:1.7fr 1fr;gap:12px;margin-top:12px}.panel h2{font-size:15px;margin:0 0 18px}.bars{height:260px;display:flex;align-items:end;gap:5px;border-bottom:1px solid var(--line)}
.bar{flex:1;min-width:3px;background:linear-gradient(var(--blue),#315ea9);border-radius:4px 4px 0 0;position:relative}.bar:hover:after{content:attr(data-tip);position:absolute;bottom:calc(100% + 7px);left:50%;transform:translateX(-50%);background:#05070a;padding:5px 7px;border-radius:6px;font-size:11px;white-space:nowrap}
.funnel{display:grid;gap:12px}.step{border-left:3px solid var(--blue);padding:9px 12px;background:#10151d}.step:nth-child(2){width:86%;border-color:var(--orange)}.step:nth-child(3){width:70%;border-color:#b68cff}.step:nth-child(4){width:55%;border-color:var(--green)}
.step b{display:block;font:650 24px ui-monospace,SFMono-Regular,monospace}.step span{font-size:12px;color:var(--muted)}.privacy{margin-top:12px;color:var(--muted);font-size:12px;line-height:1.6}
@media(max-width:760px){header{align-items:start;flex-direction:column}.cards{grid-template-columns:1fr 1fr}.grid{grid-template-columns:1fr}}@media(max-width:430px){.cards{grid-template-columns:1fr}}
</style></head><body><main>
<header><div><div class="eyebrow">Private · Anonymous</div><h1>Quill 使用指標</h1></div><select id="range"><option value="7">最近 7 天</option><option value="30" selected>最近 30 天</option><option value="90">最近 90 天</option></select></header>
<section class="cards"><div class="card"><div class="label">活躍裝置</div><div class="value" id="active">—</div></div><div class="card"><div class="label">達到使用限額</div><div class="value orange" id="quota">—</div></div><div class="card"><div class="label">查看升級方案</div><div class="value" id="upgrade">—</div></div><div class="card"><div class="label">開始結帳</div><div class="value" id="checkout">—</div></div><div class="card"><div class="label">完成購買</div><div class="value green" id="purchase">—</div></div></section>
<section class="grid"><div class="panel"><h2>每日活躍趨勢</h2><div class="bars" id="bars"></div></div><div class="panel"><h2>限額 → 意願 → 購買</h2><div class="funnel"><div class="step"><b id="fQuota">—</b><span>達到限額</span></div><div class="step"><b id="fUpgrade">—</b><span>查看升級</span></div><div class="step"><b id="fCheckout">—</b><span>開始結帳</span></div><div class="step"><b id="fPurchase">—</b><span>完成購買</span></div></div></div></section>
<p class="privacy">不收集截圖、選取文字、Prompt、AI 回覆或 API Key。裝置識別只以伺服器 HMAC 後的匿名值進行每日去重；原始事件最多保存 90 天。</p>
</main><script>
const ids={app_active:"active",quota_reached:"quota",upgrade_clicked:"upgrade",checkout_started:"checkout",purchase_completed:"purchase"};
async function load(){const days=document.querySelector("#range").value;const r=await fetch("/admin/metrics/data?days="+days);if(!r.ok)throw new Error("讀取失敗");const d=await r.json();
Object.entries(ids).forEach(([event,id])=>document.querySelector("#"+id).textContent=d.totals[event].toLocaleString());
document.querySelector("#fQuota").textContent=d.totals.quota_reached.toLocaleString();document.querySelector("#fUpgrade").textContent=d.totals.upgrade_clicked.toLocaleString();document.querySelector("#fCheckout").textContent=d.totals.checkout_started.toLocaleString();document.querySelector("#fPurchase").textContent=d.totals.purchase_completed.toLocaleString();
const max=Math.max(1,...d.days.map(x=>x.app_active));document.querySelector("#bars").innerHTML=d.days.map(x=>'<div class="bar" style="height:'+Math.max(2,x.app_active/max*100)+'%" data-tip="'+x.date+' · '+x.app_active+'"></div>').join("")}
document.querySelector("#range").addEventListener("change",()=>load().catch(alert));load().catch(alert);
</script></body></html>`;
}

export function createApp({ redis, env, fetchImpl, now = () => new Date() }: Deps): Hono {
  const app = new Hono();
  app.use("*", secureHeaders());
  app.use("/v1/*", bodyLimit({
    maxSize: MAX_REQUEST_BYTES,
    onError: (c) => jsonError("Request body is too large.", 413),
  }));
  const doFetch = fetchImpl ?? fetch;
  const dailyLimit = Number.parseInt(env.DAILY_LIMIT || "10", 10);
  const proMonthlyLimit = Number.parseInt(env.PRO_MONTHLY_LIMIT || "600", 10);
  const globalCap = Number.parseInt(env.GLOBAL_DAILY_CAP || "5000", 10);
  const proGlobalCap = Number.parseInt(env.PRO_GLOBAL_DAILY_CAP || "5000", 10);
  const registrationLimit = Number.parseInt(env.REGISTRATION_DAILY_LIMIT || "20", 10);
  const model = env.OPENAI_MODEL || "gpt-4o-mini";
  const timeZone = env.QUOTA_TIME_ZONE || "Asia/Taipei";
  const promotionEnd = env.PORTALY_PROMO_END || "2026-08-31T15:59:59.000Z";
  const promotionIsActive = (): boolean =>
    Boolean(env.PORTALY_DISCOUNT_CODE) &&
    Number.isFinite(Date.parse(promotionEnd)) &&
    now().getTime() <= Date.parse(promotionEnd);

  const hashIdentity = (installationID: string): string =>
    createHmac("sha256", env.ANALYTICS_SALT).update(installationID).digest("hex");

  const recordUnique = async (event: MetricEvent, day: string, identity: string): Promise<void> => {
    const key = `metrics:${event}:${day}`;
    await redis.sadd(key, identity);
    await redis.expire(key, RAW_RETENTION_SECONDS);
  };

  const authenticateInstallation = (request: Request): InstallationIdentity | null => {
    const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
    return verifyInstallationToken(token, env.INSTALLATION_TOKEN_SECRET, now(), timeZone);
  };

  const subscriptionKey = (anonymousID: string): string => `subscription:installation:${anonymousID}`;
  const subscriptionIndexKey = (subscriptionID: string): string =>
    `subscription:portaly:${subscriptionID}`;

  const loadSubscription = async (anonymousID: string): Promise<SubscriptionRecord | null> =>
    parseSubscription(await redis.get(subscriptionKey(anonymousID)));

  const saveSubscription = async (
    anonymousID: string,
    record: SubscriptionRecord
  ): Promise<void> => {
    await redis.set(subscriptionKey(anonymousID), JSON.stringify(record));
    await redis.set(subscriptionIndexKey(record.subscriptionId), anonymousID);
  };

  const usageStatus = async (installation: InstallationIdentity) => {
    const current = now();
    const quotaDay = dayInTimeZone(current, installation.timeZone);
    const metricDay = dayInTimeZone(current, timeZone);
    const anonymousID = hashIdentity(installation.installationID);
    const subscription = await loadSubscription(anonymousID);
    const configuredPaymentMode = portalyMode(env.PORTALY_API_KEY);
    const subscriptionMatchesMode =
      !configuredPaymentMode ||
      !subscription?.mode ||
      subscription.mode === configuredPaymentMode;
    const isPro =
      subscriptionMatchesMode && subscriptionHasAccess(subscription, current);
    const usageKey = isPro
      ? `usage:pro:${anonymousID}:${subscription.periodStart}`
      : `usage:${anonymousID}:${quotaDay}`;
    const used = Number.parseInt((await redis.get(usageKey)) || "0", 10) || 0;
    const limit = isPro ? proMonthlyLimit : dailyLimit;
    return {
      anonymousID,
      subscription,
      isPro,
      usageKey,
      used,
      limit,
      resetsAt: isPro ? subscription.periodEnd : nextResetISO(quotaDay, installation.timeZone),
      quotaDay,
      metricDay,
    };
  };

  app.get("/health", (c) =>
    c.json({
      ok: true,
      metricsTimeZone: timeZone,
      payments: {
        configured: Boolean(env.PORTALY_API_KEY && env.PORTALY_PLAN_ID),
        mode: portalyMode(env.PORTALY_API_KEY),
      },
    })
  );

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
    const requestedTimeZone = (body as { time_zone?: unknown })?.time_zone;
    if (requestedTimeZone !== undefined && !isValidTimeZone(requestedTimeZone)) {
      return jsonError("Invalid time zone.", 400);
    }
    const installationTimeZone = requestedTimeZone ?? timeZone;
    const day = dayInTimeZone(now(), timeZone);
    const ipHash = createHmac("sha256", env.ANALYTICS_SALT).update(clientIP(c.req.raw)).digest("hex");
    const registrationKey = `registration:${ipHash}:${day}`;
    const used = await redis.incr(registrationKey);
    if (used === 1) await redis.expire(registrationKey, RAW_RETENTION_SECONDS);
    if (used > registrationLimit) return jsonError("Too many installation registrations.", 429);
    return json({
      token: issueInstallationToken(
        installationID,
        installationTimeZone,
        env.INSTALLATION_TOKEN_SECRET,
        now()
      ),
      expires_in: INSTALLATION_TOKEN_TTL_SECONDS,
    }, 201);
  });

  app.post("/v1/events", async (c) => {
    const installation = authenticateInstallation(c.req.raw);
    if (!installation) return jsonError("Unauthorized installation.", 401);
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
    await recordUnique(
      event,
      dayInTimeZone(now(), timeZone),
      hashIdentity(installation.installationID)
    );
    return new Response(null, { status: 204 });
  });

  app.get("/v1/billing/status", async (c) => {
    const installation = authenticateInstallation(c.req.raw);
    if (!installation) return jsonError("Unauthorized installation.", 401);
    const status = await usageStatus(installation);
    return json({
      plan: status.isPro ? "pro" : "free",
      used: status.used,
      limit: status.limit,
      remaining: Math.max(0, status.limit - status.used),
      resets_at: status.resetsAt,
      subscription: status.isPro && status.subscription
        ? {
            status: status.subscription.status,
            current_amount: status.subscription.currentAmount,
            next_amount: 199,
            cancel_at_period_end: status.subscription.cancelAtPeriodEnd,
            cancel_effective_at: status.subscription.cancelEffectiveAt,
          }
        : null,
      promotion: {
        active: promotionIsActive(),
        first_month_amount: promotionIsActive() ? 149 : 199,
        recurring_amount: 199,
        ends_at: promotionEnd,
      },
    });
  });

  app.post("/v1/billing/checkout", async (c) => {
    const installation = authenticateInstallation(c.req.raw);
    if (!installation) return jsonError("Unauthorized installation.", 401);
    if (
      !env.PORTALY_API_KEY ||
      !env.PORTALY_PLAN_ID ||
      !env.PORTALY_CALLBACK_URL
    ) {
      return jsonError("Checkout is not configured.", 503);
    }
    let callbackURL: URL;
    try {
      callbackURL = new URL(env.PORTALY_CALLBACK_URL);
    } catch {
      return jsonError("Checkout callback is invalid.", 503);
    }
    if (callbackURL.protocol !== "https:") {
      return jsonError("Checkout callback must use HTTPS.", 503);
    }

    const status = await usageStatus(installation);
    if (status.isPro) {
      return jsonError("Quill Pro is already active.", 409, { code: "PRO_ALREADY_ACTIVE" });
    }

    const promoActive = promotionIsActive();
    const requestBody: Record<string, unknown> = {
      planId: env.PORTALY_PLAN_ID,
      successRedirectUrl:
        env.PORTALY_SUCCESS_URL ||
        "https://quill.morpheuschen.com/checkout.html?status=success",
      cancelRedirectUrl:
        env.PORTALY_CANCEL_URL ||
        "https://quill.morpheuschen.com/checkout.html?status=canceled",
      callbackUrl: env.PORTALY_CALLBACK_URL,
      subscriptionCallbackUrl: env.PORTALY_CALLBACK_URL,
      merchantOrderNumber: `quill_${randomUUID()}`,
      metadata: { installationHash: status.anonymousID },
    };
    if (promoActive) requestBody.discountCode = env.PORTALY_DISCOUNT_CODE;

    let response: Response;
    try {
      response = await doFetch(
        `${env.PORTALY_API_HOST || "https://portaly.ai"}/api/creator-subscription/checkout-sessions`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${env.PORTALY_API_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(requestBody),
        }
      );
    } catch {
      return jsonError("Checkout service is temporarily unavailable.", 502);
    }

    let result: any;
    try {
      result = await response.json();
    } catch {
      return jsonError("Checkout service returned an invalid response.", 502);
    }
    if (!response.ok) {
      const code = typeof result?.code === "string" ? result.code : undefined;
      if (code === "PLAN_INACTIVE") {
        return jsonError("This plan is no longer available.", 422, { code });
      }
      return jsonError("Unable to start checkout.", 502, code ? { code } : {});
    }

    const session = result?.data;
    let hostedCheckoutURL: URL;
    try {
      hostedCheckoutURL = new URL(session?.checkoutUrl);
    } catch {
      return jsonError("Checkout service returned an invalid checkout URL.", 502);
    }
    if (
      typeof session?.sessionId !== "string" ||
      hostedCheckoutURL.protocol !== "https:" ||
      typeof session?.checkoutToken !== "string" ||
      !validISO(session?.expiresAt)
    ) {
      return jsonError("Checkout service returned an incomplete session.", 502);
    }
    const appliedDiscount =
      session?.appliedDiscount && typeof session.appliedDiscount === "object"
        ? session.appliedDiscount as Record<string, unknown>
        : null;
    const promotionApplied =
      promoActive &&
      appliedDiscount?.code === env.PORTALY_DISCOUNT_CODE &&
      typeof appliedDiscount?.finalAmount === "number";
    const firstMonthAmount =
      promotionApplied
        ? appliedDiscount!.finalAmount as number
        : typeof session?.amount === "number"
          ? session.amount
          : 199;
    await redis.set(
      `checkout-session:${session.sessionId}`,
      JSON.stringify({
        sessionId: session.sessionId,
        checkoutToken: session.checkoutToken,
        checkoutUrl: session.checkoutUrl,
        expiresAt: session.expiresAt,
        installationHash: status.anonymousID,
        mode: portalyMode(env.PORTALY_API_KEY),
        amount: firstMonthAmount,
      }),
      "EX",
      CHECKOUT_SESSION_TTL_SECONDS
    );
    await recordUnique("checkout_started", status.metricDay, status.anonymousID);
    return json({
      checkout_url: session.checkoutUrl,
      checkout_session_id: session.sessionId,
      expires_at: session.expiresAt,
      promotion_applied: promotionApplied,
      first_month_amount: firstMonthAmount,
      recurring_amount: 199,
    }, 201);
  });

  app.post("/v1/billing/portal", async (c) => {
    const installation = authenticateInstallation(c.req.raw);
    if (!installation) return jsonError("Unauthorized installation.", 401);
    if (!env.PORTALY_API_KEY) {
      return jsonError("Subscription management is not configured.", 503);
    }

    const status = await usageStatus(installation);
    if (!status.subscription) {
      return jsonError("No subscription is linked to this installation.", 404, {
        code: "SUBSCRIPTION_NOT_FOUND",
      });
    }

    const returnURL =
      env.PORTALY_PORTAL_RETURN_URL ||
      "https://quill.morpheuschen.com/checkout.html?status=managed";
    try {
      if (new URL(returnURL).protocol !== "https:") {
        return jsonError("Subscription return URL must use HTTPS.", 503);
      }
    } catch {
      return jsonError("Subscription return URL is invalid.", 503);
    }

    let response: Response;
    try {
      response = await doFetch(
        `${env.PORTALY_API_HOST || "https://portaly.ai"}/api/creator-subscription/portal-sessions`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${env.PORTALY_API_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            subscriptionId: status.subscription.subscriptionId,
            returnUrl: returnURL,
          }),
        }
      );
    } catch {
      return jsonError("Subscription service is temporarily unavailable.", 502);
    }

    let result: any;
    try {
      result = await response.json();
    } catch {
      return jsonError("Subscription service returned an invalid response.", 502);
    }
    if (!response.ok) {
      return jsonError("Unable to open subscription management.", 502);
    }

    const portal = result?.data;
    if (
      typeof portal?.portalUrl !== "string" ||
      !portal.portalUrl.startsWith("https://") ||
      !validISO(portal?.expiresAt)
    ) {
      return jsonError("Subscription service returned an incomplete session.", 502);
    }
    return json({
      portal_url: portal.portalUrl,
      expires_at: portal.expiresAt,
    }, 201);
  });

  app.get("/checkout", async (c) => {
    const identity = createHmac("sha256", env.ANALYTICS_SALT)
      .update(`checkout:${clientIP(c.req.raw)}`)
      .digest("hex");
    await recordUnique("checkout_started", dayInTimeZone(now(), timeZone), identity);
    return new Response(null, {
      status: 302,
      headers: {
        Location: checkoutURL(env),
        "Cache-Control": "no-store",
      },
    });
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

  app.post("/v1/webhooks/portaly", async (c) => {
    const event = c.req.header("x-portaly-event") || "";
    const timestamp = c.req.header("x-portaly-timestamp") || "";
    const suppliedSignature = c.req.header("x-portaly-signature") || "";
    const timestampMs = Date.parse(timestamp);

    if (!event || !timestamp || !suppliedSignature || !Number.isFinite(timestampMs)) {
      return jsonError("Missing or invalid callback headers.", 400);
    }
    if (Math.abs(now().getTime() - timestampMs) > 5 * 60 * 1000) {
      return jsonError("Stale callback.", 401);
    }
    if (!env.PORTALY_CALLBACK_SECRET) {
      return jsonError("Callback verification is not configured.", 503);
    }

    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return jsonError("Invalid request body.", 400);
    }

    const verified = verifyPortalyCallback({
      secret: env.PORTALY_CALLBACK_SECRET,
      payload: body,
      timestamp,
      signature: suppliedSignature,
    });
    if (!verified) return jsonError("Invalid callback signature.", 401);

    const payload = body as Record<string, unknown>;
    if (payload.event !== event) return jsonError("Callback event mismatch.", 400);
    if (payload.mode !== "live" && payload.mode !== "test") {
      return jsonError("Callback mode is missing or invalid.", 400);
    }
    const expectedMode = portalyMode(env.PORTALY_API_KEY);
    if (expectedMode && payload.mode !== expectedMode) {
      return jsonError("Callback mode does not match the configured payment mode.", 400);
    }

    let deliveryIdentity: string | null = null;
    let callbackAnonymousID: string | null = null;
    if (event === "creator_subscription.checkout.completed") {
      if (payload.status !== "completed" || typeof payload.sessionId !== "string") {
        return jsonError("Invalid completed checkout callback.", 400);
      }
      const metadata = payload.metadata as Record<string, unknown> | undefined;
      const installationHash = metadata?.installationHash;
      if (
        typeof installationHash !== "string" ||
        !/^[0-9a-f]{64}$/i.test(installationHash)
      ) {
        return jsonError("Missing checkout installation identity.", 400);
      }
      if (env.PORTALY_PLAN_ID && payload.planId !== env.PORTALY_PLAN_ID) {
        return jsonError("Unexpected checkout plan.", 400);
      }
      const pendingCheckoutRaw = await redis.get(`checkout-session:${payload.sessionId}`);
      if (pendingCheckoutRaw) {
        try {
          const pendingCheckout = JSON.parse(pendingCheckoutRaw) as {
            installationHash?: unknown;
            mode?: unknown;
          };
          if (
            pendingCheckout.installationHash !== installationHash ||
            (expectedMode && pendingCheckout.mode && pendingCheckout.mode !== expectedMode)
          ) {
            return jsonError("Checkout session identity does not match.", 400);
          }
        } catch {
          return jsonError("Checkout session record is invalid.", 500);
        }
      }
      deliveryIdentity = payload.sessionId;
      callbackAnonymousID = installationHash;
    } else if (
      event === "creator_subscription.payment.succeeded" ||
      event === "creator_subscription.payment.failed"
    ) {
      deliveryIdentity =
        typeof payload.paymentId === "string"
          ? payload.paymentId
          : typeof payload.paymentReference === "string"
            ? payload.paymentReference
            : null;
      if (!deliveryIdentity) return jsonError("Missing callback payment identity.", 400);
    }

    if (deliveryIdentity) {
      const idempotencyKey = `portaly-callback:${event}`;
      const anonymousIdentity = hashIdentity(`${event}:${deliveryIdentity}`);
      const inserted = await redis.sadd(idempotencyKey, anonymousIdentity);
      await redis.expire(idempotencyKey, RAW_RETENTION_SECONDS);
      if (inserted === 0) return new Response(null, { status: 204 });

      if (event === "creator_subscription.checkout.completed") {
        const sessionID = payload.sessionId as string;
        const subscriptionID =
          typeof payload.subscriptionId === "string" ? payload.subscriptionId : sessionID;
        const periodStart = validISO(payload.completedAt)
          ? payload.completedAt
          : now().toISOString();
        const periodEnd = validISO(payload.nextBillingAt)
          ? payload.nextBillingAt
          : addOneMonthISO(periodStart);
        await saveSubscription(callbackAnonymousID!, {
          subscriptionId: subscriptionID,
          sessionId: sessionID,
          planId: typeof payload.planId === "string" ? payload.planId : env.PORTALY_PLAN_ID || "",
          mode: payload.mode === "live" ? "live" : "test",
          status: "active",
          periodStart,
          periodEnd,
          currentAmount: typeof payload.amount === "number" ? payload.amount : null,
          cancelAtPeriodEnd: false,
          cancelEffectiveAt: null,
        });
        await recordUnique(
          "purchase_completed",
          dayInTimeZone(now(), timeZone),
          hashIdentity(`portaly-purchase:${deliveryIdentity}`)
        );
      }
    }

    if (event !== "creator_subscription.checkout.completed") {
      const subscriptionID =
        typeof payload.subscriptionId === "string"
          ? payload.subscriptionId
          : typeof payload.sessionId === "string"
            ? payload.sessionId
            : null;
      if (subscriptionID) {
        const anonymousID = await redis.get(subscriptionIndexKey(subscriptionID));
        const record = anonymousID ? await loadSubscription(anonymousID) : null;
        if (anonymousID && record) {
          if (event === "creator_subscription.payment.succeeded") {
            record.status = "active";
            record.periodStart = validISO(payload.chargedAt)
              ? payload.chargedAt
              : now().toISOString();
            record.periodEnd = validISO(payload.nextBillingAt)
              ? payload.nextBillingAt
              : addOneMonthISO(record.periodStart);
            record.currentAmount = typeof payload.amount === "number" ? payload.amount : 199;
            record.cancelAtPeriodEnd = false;
            record.cancelEffectiveAt = null;
          } else if (event === "creator_subscription.payment.failed") {
            record.status = typeof payload.status === "string" ? payload.status : "past_due";
          } else if (event === "creator_subscription.active") {
            record.status = "active";
          } else if (event === "creator_subscription.cancel_requested") {
            record.status = "cancel_requested";
            record.cancelAtPeriodEnd = true;
            record.cancelEffectiveAt = validISO(payload.cancelEffectiveAt)
              ? payload.cancelEffectiveAt
              : record.periodEnd;
          } else if (event === "creator_subscription.canceled") {
            record.status = "canceled";
            record.cancelAtPeriodEnd = false;
            record.cancelEffectiveAt = validISO(payload.canceledAt)
              ? payload.canceledAt
              : now().toISOString();
            record.periodEnd = record.cancelEffectiveAt;
          }
          await saveSubscription(anonymousID, record);
        }
      }
    }

    return new Response(null, { status: 204 });
  });

  app.post("/v1/chat/completions", async (c) => {
    const installation = authenticateInstallation(c.req.raw);
    if (!installation) return jsonError("Unauthorized installation.", 401);

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

    const status = await usageStatus(installation);
    const globalKey = status.isPro
      ? `global:pro:${status.metricDay}`
      : `global:${status.metricDay}`;

    let quotaResult: number[];
    try {
      quotaResult = (await redis.eval(
        QUOTA_SCRIPT,
        2,
        status.usageKey,
        globalKey,
        status.limit,
        status.isPro ? proGlobalCap : globalCap,
        RAW_RETENTION_SECONDS
      )) as number[];
    } catch {
      return jsonError("Usage service is temporarily unavailable.", 503);
    }

    if (Number(quotaResult[0]) === 2) {
      await recordUnique("quota_reached", status.metricDay, status.anonymousID);
      return jsonError(
        status.isPro
          ? `本期 Pro 額度已用完（每期 ${proMonthlyLimit} 次）。`
          : `今日免費額度已用完（每天 ${dailyLimit} 次）。`,
        429,
        {
          code: status.isPro ? "pro_quota_reached" : "daily_quota_reached",
          resets_at: status.resetsAt,
          used: Number(quotaResult[1]),
          limit: status.limit,
        }
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

    await recordUnique("app_active", status.metricDay, status.anonymousID);
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
    const totals = Object.fromEntries(await Promise.all(events.map(async (event) => [
      event,
      (await redis.sunion(...dates.map((date) => `metrics:${event}:${date}`))).length,
    ])));
    return json({ timeZone, days, totals });
  });

  return app;
}
