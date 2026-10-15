import type { QuillEnv, RedisLike } from "./server.ts";

const parse = (raw: string | null) => { try { return JSON.parse(raw || "null"); } catch { return null; } };
const stamp = (value: unknown): number => typeof value === "string" ? Date.parse(value) : NaN;
const idOK = (value: unknown): value is string => typeof value === "string" && /^[A-Za-z0-9_-]{1,200}$/.test(value);
const subKey = (owner: string) => `subscription:installation:${owner}`;

// One budget for every provider read, including email recovery pagination.
// Reserve before I/O; failures keep their reservation. 60 leaves provider headroom.
export async function providerRead(redis: RedisLike, env: QuillEnv, path: string, fetchImpl: typeof fetch, now: () => Date, envelope = false) {
  const reserved = await redis.eval(`
    if redis.call("EXISTS", KEYS[2]) == 1 then return 0 end
    if tonumber(redis.call("GET", KEYS[1]) or "0") >= 60 then return 0 end
    if redis.call("INCR", KEYS[1]) == 1 then redis.call("EXPIRE", KEYS[1], 60) end
    return 1`, 2, "checkout:query:global", "checkout:query:backoff");
  if (Number(reserved) !== 1) return null;
  const response = await fetchImpl(new URL(path, env.PORTALY_API_HOST || "https://portaly.ai").toString(), {
    headers: { Authorization: `Bearer ${env.PORTALY_API_KEY}` }, signal: AbortSignal.timeout(10_000),
  });
  if (response.status === 429) {
    const retry = response.headers.get("Retry-After") || "60";
    const seconds = /^\d+$/.test(retry) ? Number(retry) : Math.ceil((Date.parse(retry) - now().getTime()) / 1000);
    const delay = Number.isFinite(seconds) ? Math.max(60, seconds) : 60;
    await redis.eval('local t = redis.call("TTL", KEYS[1]); if t < tonumber(ARGV[1]) then redis.call("SET", KEYS[1], "1", "EX", ARGV[1]) end; return 1', 1, "checkout:query:backoff", delay);
    return null;
  }
  if (!response.ok) return null;
  const body = await response.json() as any;
  return envelope ? body : body?.data;
}

export const RECONCILE_COMMIT_SCRIPT = `
-- billing_reconcile_v1
for i = 1, #KEYS do
  local kind = redis.call("TYPE", KEYS[i]).ok
  if kind ~= "none" and kind ~= "string" then return redis.error_reply("Invalid reconciliation key type") end
end
if redis.call("EXISTS", KEYS[5]) == 1 then return 0 end
if (redis.call("GET", KEYS[1]) or "") ~= ARGV[1] then return 0 end
if (redis.call("GET", KEYS[2]) or "") ~= ARGV[2] then return 0 end
if (redis.call("GET", KEYS[3]) or "") ~= ARGV[3] then return 0 end
if (redis.call("GET", KEYS[4]) or "") ~= ARGV[4] then return 0 end
redis.call("SET", KEYS[1], ARGV[5])
redis.call("SET", KEYS[2], ARGV[6])
if ARGV[3] ~= "" then redis.call("DEL", KEYS[3], KEYS[4]) end
return 1
`;

// Caller supplies only its authenticated, canonical installation. Never accept
// a client-supplied session ID. Unknown checkout outcomes remain support-only.
export async function reconcileBilling(redis: RedisLike, env: QuillEnv, owner: string, fetchImpl: typeof fetch, now: () => Date, pendingOnly = false) {
  try {
    if (!/^pcs_(live|test)_/.test(env.PORTALY_API_KEY || "") || !env.PORTALY_PLAN_ID) return;
    if (await redis.get(`subscription:alias:${owner}`)) return;
    const mode = env.PORTALY_API_KEY!.startsWith("pcs_live_") ? "live" : "test";
    const raw = await redis.get(subKey(owner)), old = parse(raw);
    const pendingKey = `checkout:pending:${owner}`, knownKey = `checkout:known:${owner}`;
    const order = await redis.get(pendingKey), knownRaw = await redis.get(knownKey), known = parse(knownRaw);
    let session: string;
    if (order) {
      if (!known || known.order !== order || known.mode !== mode || known.planId !== env.PORTALY_PLAN_ID || !idOK(known.sessionId)) return;
      session = known.sessionId;
      if (old && old.subscriptionId !== session) return;
    } else {
      if (pendingOnly || !old || !idOK(old.subscriptionId) || old.planId !== env.PORTALY_PLAN_ID || old.mode !== mode) return;
      session = old.subscriptionId;
    }
    const indexKey = `subscription:portaly:${session}`, index = await redis.get(indexKey);
    if (index && index !== owner || !order && index !== owner) return;
    const allowed = await redis.eval(`
      if redis.call("EXISTS", KEYS[1]) == 1 or redis.call("EXISTS", KEYS[3]) == 1 then return 0 end
      if tonumber(redis.call("GET", KEYS[2]) or "0") >= 60 then return 0 end
      redis.call("SET", KEYS[1], "1", "EX", 60); return 1`, 3, `checkout:query:${owner}`, "checkout:query:global", "checkout:query:backoff");
    if (Number(allowed) !== 1) return;
    let checkout: any;
    if (order) {
      checkout = await providerRead(redis, env, `/api/creator-subscription/checkout-sessions/${encodeURIComponent(session)}`, fetchImpl, now);
      if (!checkout || checkout.merchantOrderNumber !== order || checkout.plan?.id !== env.PORTALY_PLAN_ID || checkout.mode != null && checkout.mode !== mode) return;
      if (["failed", "canceled", "expired"].includes(checkout.status)) {
        await redis.eval('if redis.call("GET", KEYS[1]) ~= ARGV[1] or redis.call("GET", KEYS[2]) ~= ARGV[2] then return 0 end; return redis.call("DEL", KEYS[1], KEYS[2])', 2, pendingKey, knownKey, order, knownRaw!);
        return;
      }
      if (checkout.status !== "completed") return;
    }
    const sub = await providerRead(redis, env, `/api/creator-subscription/subscriptions/${encodeURIComponent(session)}`, fetchImpl, now);
    if (!sub || sub.id !== session || sub.planId !== env.PORTALY_PLAN_ID || sub.mode !== mode || !["monthly", "yearly"].includes(sub.billingPeriod) || !["active", "past_due", "canceled"].includes(sub.status)) return;
    const start = stamp(sub.lastChargedAt), end = stamp(sub.nextBillingAt);
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start || start > now().getTime() || typeof sub.lastPaymentReference !== "string" || !sub.lastPaymentReference || typeof sub.cancelAtPeriodEnd !== "boolean") return;
    if (old && (!Number.isFinite(stamp(old.periodStart)) || start < stamp(old.periodStart) || end < stamp(old.periodEnd))) return;
    // A query has no revision timestamp. Never clear a locally known lifecycle
    // event merely because a replica returns an older lifecycle state. A paid
    // period advance is still authoritative for the billing period itself: this
    // covers a missed renewal callback followed by cancel/resume callbacks.
    const samePeriod = old && start === stamp(old.periodStart);
    const lifecycleIsNewer = Boolean(old && !samePeriod && start > stamp(old.periodStart) &&
      Number.isFinite(stamp(old.lastEventAt)) && stamp(old.lastEventAt) >= start);
    if (!lifecycleIsNewer && (old?.status === "canceled" || old?.cancelAtPeriodEnd && sub.cancelAtPeriodEnd !== true)) return;
    const canceledAt = stamp(sub.canceledAt);
    if (!lifecycleIsNewer && sub.status === "canceled" && (!Number.isFinite(canceledAt) || canceledAt < Math.max(start, stamp(old?.lastEventAt) || start) || canceledAt > now().getTime())) return;
    const cancelEffectiveAt = Number.isFinite(stamp(sub.cancelEffectiveAt)) ? sub.cancelEffectiveAt : null;
    if (!lifecycleIsNewer && sub.cancelAtPeriodEnd && !cancelEffectiveAt) return;
    const record = {
      subscriptionId: session, sessionId: session, planId: env.PORTALY_PLAN_ID, mode,
      status: lifecycleIsNewer ? old.status : sub.status === "canceled" ? "canceled" : sub.cancelAtPeriodEnd ? "cancel_requested" : samePeriod && old.status === "past_due" && sub.status === "active" ? old.status : sub.status,
      periodStart: samePeriod ? old.periodStart : new Date(start).toISOString(),
      periodEnd: samePeriod && end === stamp(old.periodEnd) ? old.periodEnd : new Date(end).toISOString(),
      // Subscription query has no documented last-charge amount. The original
      // checkout amount may be promotional and must not label a later renewal.
      currentAmount: samePeriod ? old.currentAmount ?? null : null,
      cancelAtPeriodEnd: lifecycleIsNewer ? old.cancelAtPeriodEnd : sub.cancelAtPeriodEnd,
      cancelEffectiveAt: lifecycleIsNewer ? old.cancelEffectiveAt : cancelEffectiveAt,
      lastPaymentReference: sub.lastPaymentReference,
      lastEventAt: lifecycleIsNewer ? old.lastEventAt : sub.status === "canceled" ? new Date(canceledAt).toISOString() : old?.lastEventAt && stamp(old.lastEventAt) > start ? old.lastEventAt : new Date(start).toISOString(),
    };
    await redis.eval(RECONCILE_COMMIT_SCRIPT, 5, subKey(owner), indexKey, pendingKey, knownKey, `subscription:alias:${owner}`,
      raw || "", index || "", order || "", knownRaw || "", JSON.stringify(record), owner);
  } catch { /* Retain the known entitlement and pending guard on any uncertainty. */ }
}

export const reconcilePendingCheckout = (redis: RedisLike, env: QuillEnv, owner: string, fetchImpl: typeof fetch, now: () => Date) => reconcileBilling(redis, env, owner, fetchImpl, now, true);
