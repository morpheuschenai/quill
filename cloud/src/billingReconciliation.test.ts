import assert from "node:assert/strict";
import { test } from "node:test";
import { createHmac, randomUUID } from "node:crypto";
import Redis from "ioredis";
import { createApp, type QuillEnv } from "./server.ts";
import { reconcileBilling } from "./billingReconciliation.ts";
import { createPurchaseRecovery } from "./purchaseRecovery.ts";
import { signPortalyCallback } from "./portalyCallback.mjs";

const options = { skip: !process.env.REDIS_TEST_SOCKET && "REDIS_TEST_SOCKET required", timeout: 15_000 };
async function fixture(run: (f: any) => Promise<void>) {
  const raw = new Redis({ path: process.env.REDIS_TEST_SOCKET!, lazyConnect: true, retryStrategy: () => null });
  await raw.connect();
  const prefix = `quill:reconcile-test:${randomUUID()}:`;
  const redis: any = new Proxy(raw, { get(t, p) {
    if (p === "eval") return (script: string, count: number, ...args: any[]) => t.eval(script.replaceAll('"subscription:alias:"', JSON.stringify(prefix + "subscription:alias:")), count, ...args.map((a, i) => i < count ? prefix + a : a));
    if (["get", "set", "ttl", "incr", "expire", "sadd", "scard"].includes(String(p))) return (key: string, ...args: any[]) => (t as any)[p](prefix + key, ...args);
    if (p === "del") return (...keys: string[]) => t.del(...keys.map(k => prefix + k));
    const value = (t as any)[p]; return typeof value === "function" ? value.bind(t) : value;
  } });
  const env: QuillEnv = { OPENAI_KEY: "fake", INSTALLATION_TOKEN_SECRET: "fixture", ANALYTICS_SALT: "fixture", PORTALY_API_KEY: "pcs_test_fake", PORTALY_PLAN_ID: "plan", PORTALY_CALLBACK_URL: "https://example.com/portaly", PORTALY_CALLBACK_SECRET: "fixture" };
  const installation = randomUUID(), owner = createHmac("sha256", env.ANALYTICS_SALT).update(installation).digest("hex");
  const session = "stored_" + randomUUID();
  const sub = { id: session, planId: "plan", mode: "test", billingPeriod: "monthly", status: "active", cancelAtPeriodEnd: false, lastChargedAt: "2026-09-01T00:00:00Z", nextBillingAt: "2026-10-01T00:00:00Z", lastPaymentReference: "payment_new" };
  const local = { subscriptionId: session, sessionId: session, planId: "plan", mode: "test", status: "active", periodStart: "2026-08-01T00:00:00Z", periodEnd: "2026-09-01T00:00:00Z", cancelAtPeriodEnd: false, cancelEffectiveAt: null, currentAmount: 149 };
  const now = () => new Date("2026-09-05T00:00:00Z");
  const key = `subscription:installation:${owner}`;
  const calls: string[] = [];
  let respond: (url: string) => Promise<Response> = async url => Response.json({ data: url.includes("checkout-sessions") ? { status: "completed", merchantOrderNumber: "order", plan: { id: "plan" }, amount: 149 } : sub });
  const fetchImpl = (async (url: string) => { calls.push(url); return respond(url); }) as typeof fetch;
  const app = createApp({ redis, env, now, fetchImpl });
  const registered = await (await app.request("/v1/installations", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ installation_id: installation }) })).json() as any;
  const headers = { Authorization: `Bearer ${registered.token}` };
  const seed = async (pending = false) => {
    if (pending) {
      await redis.set(`checkout:pending:${owner}`, "order");
      await redis.set(`checkout:known:${owner}`, JSON.stringify({ order: "order", sessionId: session, mode: "test", planId: "plan" }));
    } else {
      await redis.set(key, JSON.stringify(local));
      await redis.set(`subscription:portaly:${session}`, owner);
    }
  };
  const callback = async (event: string, data: any) => {
    const payload = { event, mode: "test", planId: "plan", subscriptionId: session, ...data };
    const timestamp = now().toISOString();
    return app.request("/v1/webhooks/portaly", { method: "POST", headers: { "content-type": "application/json", "x-portaly-event": event, "x-portaly-timestamp": timestamp, "x-portaly-signature": signPortalyCallback({ secret: env.PORTALY_CALLBACK_SECRET!, timestamp, payload }) }, body: JSON.stringify(payload) });
  };
  try { await run({ redis, env, owner, session, sub, local, key, seed, calls, now, headers, app, callback, fetchImpl, respond: (fn: typeof respond) => { respond = fn; }, reconcile: () => reconcileBilling(redis, env, owner, fetchImpl, now), read: async () => JSON.parse(await redis.get(key)), clear: () => redis.del(`checkout:query:${owner}`) }); }
  finally { const keys = await raw.keys(prefix + "*"); if (keys.length) await raw.del(...keys); raw.disconnect(); }
}

test("status reconciles completed bound checkout with exact paid period and reverse owner", options, async () => fixture(async f => {
  await f.seed(true);
  const response = await f.app.request("/v1/billing/status?session_id=attacker", { headers: f.headers });
  const status = await response.json();
  assert.equal(status.plan, "pro"); assert.equal(status.recovery_enabled, false);
  assert.equal(status.resets_at, "2026-10-01T00:00:00.000Z");
  assert.equal(f.calls.length, 2); assert.ok(f.calls.every((u: string) => u.endsWith(f.session)));
  assert.equal(await f.redis.get(`subscription:portaly:${f.session}`), f.owner);
  assert.equal(await f.redis.get(`checkout:pending:${f.owner}`), null);
}));

test("renewal reconciliation preserves usage on repeated formatting drift and late checkout", options, async () => fixture(async f => {
  await f.seed(); await f.reconcile();
  const paid = await f.read(), usage = `usage:pro:${f.owner}:${paid.periodStart}`;
  await f.redis.set(usage, "37"); await f.clear();
  f.sub.lastChargedAt = "2026-09-01T08:00:00+08:00";
  await f.reconcile(); assert.equal((await f.read()).periodStart, paid.periodStart);
  assert.equal(await f.redis.get(usage), "37");
  const late = await f.callback("creator_subscription.checkout.completed", { sessionId: f.session, status: "completed", completedAt: f.local.periodStart, metadata: { installationHash: f.owner }, merchantOrderNumber: "order", amount: 149 });
  assert.equal(late.status, 204); assert.equal((await f.read()).periodStart, paid.periodStart);
  const duplicate = await f.callback("creator_subscription.payment.succeeded", { status: "active", paymentId: "renewal", paymentReference: "payment_new", chargedAt: f.sub.lastChargedAt, nextBillingAt: f.sub.nextBillingAt });
  assert.equal(duplicate.status, 204); assert.equal((await f.read()).periodStart, paid.periodStart);
  assert.equal(await f.redis.get(usage), "37");
}));

test("missed renewal is reconciled before checkout and blocks a duplicate subscription", options, async () => fixture(async f => {
  await f.seed();
  const response = await f.app.request("/v1/billing/checkout", { method: "POST", headers: f.headers });
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error.code, "PRO_ALREADY_ACTIVE");
  assert.equal((await f.read()).periodStart, "2026-09-01T00:00:00.000Z");
  assert.equal(f.calls.length, 1);

  await f.redis.set(f.key, JSON.stringify(f.local));
  await f.clear(); f.calls.length = 0;
  f.respond(async () => new Response(null, { status: 503 }));
  const unresolved = await f.app.request("/v1/billing/checkout", { method: "POST", headers: f.headers });
  assert.equal(unresolved.status, 409);
  assert.equal((await unresolved.json()).error.code, "CHECKOUT_PENDING");
  assert.equal(f.calls.length, 1);
}));

test("missed renewal merges paid period while preserving a newer cancellation", options, async () => fixture(async f => {
  await f.seed();
  assert.equal((await f.callback("creator_subscription.cancel_requested", {
    cancelRequestedAt: "2026-09-04T00:00:00Z", cancelEffectiveAt: f.sub.nextBillingAt,
  })).status, 204);
  await f.clear(); await f.reconcile();
  const record = await f.read();
  assert.equal(record.periodStart, "2026-09-01T00:00:00.000Z");
  assert.equal(record.periodEnd, "2026-10-01T00:00:00.000Z");
  assert.equal(record.status, "cancel_requested");
  assert.equal(record.cancelAtPeriodEnd, true);
  assert.equal(record.cancelEffectiveAt, "2026-10-01T00:00:00Z");
  assert.equal(record.lastEventAt, "2026-09-04T00:00:00Z");
  assert.equal(record.lastPaymentReference, "payment_new");
}));

test("missed renewal merges paid period while preserving a newer resume", options, async () => fixture(async f => {
  await f.seed();
  assert.equal((await f.callback("creator_subscription.cancel_requested", {
    cancelRequestedAt: "2026-09-04T00:00:00Z", cancelEffectiveAt: f.sub.nextBillingAt,
  })).status, 204);
  assert.equal((await f.callback("creator_subscription.active", {})).status, 204);
  f.sub.cancelAtPeriodEnd = true;
  f.sub.cancelEffectiveAt = f.sub.nextBillingAt;
  await f.clear(); await f.reconcile();
  const record = await f.read();
  assert.equal(record.periodStart, "2026-09-01T00:00:00.000Z");
  assert.equal(record.periodEnd, "2026-10-01T00:00:00.000Z");
  assert.equal(record.status, "active");
  assert.equal(record.cancelAtPeriodEnd, false);
  assert.equal(record.cancelEffectiveAt, null);
  assert.equal(record.lastEventAt, "2026-09-05T00:00:00.000Z");
  assert.equal(record.lastPaymentReference, "payment_new");
}));

test("provider failure, malformed fields and ownership/mode mismatch never grant", options, async () => fixture(async f => {
  await f.seed(true);
  for (const mutation of [{ mode: "live" }, { planId: "wrong" }, { id: "other" }, { lastChargedAt: null }, { lastPaymentReference: null }, { nextBillingAt: null }, { billingPeriod: "one-time" }]) {
    await f.clear();
    f.respond(async (url: string) => Response.json({ data: url.includes("checkout-sessions") ? { status: "completed", merchantOrderNumber: "order", plan: { id: "plan" } } : { ...f.sub, ...mutation } }));
    await f.reconcile(); assert.equal(await f.redis.get(f.key), null);
  }
  await f.clear(); f.respond(async () => { throw Error("timeout"); }); await f.reconcile();
  assert.equal(await f.redis.get(f.key), null); assert.equal(await f.redis.get(`checkout:pending:${f.owner}`), "order");
  await f.clear(); await f.redis.set(`subscription:portaly:${f.session}`, "other_owner");
  const count = f.calls.length; await f.reconcile(); assert.equal(f.calls.length, count);
}));

test("concurrent refresh reserves one query and cannot overwrite racing callback/canonical link", options, async () => fixture(async f => {
  await f.seed(); await Promise.all([f.reconcile(), f.reconcile(), f.reconcile()]); assert.equal(f.calls.length, 1);
  for (const target of [f.key, `subscription:portaly:${f.session}`, `subscription:alias:${f.owner}`, `checkout:pending:${f.owner}`]) {
    await f.seed(); await f.clear();
    const before = await f.redis.get(target);
    f.respond(async () => { await f.redis.set(target, "racing_change"); return Response.json({ data: f.sub }); });
    await f.reconcile(); assert.equal(await f.redis.get(target), "racing_change");
    if (target !== f.key) assert.equal((await f.read()).periodStart, f.local.periodStart);
    if (before === null) await f.redis.del(target); else await f.redis.set(target, before);
  }
}));

test("stale charge/query cannot undo newer cancellation and stale period cannot regress renewal", options, async () => fixture(async f => {
  await f.seed(); await f.reconcile();
  assert.equal((await f.callback("creator_subscription.cancel_requested", { cancelRequestedAt: "2026-09-04T00:00:00Z", cancelEffectiveAt: f.sub.nextBillingAt })).status, 204);
  await f.clear(); await f.reconcile(); assert.equal((await f.read()).cancelAtPeriodEnd, true);
  assert.equal((await f.callback("creator_subscription.payment.succeeded", { paymentReference: "old", chargedAt: f.sub.lastChargedAt, nextBillingAt: f.sub.nextBillingAt })).status, 204);
  assert.equal((await f.read()).cancelAtPeriodEnd, true);
  await f.clear(); f.sub.lastChargedAt = f.local.periodStart; f.sub.nextBillingAt = f.local.periodEnd;
  await f.reconcile(); assert.equal((await f.read()).periodStart, "2026-09-01T00:00:00.000Z");
}));

test("shared read budget counts both checkout reads and honors subscription Retry-After", options, async () => fixture(async f => {
  await f.seed(true); await f.redis.set("checkout:query:global", "59"); await f.reconcile();
  assert.equal(f.calls.length, 1); assert.equal(await f.redis.get(f.key), null);
  await f.clear(); await f.redis.del("checkout:query:global");
  f.respond(async (url: string) => url.includes("checkout-sessions") ? Response.json({ data: { status: "completed", merchantOrderNumber: "order", plan: { id: "plan" } } }) : new Response(null, { status: 429, headers: { "Retry-After": "180" } }));
  await f.reconcile(); assert.ok(await f.redis.ttl("checkout:query:backoff") >= 179);
  await f.clear(); const count = f.calls.length; await f.reconcile(); assert.equal(f.calls.length, count);
}));

test("email recovery default gate rejects request/verify before sender/provider access", options, async () => fixture(async f => {
  const service = createPurchaseRecovery({ redis: f.redis, env: f.env, fetchImpl: f.fetchImpl, sendEmail: async () => { throw Error("must not send"); } });
  for (const action of ["request", "verify"] as const) {
    const response = await f.app.request(`/v1/billing/recovery/${action}`, { method: "POST", headers: f.headers, body: "not JSON" });
    assert.equal(response.status, 503);
    await assert.rejects(action === "request" ? service.request(f.owner, "ip", {}) : service.verify(f.owner, {}), (e: any) => e.status === 503);
  }
  assert.equal(f.calls.length, 0);
}));

test("signed cancellation racing a provider response wins atomic snapshot commit", options, async () => fixture(async f => {
  await f.seed();
  f.respond(async () => {
    assert.equal((await f.callback("creator_subscription.cancel_requested", { cancelRequestedAt: "2026-09-04T00:00:00Z", cancelEffectiveAt: f.local.periodEnd })).status, 204);
    return Response.json({ data: f.sub });
  });
  await f.reconcile();
  assert.equal((await f.read()).cancelAtPeriodEnd, true);
  assert.equal((await f.read()).periodStart, f.local.periodStart);
}));

test("canceled provider state takes precedence, requires cancellation evidence, and stale cancel cannot undo resume", options, async () => fixture(async f => {
  await f.seed(); await f.reconcile();
  const paid = await f.read();
  f.sub.status = "canceled"; f.sub.cancelAtPeriodEnd = true; f.sub.cancelEffectiveAt = f.sub.nextBillingAt;
  await f.clear(); await f.reconcile(); assert.equal((await f.read()).status, "active");
  f.sub.canceledAt = "2026-09-02T00:00:00Z";
  await f.redis.set(f.key, JSON.stringify({ ...paid, lastEventAt: "2026-09-04T00:00:00Z" }));
  await f.clear(); await f.reconcile(); assert.equal((await f.read()).status, "active");
  f.sub.canceledAt = "2026-09-05T00:00:00Z";
  await f.clear(); await f.reconcile(); assert.equal((await f.read()).status, "canceled");
  assert.equal((await (await f.app.request("/v1/billing/status", { headers: f.headers })).json()).plan, "free");
  assert.equal((await f.callback("creator_subscription.active", {})).status, 204);
  assert.equal((await f.read()).status, "canceled");
}));

test("unknown checkout without server ID and provider outages preserve known status", options, async () => fixture(async f => {
  await f.redis.set(`checkout:pending:${f.owner}`, "unknown"); await f.reconcile(); assert.equal(f.calls.length, 0);
  await f.redis.del(`checkout:pending:${f.owner}`); await f.seed();
  const saved = await f.redis.get(f.key);
  for (const status of [401, 403, 404, 500]) {
    await f.clear(); f.respond(async () => new Response(null, { status })); await f.reconcile();
    assert.equal(await f.redis.get(f.key), saved);
  }
}));

test("status on recovered alias reconciles only canonical subscription and keeps quota shared", options, async () => fixture(async f => {
  const canonical = "c".repeat(64);
  await f.redis.set(`subscription:alias:${f.owner}`, canonical);
  await f.redis.set(`subscription:installation:${canonical}`, JSON.stringify(f.local));
  await f.redis.set(`subscription:portaly:${f.session}`, canonical);
  const response = await f.app.request("/v1/billing/status", { headers: f.headers });
  assert.equal((await response.json()).plan, "pro");
  assert.equal(await f.redis.get(f.key), null);
  const paid = JSON.parse(await f.redis.get(`subscription:installation:${canonical}`));
  await f.redis.set(`usage:pro:${canonical}:${paid.periodStart}`, "29");
  assert.equal((await (await f.app.request("/v1/billing/status", { headers: f.headers })).json()).used, 29);
}));
