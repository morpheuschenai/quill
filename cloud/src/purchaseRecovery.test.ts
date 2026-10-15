import assert from "node:assert/strict";
import { test } from "node:test";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
import Redis from "ioredis";
import { createPurchaseRecovery, RecoveryError, resolveCanonicalInstallation, reconcilePendingCheckout, CHECKOUT_KNOWN_SCRIPT } from "./purchaseRecovery.ts";
import { createApp, BILLING_COMMIT_SCRIPT, CHECKOUT_RESERVE_SCRIPT, type QuillEnv } from "./server.ts";

const socket = process.env.REDIS_TEST_SOCKET;
const options = { skip: !socket && "REDIS_TEST_SOCKET is required", timeout: 15_000 };
const id = () => randomBytes(32).toString("hex");
async function fixture(run: (f: any) => Promise<void>) {
  const rawRedis = new Redis({ path: socket!, lazyConnect: true, retryStrategy: () => null });
  await rawRedis.connect();
  const prefix = `quill:recovery-test:${randomUUID()}:`;
  // Explicitly namespace EVAL keys too (ioredis keyPrefix alone does not cover
  // Lua's dynamically derived keys). Only test-owned exact keys are deleted.
  const redis: any = new Proxy(rawRedis, { get(target, property) {
    if (property === "eval") return (script: string, count: number, ...args: any[]) => target.eval(
      script.replaceAll('"subscription:alias:"', JSON.stringify(`${prefix}subscription:alias:`)), count,
      ...args.map((arg, i) => i < count ? prefix + arg : arg));
    if (property === "keys") return async (pattern: string) => (await target.keys(prefix + pattern)).map(k => k.slice(prefix.length));
    if (["get", "set", "ttl", "incr", "expire", "sadd", "scard"].includes(String(property))) return (key: string, ...args: any[]) => (target as any)[property](prefix + key, ...args);
    if (property === "sunion") return (...keys: string[]) => target.sunion(...keys.map(k => prefix + k));
    if (property === "del") return (...keys: string[]) => target.del(...keys.map(k => prefix + k));
    const value = (target as any)[property]; return typeof value === "function" ? value.bind(target) : value;
  } });
  const env: QuillEnv = { OPENAI_KEY: "fake", INSTALLATION_TOKEN_SECRET: randomUUID(), ANALYTICS_SALT: randomUUID(), PORTALY_API_KEY: "pcs_test_fake", PORTALY_PLAN_ID: "plan_test", EMAIL_RECOVERY_ENABLED: "true" };
  const device = id(), owner = id(), subscription = randomUUID(), email = `${randomUUID()}@example.com`;
  let time = new Date("2026-09-01T00:00:00Z"), sent: any, calls = 0, failure = false;
  const local = { subscriptionId: subscription, sessionId: subscription, planId: env.PORTALY_PLAN_ID, mode: "test", status: "active", periodStart: "2026-08-25T00:00:00Z", periodEnd: "2026-09-25T00:00:00Z" };
  const provider = { id: subscription, customerEmail: email, planId: env.PORTALY_PLAN_ID, mode: "test", status: "active", nextBillingAt: local.periodEnd };
  let page: any = { data: [provider], pagination: { hasMore: false, nextCursor: null } };
  const fetchImpl = (async (url: string) => { calls++; assert.equal(new URL(url).searchParams.get("customerEmail"), email); if (failure) throw Error("provider-private-details"); return Response.json(page); }) as typeof fetch;
  const now = () => time;
  const service = createPurchaseRecovery({ redis, env, fetchImpl, now, sendEmail: async (message) => { sent = message; } });
  await redis.set(`subscription:portaly:${subscription}`, owner);
  await redis.set(`subscription:installation:${owner}`, JSON.stringify(local));
  await redis.set(`usage:pro:${owner}:${local.periodStart}`, "37");
  const request = async () => service.request(device, id(), { email, language: "en" });
  const verify = (challenge: any, code = sent.code, who = device) => service.verify(who, { challenge_id: challenge.challenge_id, code });
  try { await run({ redis, env, service, device, owner, subscription, email, local, provider, request, verify, now, fetchImpl,
    sent: () => sent, calls: () => calls, time: (value: string) => { time = new Date(value); }, page: (value: any) => { page = value; }, failure: (value: boolean) => { failure = value; } }); }
  finally {
    const created = await rawRedis.keys(`${prefix}*`);
    if (created.length) await rawRedis.del(...created);
    rawRedis.disconnect();
  }
}
const error = (code: string) => (e: unknown) => e instanceof RecoveryError && e.code === code;

test("checkout route reconciles stored session, ignores user session ID, and permits new checkout", options, async () => fixture(async (f) => {
  let creates = 0, queries = 0, order = "";
  const app = createApp({ redis: f.redis, env: { ...f.env, PORTALY_CALLBACK_URL: "https://example.com/callback" }, now: f.now,
    fetchImpl: (async (url: string, init: any) => {
      if (init.method === "POST") {
        creates++; order = JSON.parse(init.body).merchantOrderNumber;
        return Response.json({ data: { sessionId: `provider_${creates}`, checkoutUrl: "https://example.com/pay", checkoutToken: "fake", expiresAt: "2026-09-02T00:00:00Z" } });
      }
      queries++; assert.ok(url.endsWith("/provider_1"));
      return Response.json({ data: { status: "expired", merchantOrderNumber: order, plan: { id: f.env.PORTALY_PLAN_ID } } });
    }) as typeof fetch });
  const installed = await app.request("/v1/installations", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ installation_id: randomUUID() }) });
  const { token } = await installed.json() as any;
  const checkout = () => app.request("/v1/billing/checkout", { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify({ session_id: "attacker_chosen" }) });
  assert.equal((await checkout()).status, 201);
  assert.equal((await checkout()).status, 201);
  assert.equal(creates, 2); assert.equal(queries, 1);
}));

test("verified recovery reconciles terminal checkout before committing alias", options, async () => fixture(async (f) => {
  await f.redis.set(`checkout:pending:${f.device}`, "order");
  await f.redis.set(`checkout:known:${f.device}`, JSON.stringify({ order: "order", sessionId: "stored", mode: "test", planId: f.env.PORTALY_PLAN_ID }));
  let code = "";
  const service = createPurchaseRecovery({ redis: f.redis, env: f.env, now: f.now, sendEmail: async message => { code = message.code; },
    fetchImpl: (async (url: string) => url.includes("/checkout-sessions/")
      ? Response.json({ data: { status: "canceled", merchantOrderNumber: "order", plan: { id: f.env.PORTALY_PLAN_ID } } })
      : f.fetchImpl(url)) as typeof fetch });
  const c = await service.request(f.device, id(), { email: f.email, language: "en" });
  assert.deepEqual(await service.verify(f.device, { challenge_id: c.challenge_id, code }), { restored: true });
  assert.equal(await f.redis.get(`subscription:alias:${f.device}`), f.owner);
}));

test("known checkout terminal reconciliation clears only matching terminal snapshots", options, async () => fixture(async (f) => {
  const pending = `checkout:pending:${f.device}`, known = `checkout:known:${f.device}`;
  for (const status of ["failed", "canceled", "expired", "completed", "checkout_ready", "unknown", "error", "wrong-order", "wrong-plan", "new-marker", "new-mapping"]) {
    await f.redis.del(`checkout:query:${f.device}`);
    await f.redis.set(pending, "order");
    await f.redis.set(known, JSON.stringify({ order: "order", sessionId: "stored_session", mode: "test", planId: f.env.PORTALY_PLAN_ID }));
    const fetcher = (async (url: string) => {
      assert.ok(url.endsWith("/checkout-sessions/stored_session"));
      if (status === "error") throw Error("outage");
      if (status === "new-marker") await f.redis.set(pending, "new-order");
      if (status === "new-mapping") await f.redis.set(known, "changed");
      return Response.json({ data: { status: ["new-marker", "new-mapping", "wrong-order", "wrong-plan"].includes(status) ? "expired" : status,
        merchantOrderNumber: status === "wrong-order" ? "wrong" : "order", plan: { id: status === "wrong-plan" ? "wrong" : f.env.PORTALY_PLAN_ID } } });
    }) as typeof fetch;
    await reconcilePendingCheckout(f.redis, f.env, f.device, fetcher, f.now);
    assert.equal(await f.redis.get(pending), ["failed", "canceled", "expired"].includes(status) ? null : status === "new-marker" ? "new-order" : "order");
  }
}));

test("checkout query is owner/global limited, respects Retry-After and ignores unbound sessions", options, async () => fixture(async (f) => {
  const seed = async (device: string) => {
    await f.redis.set(`checkout:pending:${device}`, "order");
    await f.redis.set(`checkout:known:${device}`, JSON.stringify({ order: "order", sessionId: "stored", mode: "test", planId: f.env.PORTALY_PLAN_ID }));
  };
  await seed(f.device); let calls = 0;
  const fetcher = (async () => { calls++; return Response.json({ data: { status: "completed" } }); }) as typeof fetch;
  await Promise.all(Array.from({ length: 5 }, () => reconcilePendingCheckout(f.redis, f.env, f.device, fetcher, f.now)));
  assert.equal(calls, 1);
  await f.redis.del(`checkout:query:${f.device}`);
  await f.redis.set("checkout:query:global", "60");
  await reconcilePendingCheckout(f.redis, f.env, f.device, fetcher, f.now); assert.equal(calls, 1);
  await f.redis.del("checkout:query:global");
  await reconcilePendingCheckout(f.redis, f.env, f.device, (async () => new Response(null, { status: 429, headers: { "Retry-After": "180" } })) as typeof fetch, f.now);
  assert.ok(await f.redis.ttl("checkout:query:backoff") >= 179);
  const second = id(); await seed(second);
  await reconcilePendingCheckout(f.redis, f.env, second, fetcher, f.now); assert.equal(calls, 1);
  await f.redis.del("checkout:query:backoff");
  await f.redis.set(`checkout:pending:${second}`, "new-order");
  await reconcilePendingCheckout(f.redis, f.env, second, fetcher, f.now); assert.equal(calls, 1);
  await f.redis.del(`checkout:known:${second}`);
  await reconcilePendingCheckout(f.redis, f.env, second, fetcher, f.now); assert.equal(calls, 1);
  assert.equal(await f.redis.eval(CHECKOUT_KNOWN_SCRIPT, 2, `checkout:pending:${second}`, `checkout:known:${second}`, "old-order", "{}"), 0);
  assert.equal(await f.redis.get(`checkout:known:${second}`), null);
}));

test("resend invalidates old codes and retains the aggregate guess budget", options, async () => fixture(async (f) => {
  const old = await f.request(), oldCode = f.sent().code;
  const wrong = oldCode === "000000" ? "111111" : "000000";
  for (let i = 0; i < 4; i++) await assert.rejects(f.verify(old, wrong), error("recovery_invalid_code"));
  for (const key of await f.redis.keys("recovery:cooldown:*")) await f.redis.del(key);
  const fresh = await f.request();
  await assert.rejects(f.verify(old, oldCode), error("recovery_invalid_code"));
  await assert.rejects(f.verify(fresh, f.sent().code === "000000" ? "111111" : "000000"), error("recovery_invalid_code"));
  await assert.rejects(f.verify(fresh), (e: any) => error("recovery_rate_limited")(e) && e.status === 429 && e.message.includes("one hour"));
  assert.equal(f.calls(), 0);
}));

test("pending checkout and recovery cannot both win, and marker has no unsafe expiry", options, async () => fixture(async (f) => {
  const c = await f.request();
  const reserve = () => f.redis.eval(CHECKOUT_RESERVE_SCRIPT, 3, `checkout:pending:${f.device}`, `subscription:alias:${f.device}`, `subscription:installation:${f.device}`, "order", "");
  assert.equal(await reserve(), 1);
  assert.equal(await f.redis.ttl(`checkout:pending:${f.device}`), -1);
  await assert.rejects(f.verify(c), error("recovery_conflict"));
  await f.redis.del(`checkout:pending:${f.device}`);
  await f.verify(c);
  assert.equal(await reserve(), 0);
}));

test("recovery commit CAS rejects changed source/index and existing canonical reassignment", options, async () => fixture(async (f) => {
  const c = await f.request();
  const originalEval = f.redis.eval;
  for (const target of [`subscription:portaly:${f.subscription}`, `subscription:installation:${f.owner}`]) {
    const saved = await f.redis.get(target);
    const wrapped = new Proxy(f.redis, { get(t, p) {
      if (p === "eval") return async (script: string, ...args: any[]) => {
        if (script.includes("recovery_commit_v1")) await f.redis.set(target, "changed");
        return originalEval(script, ...args);
      };
      return t[p];
    } });
    const service = createPurchaseRecovery({ redis: wrapped, env: f.env, now: f.now, fetchImpl: f.fetchImpl, sendEmail: async () => {} });
    await assert.rejects(service.verify(f.device, { challenge_id: c.challenge_id, code: f.sent().code }), error("recovery_conflict"));
    await f.redis.set(target, saved);
  }
  await f.redis.set(`subscription:canonical:${f.device}`, "1");
  await assert.rejects(f.verify(c), error("recovery_conflict"));
}));

test("OTP is private, cross-installation bound, five guesses maximum, and expiry enforced", options, async () => fixture(async (f) => {
  const c = await f.request();
  assert.deepEqual(Object.keys(c).sort(), ["challenge_id", "expires_in", "resend_after"]);
  const stored = await f.redis.get(`recovery:challenge:${c.challenge_id}`);
  assert.ok(!stored.includes(f.sent().code));
  assert.ok(await f.redis.ttl(`recovery:challenge:${c.challenge_id}`) <= 600);
  await assert.rejects(f.verify(c, f.sent().code, id()), error("recovery_invalid_code"));
  for (let i = 0; i < 5; i++) await assert.rejects(f.verify(c, f.sent().code === "000000" ? "111111" : "000000"), error("recovery_invalid_code"));
  await assert.rejects(f.verify(c), error("recovery_rate_limited"));
  assert.equal(f.calls(), 0);
}));
test("expired OTP cannot query provider", options, async () => fixture(async (f) => {
  const c = await f.request(); f.time("2026-09-01T00:10:00Z");
  await assert.rejects(f.verify(c), error("recovery_invalid_code")); assert.equal(f.calls(), 0);
}));
test("request limits atomically allow one concurrent email send", options, async () => fixture(async (f) => {
  const results = await Promise.allSettled([f.request(), f.request(), f.request()]);
  assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
  assert.ok(results.filter((r) => r.status === "rejected").every((r: any) => r.reason.code === "recovery_rate_limited"));
}));
test("device, IP and global limits block independently", options, async () => fixture(async (f) => {
  const ip = id();
  const ipHash = createHmac("sha256", f.env.INSTALLATION_TOKEN_SECRET).update(`recovery-ip:${ip}`).digest("hex");
  for (const [key, limit] of [[`recovery:device:${f.device}`, 5], [`recovery:ip:${ipHash}`, 20], ["recovery:global", 100]] as const) {
    const previous = await f.redis.get(key); await f.redis.set(key, String(limit));
    await assert.rejects(f.service.request(f.device, ip, { email: `${randomUUID()}@example.com`, language: "en" }), error("recovery_rate_limited"));
    if (previous === null) await f.redis.del(key); else await f.redis.set(key, previous);
  }
}));
test("sender failures remove challenge and expose no provider details; missing config fails closed", options, async () => fixture(async (f) => {
  const service = createPurchaseRecovery({ redis: f.redis, env: f.env, now: f.now, sendEmail: async () => { throw Error("private sender secret"); } });
  await assert.rejects(service.request(f.device, id(), { email: f.email, language: "en" }), (e: any) => e.status === 503 && !e.message.includes("secret"));
  assert.equal((await f.redis.keys("recovery:challenge:*")).length, 0);
  const unconfigured = createPurchaseRecovery({ redis: f.redis, env: f.env });
  await assert.rejects(unconfigured.request(f.device, id(), { email: f.email, language: "en" }), error("recovery_unavailable"));
}));
for (const field of ["customerEmail", "mode", "planId", "nextBillingAt"]) {
  test(`provider ${field} mismatch grants no entitlement`, options, async () => fixture(async (f) => {
    f.page({ data: [{ ...f.provider, [field]: "wrong" }], pagination: { hasMore: false } });
    await assert.rejects(f.verify(await f.request()), error("recovery_no_unique_purchase"));
    assert.equal(await f.redis.get(`subscription:alias:${f.device}`), null);
  }));
}
test("multiple candidates and incomplete/repeating pagination fail closed", options, async () => fixture(async (f) => {
  const c = await f.request();
  f.page({ data: [f.provider, { ...f.provider, id: randomUUID() }], pagination: { hasMore: false } });
  await assert.rejects(f.verify(c), error("recovery_no_unique_purchase"));
  f.page({ data: [f.provider], pagination: { hasMore: true, nextCursor: "same" } });
  await assert.rejects(f.verify(c), error("recovery_unavailable"));
}));
test("unknown or mismatched local subscription cannot be constructed from provider data", options, async () => fixture(async (f) => {
  const c = await f.request();
  await f.redis.set(`subscription:installation:${f.owner}`, JSON.stringify({ ...f.local, subscriptionId: "other" }));
  await assert.rejects(f.verify(c), error("recovery_not_linked"));
  await f.redis.del(`subscription:portaly:${f.subscription}`);
  await assert.rejects(f.verify(c), error("recovery_not_linked"));
}));
test("transient provider failures allow retry; concurrent successful verify consumes once", options, async () => fixture(async (f) => {
  const c = await f.request(); f.failure(true);
  await assert.rejects(f.verify(c), error("recovery_unavailable")); f.failure(false);
  const results = await Promise.allSettled([f.verify(c), f.verify(c)]);
  assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
  await assert.rejects(f.verify(c), error("recovery_invalid_code"));
  assert.equal(await resolveCanonicalInstallation(f.redis, f.device), f.owner);
  assert.equal(await f.redis.get(`subscription:installation:${f.device}`), null);
  assert.equal(await f.redis.get(`usage:pro:${f.owner}:${f.local.periodStart}`), "37");
  assert.deepEqual(JSON.parse(await f.redis.get(`subscription:installation:${f.owner}`)), f.local);
}));
test("existing entitlement and alias chains are rejected", options, async () => fixture(async (f) => {
  const c = await f.request();
  await f.redis.set(`subscription:installation:${f.device}`, JSON.stringify({ ...f.local, subscriptionId: "different" }));
  await assert.rejects(f.verify(c), error("recovery_conflict"));
  await f.redis.del(`subscription:installation:${f.device}`);
  await f.redis.set(`subscription:alias:${f.owner}`, id());
  await assert.rejects(f.verify(c), error("recovery_conflict"));
}));
test("two authenticated installations share original period and metered usage after recovery", options, async () => fixture(async (f) => {
  const app = createApp({ redis: f.redis, env: f.env, now: f.now, fetchImpl: (async () => Response.json({ choices: [{ message: { content: "ok" } }] })) as typeof fetch, sendRecoveryEmail: async () => {} });
  const install = async (installationID: string) => {
    const res = await app.request("/v1/installations", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ installation_id: installationID }) });
    return await res.json() as any;
  };
  const originalID = randomUUID(), newID = randomUUID();
  const original = await install(originalID), replacement = await install(newID);
  const owner = createHmac("sha256", f.env.ANALYTICS_SALT).update(originalID).digest("hex");
  const device = createHmac("sha256", f.env.ANALYTICS_SALT).update(newID).digest("hex");
  await f.redis.set(`subscription:portaly:${f.subscription}`, owner);
  await f.redis.set(`subscription:installation:${owner}`, JSON.stringify(f.local));
  await f.redis.set(`usage:pro:${owner}:${f.local.periodStart}`, "37");
  const c = await f.service.request(device, id(), { email: f.email, language: "en" });
  await f.service.verify(device, { challenge_id: c.challenge_id, code: f.sent().code });
  const status = async (token: string) => (await app.request("/v1/billing/status", { headers: { Authorization: `Bearer ${token}` } })).json();
  assert.equal(original.token !== undefined, true);
  assert.deepEqual(await status(original.token), await status(replacement.token));
  const s = await status(replacement.token) as any; assert.equal(s.used, 37); assert.equal(s.resets_at, f.local.periodEnd);
  await f.redis.incr(`usage:pro:${owner}:${f.local.periodStart}`);
  assert.equal((await status(original.token) as any).used, 38);
  assert.equal((await status(replacement.token) as any).used, 38);
  // A pending checkout on the replacement device must fail closed after linking.
  assert.equal(await f.redis.eval(BILLING_COMMIT_SCRIPT, 4, `subscription:installation:${device}`, `subscription:portaly:${randomUUID()}`, `test:receipts:${device}`, `test:metrics:${device}`, "{}", device, "receipt", "", 3600, ""), -1);
}));
