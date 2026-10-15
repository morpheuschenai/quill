import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { createApp, type QuillEnv, type RedisLike } from "./server.ts";
import { signPortalyCallback } from "./portalyCallback.mjs";
import { meteredResponseStream } from "./responseStream.ts";

type MockRedis = RedisLike & {
  counters: Map<string, number>;
  sets: Map<string, Set<string>>;
  values: Map<string, string>;
};

function mockRedis(): MockRedis {
  const counters = new Map<string, number>();
  const sets = new Map<string, Set<string>>();
  const values = new Map<string, string>();
  return {
    counters,
    sets,
    values,
    async get(key: string) {
      if (values.has(key)) return values.get(key) || null;
      const counter = counters.get(key);
      return counter === undefined ? null : String(counter);
    },
    async set(key: string, value: string) {
      values.set(key, value);
      return "OK";
    },
    async incr(key: string) {
      const value = (counters.get(key) || 0) + 1;
      counters.set(key, value);
      return value;
    },
    async expire() {
      return 1;
    },
    async sadd(key: string, ...members: string[]) {
      const set = sets.get(key) || new Set<string>();
      const before = set.size;
      members.forEach((member) => set.add(member));
      sets.set(key, set);
      return set.size - before;
    },
    async scard(key: string) {
      return sets.get(key)?.size || 0;
    },
    async sunion(...keys: string[]) {
      const result = new Set<string>();
      keys.forEach((key) => sets.get(key)?.forEach((member) => result.add(member)));
      return [...result];
    },
    async eval(_script, _numberOfKeys, deviceKey, globalKey, dailyLimit, globalLimit, ...args) {
      if (_script.includes("checkout_known_v1")) {
        if (values.get(String(deviceKey)) !== String(dailyLimit)) return 0;
        values.set(String(globalKey), String(globalLimit)); return 1;
      }
      if (_script.includes("checkout_reserve_v1")) {
        if (values.has(String(deviceKey)) || values.has(String(globalKey))) return 0;
        if ((values.get(String(dailyLimit)) || "") !== String(args[0])) return 0;
        values.set(String(deviceKey), String(globalLimit)); return 1;
      }
      if (_script.includes("checkout_release_v1")) {
        if (values.get(String(deviceKey)) !== String(globalKey)) return 0;
        values.delete(String(deviceKey)); return 1;
      }
      if (_script.includes("quota_refund_v1")) {
        if (values.has(String(dailyLimit))) return 0;
        for (const key of [String(deviceKey), String(globalKey)]) {
          counters.set(key, Math.max(0, (counters.get(key) || 0) - 1));
        }
        values.set(String(dailyLimit), "1");
        return 1;
      }
      if (_script.includes("billing_commit_v1")) {
        const [record, identity, receipt, previous, _ttl, metric] = args.map(String);
        if (values.has(`subscription:alias:${identity}`)) return -1;
        const receipts = sets.get(String(dailyLimit)) || new Set<string>();
        if (receipt && receipts.has(receipt)) return 0;
        if (values.has(String(globalKey)) && values.get(String(globalKey)) !== identity) return -1;
        if ((values.get(String(deviceKey)) || "") !== previous) return -1;
        values.set(String(deviceKey), record);
        values.set(String(globalKey), identity);
        if (receipt) { receipts.add(receipt); sets.set(String(dailyLimit), receipts); }
        if (metric) {
          const metrics = sets.get(String(globalLimit)) || new Set<string>();
          metrics.add(metric); sets.set(String(globalLimit), metrics);
        }
        return 1;
      }
      const deviceUsed = counters.get(String(deviceKey)) || 0;
      const globalUsed = counters.get(String(globalKey)) || 0;
      if (deviceUsed >= Number(dailyLimit)) return [2, deviceUsed, globalUsed];
      if (globalUsed >= Number(globalLimit)) return [3, deviceUsed, globalUsed];
      counters.set(String(deviceKey), deviceUsed + 1);
      counters.set(String(globalKey), globalUsed + 1);
      return [1, deviceUsed + 1, globalUsed + 1];
    },
  };
}

function mockFetch(status = 200) {
  const calls: any[] = [];
  const fn = async (url: any, init: any) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return new Response('data: {"choices":[{"delta":{"content":"Answer"}}]}\n\ndata: [DONE]\n\n', { status });
  };
  return { fn: fn as unknown as typeof fetch, calls };
}

test("checkout reserves before provider call, keeps unknown outcomes, releases known rejection", async () => {
  for (const outcome of ["timeout", "invalid-json", "server-error", "known-rejection"] as const) {
    const redis = mockRedis(); let calls = 0;
    const app = createApp({ redis, env: env({ PORTALY_API_KEY: "pcs_test_fake", PORTALY_CALLBACK_URL: "https://example.com/callback" }), now: () => NOW,
      fetchImpl: (async () => {
        calls++;
        assert.equal([...redis.values.keys()].filter(k => k.startsWith("checkout:pending:")).length, 1);
        if (outcome === "timeout") throw Error("timeout");
        if (outcome === "invalid-json") return new Response("bad");
        return Response.json({ code: "PLAN_INACTIVE" }, { status: outcome === "known-rejection" ? 422 : 500 });
      }) as typeof fetch });
    const token = await installationToken(app);
    const request = () => app.fetch(jsonPost("/v1/billing/checkout", {}, { Authorization: `Bearer ${token}` }));
    await request();
    const retry = await request();
    assert.equal(calls, outcome === "known-rejection" ? 2 : 1);
    assert.equal(retry.status, outcome === "known-rejection" ? 422 : 409);
  }
});

const NOW = new Date("2026-07-23T03:00:00.000Z");
const INSTALLATION_ID = "0e94b434-1f10-4a7f-8d34-e09f9c0e7bd9";
const ADMIN_AUTH = `Basic ${Buffer.from("owner:correct-horse").toString("base64")}`;

function env(overrides: Partial<QuillEnv> = {}): QuillEnv {
  return {
    OPENAI_KEY: "openai-key",
    INSTALLATION_TOKEN_SECRET: "installation-secret",
    ANALYTICS_SALT: "analytics-salt",
    QUOTA_TIME_ZONE: "Asia/Taipei",
    ADMIN_USERNAME: "owner",
    ADMIN_PASSWORD: "correct-horse",
    PORTALY_PLAN_ID: "plan_quill_pro",
    ...overrides,
  };
}

function jsonPost(path: string, body: unknown, headers: Record<string, string> = {}) {
  return new Request(`http://x${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

const textBody = { messages: [{ role: "user", content: "hi" }], stream: true };
const visionBody = {
  messages: [{
    role: "user",
    content: [
      { type: "text", text: "x" },
      { type: "image_url", image_url: { url: "data:image/png;base64,QUJD" } },
    ],
  }],
  stream: true,
};

async function installationToken(
  app: ReturnType<typeof createApp>,
  id = INSTALLATION_ID,
  timeZone?: string
): Promise<string> {
  const body: Record<string, string> = { installation_id: id };
  if (timeZone) body.time_zone = timeZone;
  const response = await app.fetch(jsonPost("/v1/installations", body));
  assert.equal(response.status, 201);
  return (await response.json()).token;
}

test("installation registration returns a token; invalid id is rejected", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), now: () => NOW });
  assert.equal((await app.fetch(jsonPost("/v1/installations", { installation_id: "change-me" }))).status, 400);
  assert.equal((await app.fetch(jsonPost("/v1/installations", {
    installation_id: INSTALLATION_ID,
    time_zone: "Mars/Olympus_Mons",
  }))).status, 400);
  const token = await installationToken(app);
  assert.match(token, /^[^.]+\.[^.]+$/);
});

test("missing or forged installation token → 401", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), now: () => NOW });
  assert.equal((await app.fetch(jsonPost("/v1/chat/completions", textBody))).status, 401);
  assert.equal((await app.fetch(jsonPost("/v1/chat/completions", textBody, {
    Authorization: "Bearer forged.token",
  }))).status, 401);
});

test("valid request routes to OpenAI and records anonymous active metric", async () => {
  const redis = mockRedis();
  const upstream = mockFetch();
  const app = createApp({ redis, env: env(), fetchImpl: upstream.fn, now: () => NOW });
  const token = await installationToken(app);
  const response = await app.fetch(jsonPost("/v1/chat/completions", textBody, {
    Authorization: `Bearer ${token}`,
  }));
  assert.equal(response.status, 200);
  assert.match(upstream.calls[0].url, /api\.openai\.com/);
  assert.equal(upstream.calls[0].init.headers.Authorization, "Bearer openai-key");
  assert.equal(upstream.calls[0].body.model, "gpt-4o-mini");
  assert.equal(redis.sets.get("metrics:app_active:2026-07-23")?.size, 1);
  assert.ok(![...redis.counters.keys(), ...redis.sets.keys()].some((key) => key.includes(INSTALLATION_ID)));
});

test("vision request passes image content through", async () => {
  const upstream = mockFetch();
  const app = createApp({ redis: mockRedis(), env: env(), fetchImpl: upstream.fn, now: () => NOW });
  const token = await installationToken(app);
  await app.fetch(jsonPost("/v1/chat/completions", visionBody, { Authorization: `Bearer ${token}` }));
  assert.ok(upstream.calls[0].body.messages[0].content.some((part: any) => part.type === "image_url"));
});

test("invalid request does not consume quota", async () => {
  const redis = mockRedis();
  const app = createApp({ redis, env: env(), fetchImpl: mockFetch().fn, now: () => NOW });
  const token = await installationToken(app);
  const response = await app.fetch(jsonPost("/v1/chat/completions", {}, {
    Authorization: `Bearer ${token}`,
  }));
  assert.equal(response.status, 400);
  assert.ok(![...redis.counters.keys()].some((key) => key.startsWith("usage:")));
});

test("11th request → 429 once per unique installation with Taipei reset timestamp", async () => {
  const redis = mockRedis();
  const app = createApp({
    redis,
    env: env({ DAILY_LIMIT: "10" }),
    fetchImpl: mockFetch().fn,
    now: () => NOW,
  });
  const token = await installationToken(app);
  const headers = { Authorization: `Bearer ${token}` };
  for (let index = 0; index < 10; index++) {
    assert.equal((await app.fetch(jsonPost("/v1/chat/completions", textBody, headers))).status, 200);
  }
  const response = await app.fetch(jsonPost("/v1/chat/completions", textBody, headers));
  assert.equal(response.status, 429);
  const payload = await response.json();
  assert.equal(payload.error.code, "daily_quota_reached");
  assert.equal(payload.error.resets_at, "2026-07-23T16:00:00.000Z");
  await app.fetch(jsonPost("/v1/chat/completions", textBody, headers));
  assert.equal(redis.sets.get("metrics:quota_reached:2026-07-23")?.size, 1);
});

test("Taipei quota does not reset at UTC midnight", async () => {
  const redis = mockRedis();
  let clock = new Date("2026-07-22T23:59:00.000Z");
  const app = createApp({
    redis,
    env: env({ DAILY_LIMIT: "1" }),
    fetchImpl: mockFetch().fn,
    now: () => clock,
  });
  const token = await installationToken(app);
  const headers = { Authorization: `Bearer ${token}` };
  assert.equal((await app.fetch(jsonPost("/v1/chat/completions", textBody, headers))).status, 200);
  clock = new Date("2026-07-23T00:01:00.000Z");
  assert.equal((await app.fetch(jsonPost("/v1/chat/completions", textBody, headers))).status, 429);
});

test("free quota resets at the installation's signed local midnight", async () => {
  const redis = mockRedis();
  const app = createApp({
    redis,
    env: env(),
    now: () => NOW,
  });
  const token = await installationToken(app, INSTALLATION_ID, "America/Los_Angeles");
  const response = await app.fetch(new Request("http://x/v1/billing/status", {
    headers: { Authorization: `Bearer ${token}` },
  }));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).resets_at, "2026-07-23T07:00:00.000Z");
});

test("oversized API request is rejected before route processing", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), now: () => NOW });
  const response = await app.fetch(new Request("http://x/v1/installations", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Content-Length": String(10 * 1024 * 1024 + 1),
    },
    body: "{}",
  }));
  assert.equal(response.status, 413);
  assert.match((await response.json()).error.message, /too large/i);
});

test("global cap does not consume another installation's quota", async () => {
  const redis = mockRedis();
  const app = createApp({
    redis,
    env: env({ GLOBAL_DAILY_CAP: "1" }),
    fetchImpl: mockFetch().fn,
    now: () => NOW,
  });
  const token1 = await installationToken(app, "0e94b434-1f10-4a7f-8d34-e09f9c0e7bd9");
  const token2 = await installationToken(app, "ff55d247-322e-45d7-97c5-dc2eb8811aa4");
  await app.fetch(jsonPost("/v1/chat/completions", textBody, { Authorization: `Bearer ${token1}` }));
  assert.equal((await app.fetch(jsonPost("/v1/chat/completions", textBody, {
    Authorization: `Bearer ${token2}`,
  }))).status, 503);
  assert.equal([...redis.counters.keys()].filter((key) => key.startsWith("usage:")).length, 1);
});

test("upgrade intent is unique per installation/day", async () => {
  const redis = mockRedis();
  const app = createApp({ redis, env: env(), now: () => NOW });
  const token = await installationToken(app);
  const request = () => jsonPost("/v1/events", { event: "upgrade_clicked" }, {
    Authorization: `Bearer ${token}`,
  });
  assert.equal((await app.fetch(request())).status, 204);
  assert.equal((await app.fetch(request())).status, 204);
  assert.equal(redis.sets.get("metrics:upgrade_clicked:2026-07-23")?.size, 1);
});

test("checkout records intent and redirects to configured payment provider", async () => {
  const redis = mockRedis();
  const app = createApp({
    redis,
    env: env({ CHECKOUT_URL: "https://payments.example.com/quill-pro" }),
    now: () => NOW,
  });
  const request = () => new Request("http://x/checkout", {
    headers: { "x-forwarded-for": "203.0.113.8" },
  });
  const response = await app.fetch(request());
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), "https://payments.example.com/quill-pro");
  await app.fetch(request());
  assert.equal(redis.sets.get("metrics:checkout_started:2026-07-23")?.size, 1);
});

test("checkout uses honest coming-soon page until a payment URL is configured", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), now: () => NOW });
  const response = await app.fetch(new Request("http://x/checkout"));
  assert.equal(response.status, 302);
  assert.equal(
    response.headers.get("location"),
    "https://quill.morpheuschen.com/checkout.html?status=coming-soon"
  );
});

test("billing status and checkout apply the launch offer for an authenticated installation", async () => {
  const redis = mockRedis();
  const calls: any[] = [];
  const checkoutFetch = async (_url: any, init: any) => {
    calls.push(JSON.parse(init.body));
    return Response.json({
      data: {
        sessionId: "checkout_session_123",
        checkoutToken: "checkout_token_123",
        checkoutUrl: "https://portaly.cc/checkout/test",
        expiresAt: "2026-07-23T03:30:00.000Z",
        amount: 199,
        appliedDiscount: {
          code: "LAUNCH149",
          finalAmount: 149,
        },
      },
    });
  };
  const app = createApp({
    redis,
    env: env({
      PORTALY_API_KEY: "pcs_test_fixture",
      PORTALY_CALLBACK_URL: "https://quill.example.com/v1/webhooks/portaly",
      PORTALY_DISCOUNT_CODE: "LAUNCH149",
      PORTALY_PROMO_END: "2026-08-31T15:59:59.000Z",
    }),
    fetchImpl: checkoutFetch as typeof fetch,
    now: () => NOW,
  });
  const token = await installationToken(app);
  const authorization = { Authorization: `Bearer ${token}` };

  const status = await app.fetch(new Request("http://x/v1/billing/status", {
    headers: authorization,
  }));
  assert.equal(status.status, 200);
  assert.deepEqual(await status.json(), {
    recovery_enabled: false,
    plan: "free",
    used: 0,
    limit: 10,
    remaining: 10,
    resets_at: "2026-07-23T16:00:00.000Z",
    subscription: null,
    promotion: {
      active: true,
      first_month_amount: 149,
      recurring_amount: 199,
      ends_at: "2026-08-31T15:59:59.000Z",
    },
  });

  const checkout = await app.fetch(jsonPost("/v1/billing/checkout", {}, authorization));
  assert.equal(checkout.status, 201);
  assert.deepEqual(await checkout.json(), {
    checkout_url: "https://portaly.cc/checkout/test",
    checkout_session_id: "checkout_session_123",
    expires_at: "2026-07-23T03:30:00.000Z",
    promotion_applied: true,
    first_month_amount: 149,
    recurring_amount: 199,
  });
  assert.equal(calls[0].planId, "plan_quill_pro");
  assert.equal(calls[0].discountCode, "LAUNCH149");
  assert.match(calls[0].metadata.installationHash, /^[0-9a-f]{64}$/);
  assert.ok(redis.values.has("checkout-session:checkout_session_123"));
});

test("launch offer automatically expires after the configured deadline", async () => {
  const calls: any[] = [];
  const checkoutFetch = async (_url: any, init: any) => {
    calls.push(JSON.parse(init.body));
    return Response.json({
      data: {
        sessionId: "checkout_after_offer",
        checkoutToken: "token_after_offer",
        checkoutUrl: "https://portaly.cc/checkout/test",
        expiresAt: "2026-09-02T03:30:00.000Z",
        amount: 199,
      },
    });
  };
  const app = createApp({
    redis: mockRedis(),
    env: env({
      PORTALY_API_KEY: "pcs_test_fixture",
      PORTALY_CALLBACK_URL: "https://quill.example.com/v1/webhooks/portaly",
      PORTALY_DISCOUNT_CODE: "LAUNCH149",
      PORTALY_PROMO_END: "2026-08-31T15:59:59.000Z",
    }),
    fetchImpl: checkoutFetch as typeof fetch,
    now: () => new Date("2026-09-02T03:00:00.000Z"),
  });
  const token = await installationToken(app);
  const authorization = { Authorization: `Bearer ${token}` };
  const status = await app.fetch(new Request("http://x/v1/billing/status", {
    headers: authorization,
  }));
  const statusBody = await status.json();
  assert.equal(statusBody.promotion.active, false);
  assert.equal(statusBody.promotion.first_month_amount, 199);

  const checkout = await app.fetch(jsonPost("/v1/billing/checkout", {}, authorization));
  const checkoutBody = await checkout.json();
  assert.equal(checkoutBody.promotion_applied, false);
  assert.equal(checkoutBody.first_month_amount, 199);
  assert.equal(calls[0].discountCode, undefined);
});

test("verified Portaly checkout callback records one anonymous purchase", async () => {
  const redis = mockRedis();
  const callbackSecret = "callback-secret";
  const app = createApp({
    redis,
    env: env({ PORTALY_CALLBACK_SECRET: callbackSecret }),
    now: () => NOW,
  });
  const payload = {
    event: "creator_subscription.checkout.completed",
    sessionId: "session_test_123",
    subscriptionId: "session_test_123",
    mode: "test",
    status: "completed",
    merchantOrderNumber: "quill_test_001",
    amount: 199,
    currency: "TWD",
    customerEmail: "buyer@example.com",
    paymentReference: "txn_test_123",
    planId: "plan_quill_pro",
    metadata: {
      installationHash: "a".repeat(64),
    },
  };
  const timestamp = NOW.toISOString();
  const signature = signPortalyCallback({ secret: callbackSecret, payload, timestamp });
  const request = () => jsonPost("/v1/webhooks/portaly", payload, {
    "x-portaly-event": payload.event,
    "x-portaly-timestamp": timestamp,
    "x-portaly-signature": signature,
  });

  assert.equal((await app.fetch(request())).status, 204);
  assert.equal((await app.fetch(request())).status, 204);
  assert.equal(redis.sets.get("metrics:purchase_completed:2026-07-23")?.size, 1);
  assert.equal(redis.sets.get(`portaly-callback:${payload.event}`)?.size, 1);
  assert.ok(
    ![...redis.sets.values()].some((set) =>
      [...set].some((value) => value.includes(payload.customerEmail))
    )
  );
});

test("verified checkout activates Pro with a 600-use billing period", async () => {
  const redis = mockRedis();
  const callbackSecret = "callback-secret";
  const app = createApp({
    redis,
    env: env({
      PORTALY_CALLBACK_SECRET: callbackSecret,
      PRO_MONTHLY_LIMIT: "600",
    }),
    fetchImpl: mockFetch().fn,
    now: () => NOW,
  });
  const token = await installationToken(app);
  const anonymousID = createHmac("sha256", "analytics-salt")
    .update(INSTALLATION_ID).digest("hex");
  const payload = {
    event: "creator_subscription.checkout.completed",
    sessionId: "session_pro_123",
    subscriptionId: "subscription_pro_123",
    planId: "plan_quill_pro",
    mode: "test",
    status: "completed",
    amount: 149,
    completedAt: NOW.toISOString(),
    nextBillingAt: "2026-08-23T03:00:00.000Z",
    metadata: { installationHash: anonymousID },
  };
  const timestamp = NOW.toISOString();
  const signature = signPortalyCallback({ secret: callbackSecret, payload, timestamp });
  assert.equal((await app.fetch(jsonPost("/v1/webhooks/portaly", payload, {
    "x-portaly-event": payload.event,
    "x-portaly-timestamp": timestamp,
    "x-portaly-signature": signature,
  }))).status, 204);

  const status = await app.fetch(new Request("http://x/v1/billing/status", {
    headers: { Authorization: `Bearer ${token}` },
  }));
  const statusBody = await status.json();
  assert.equal(statusBody.plan, "pro");
  assert.equal(statusBody.limit, 600);
  assert.equal(statusBody.subscription.current_amount, 149);
  assert.equal(statusBody.subscription.next_amount, 199);
  assert.equal(statusBody.resets_at, "2026-08-23T03:00:00.000Z");
});

test("test subscriptions do not grant Pro after switching to live payments", async () => {
  const redis = mockRedis();
  const anonymousID = createHmac("sha256", "analytics-salt")
    .update(INSTALLATION_ID).digest("hex");
  await redis.set(`subscription:installation:${anonymousID}`, JSON.stringify({
    subscriptionId: "subscription_test_123",
    sessionId: "session_test_123",
    planId: "plan_quill_pro",
    mode: "test",
    status: "active",
    periodStart: NOW.toISOString(),
    periodEnd: "2026-08-23T03:00:00.000Z",
    currentAmount: 149,
    cancelAtPeriodEnd: false,
    cancelEffectiveAt: null,
  }));
  const app = createApp({
    redis,
    env: env({ PORTALY_API_KEY: "pcs_live_fixture" }),
    now: () => NOW,
  });
  const token = await installationToken(app);
  const response = await app.fetch(new Request("http://x/v1/billing/status", {
    headers: { Authorization: `Bearer ${token}` },
  }));
  const body = await response.json();
  assert.equal(body.plan, "free");
  assert.equal(body.limit, 10);
});

test("subscription portal is scoped to the authenticated installation's subscription", async () => {
  const redis = mockRedis();
  const anonymousID = createHmac("sha256", "analytics-salt")
    .update(INSTALLATION_ID).digest("hex");
  await redis.set(`subscription:installation:${anonymousID}`, JSON.stringify({
    subscriptionId: "subscription_pro_123",
    sessionId: "session_pro_123",
    planId: "plan_quill_pro",
    mode: "test",
    status: "active",
    periodStart: NOW.toISOString(),
    periodEnd: "2026-08-23T03:00:00.000Z",
    currentAmount: 149,
    cancelAtPeriodEnd: false,
    cancelEffectiveAt: null,
  }));
  const calls: any[] = [];
  const portalFetch = async (url: any, init: any) => {
    calls.push({ url, body: JSON.parse(init.body) });
    return Response.json({
      data: {
        portalSessionId: "portal_123",
        portalUrl: "https://portaly.ai/portal/portal_123?token=test",
        expiresAt: "2026-07-23T03:30:00.000Z",
      },
    });
  };
  const app = createApp({
    redis,
    env: env({
      PORTALY_API_KEY: "test-key",
      PORTALY_PORTAL_RETURN_URL: "https://quill.example.com/account",
    }),
    fetchImpl: portalFetch as typeof fetch,
    now: () => NOW,
  });
  const token = await installationToken(app);
  const response = await app.fetch(jsonPost("/v1/billing/portal", {}, {
    Authorization: `Bearer ${token}`,
  }));

  assert.equal(response.status, 201);
  assert.equal((await response.json()).portal_url, "https://portaly.ai/portal/portal_123?token=test");
  assert.equal(
    calls[0].url,
    "https://portaly.ai/api/creator-subscription/portal-sessions"
  );
  assert.deepEqual(calls[0].body, {
    subscriptionId: "subscription_pro_123",
    returnUrl: "https://quill.example.com/account",
  });
  assert.equal(calls[0].body.customerEmail, undefined);
});

test("subscription portal rejects unauthenticated and unlinked installations", async () => {
  const app = createApp({
    redis: mockRedis(),
    env: env({ PORTALY_API_KEY: "test-key" }),
    now: () => NOW,
  });
  assert.equal((await app.fetch(jsonPost("/v1/billing/portal", {}))).status, 401);
  const token = await installationToken(app);
  assert.equal((await app.fetch(jsonPost("/v1/billing/portal", {}, {
    Authorization: `Bearer ${token}`,
  }))).status, 404);
});

test("Portaly callback rejects invalid signatures, stale timestamps, and event mismatch", async () => {
  const callbackSecret = "callback-secret";
  const app = createApp({
    redis: mockRedis(),
    env: env({ PORTALY_CALLBACK_SECRET: callbackSecret }),
    now: () => NOW,
  });
  const payload = {
    event: "creator_subscription.checkout.completed",
    sessionId: "session_test_456",
    mode: "test",
    status: "completed",
  };
  const timestamp = NOW.toISOString();
  const signature = signPortalyCallback({ secret: callbackSecret, payload, timestamp });

  assert.equal((await app.fetch(jsonPost("/v1/webhooks/portaly", payload, {
    "x-portaly-event": payload.event,
    "x-portaly-timestamp": timestamp,
    "x-portaly-signature": "0".repeat(64),
  }))).status, 401);
  assert.equal((await app.fetch(jsonPost("/v1/webhooks/portaly", payload, {
    "x-portaly-event": payload.event,
    "x-portaly-timestamp": "2026-07-23T02:50:00.000Z",
    "x-portaly-signature": signature,
  }))).status, 401);
  assert.equal((await app.fetch(jsonPost("/v1/webhooks/portaly", payload, {
    "x-portaly-event": "creator_subscription.payment.succeeded",
    "x-portaly-timestamp": timestamp,
    "x-portaly-signature": signature,
  }))).status, 400);
});

test("Portaly callback rejects unknown signed events without changing subscription state", async () => {
  const callbackSecret = "callback-secret";
  const redis = mockRedis();
  const anonymousID = "a".repeat(64);
  const subscriptionID = "subscription_known_123";
  const original = JSON.stringify({
    subscriptionId: subscriptionID,
    sessionId: subscriptionID,
    planId: "plan_quill_pro",
    mode: "test",
    status: "active",
    periodStart: NOW.toISOString(),
    periodEnd: "2026-08-23T03:00:00.000Z",
    currentAmount: 199,
    cancelAtPeriodEnd: false,
    cancelEffectiveAt: null,
  });
  redis.values.set(`subscription:portaly:${subscriptionID}`, anonymousID);
  redis.values.set(`subscription:installation:${anonymousID}`, original);
  const app = createApp({
    redis,
    env: env({ PORTALY_CALLBACK_SECRET: callbackSecret }),
    now: () => NOW,
  });
  const payload = {
    event: "creator_subscription.future_event",
    subscriptionId: subscriptionID,
    planId: "plan_quill_pro",
    mode: "test",
  };
  const timestamp = NOW.toISOString();
  const signature = signPortalyCallback({ secret: callbackSecret, payload, timestamp });
  const response = await app.fetch(jsonPost("/v1/webhooks/portaly", payload, {
    "x-portaly-event": payload.event,
    "x-portaly-timestamp": timestamp,
    "x-portaly-signature": signature,
  }));
  assert.equal(response.status, 400);
  assert.equal(redis.values.get(`subscription:installation:${anonymousID}`), original);
});

test("Portaly callback rejects a test event when live mode is configured", async () => {
  const callbackSecret = "callback-secret";
  const app = createApp({
    redis: mockRedis(),
    env: env({
      PORTALY_API_KEY: "pcs_live_fixture",
      PORTALY_CALLBACK_SECRET: callbackSecret,
    }),
    now: () => NOW,
  });
  const payload = {
    event: "creator_subscription.checkout.completed",
    sessionId: "session_wrong_mode",
    mode: "test",
    status: "completed",
    planId: "plan_quill_pro",
    metadata: { installationHash: "a".repeat(64) },
  };
  const timestamp = NOW.toISOString();
  const signature = signPortalyCallback({ secret: callbackSecret, payload, timestamp });
  const response = await app.fetch(jsonPost("/v1/webhooks/portaly", payload, {
    "x-portaly-event": payload.event,
    "x-portaly-timestamp": timestamp,
    "x-portaly-signature": signature,
  }));
  assert.equal(response.status, 400);
});

test("metrics dashboard and data require admin authentication", async () => {
  const redis = mockRedis();
  const app = createApp({ redis, env: env(), now: () => NOW });
  assert.equal((await app.fetch(new Request("http://x/admin/metrics"))).status, 401);
  const page = await app.fetch(new Request("http://x/admin/metrics", {
    headers: { Authorization: ADMIN_AUTH },
  }));
  assert.equal(page.status, 200);
  assert.match(await page.text(), /Quill 使用指標/);
  const data = await app.fetch(new Request("http://x/admin/metrics/data?days=7", {
    headers: { Authorization: ADMIN_AUTH },
  }));
  assert.equal(data.status, 200);
  assert.equal((await data.json()).days.length, 7);
});

test("failed entitlement commit can retry, duplicate delivery cannot reset renewed quota", async () => {
  const redis = mockRedis();
  const originalEval = redis.eval.bind(redis);
  let fail = true;
  redis.eval = async (...args) => {
    if (args[0].includes("billing_commit_v1") && fail) { fail = false; throw new Error("Injected outage"); }
    return originalEval(...args);
  };
  const app = createApp({redis, env: env({PORTALY_CALLBACK_SECRET: "fixture"}), now: () => NOW});
  const identity = "a".repeat(64);
  const payload = {event: "creator_subscription.checkout.completed", mode: "test", status: "completed",
    sessionId: "retry-session", planId: "plan_quill_pro", metadata: {installationHash: identity},
    completedAt: NOW.toISOString(), nextBillingAt: "2026-08-23T03:00:00.000Z"};
  const deliver = () => app.fetch(jsonPost("/v1/webhooks/portaly", payload, {
    "x-portaly-event": payload.event, "x-portaly-timestamp": NOW.toISOString(),
    "x-portaly-signature": signPortalyCallback({secret: "fixture", payload, timestamp: NOW.toISOString()})
  }));
  assert.equal((await deliver()).status, 500);
  assert.equal(redis.values.has(`subscription:installation:${identity}`), false);
  assert.equal((await deliver()).status, 204);
  const key = `subscription:installation:${identity}`;
  const record = JSON.parse(redis.values.get(key)!);
  record.periodStart = "2026-08-23T03:00:00.000Z";
  redis.values.set(key, JSON.stringify(record));
  assert.equal((await deliver()).status, 204);
  assert.equal(JSON.parse(redis.values.get(key)!).periodStart, record.periodStart);
});

test("cancel then resume clears cancellation and permits subsequent cancellation", async () => {
  const redis = mockRedis();
  const identity = "a".repeat(64), sub = "resume-session";
  redis.values.set(`subscription:portaly:${sub}`, identity);
  redis.values.set(`subscription:installation:${identity}`, JSON.stringify({
    subscriptionId: sub, sessionId: sub, planId: "plan_quill_pro", mode: "test", status: "active",
    periodStart: NOW.toISOString(), periodEnd: "2026-08-23T03:00:00.000Z"
  }));
  const app = createApp({redis, env: env({PORTALY_CALLBACK_SECRET: "fixture"}), now: () => NOW});
  for (const action of ["cancel_requested", "active", "cancel_requested"]) {
    const payload = {event: `creator_subscription.${action}`, mode: "test", subscriptionId: sub};
    const response = await app.fetch(jsonPost("/v1/webhooks/portaly", payload, {
      "x-portaly-event": payload.event, "x-portaly-timestamp": NOW.toISOString(),
      "x-portaly-signature": signPortalyCallback({secret: "fixture", payload, timestamp: NOW.toISOString()})
    }));
    assert.equal(response.status, 204);
    const record = JSON.parse(redis.values.get(`subscription:installation:${identity}`)!);
    assert.equal(record.cancelAtPeriodEnd, action === "cancel_requested");
    if (action === "active") assert.equal(record.cancelEffectiveAt, null);
  }
});

test("upstream HTTP and connection failures refund device and global usage", async () => {
  for (const networkFailure of [false, true]) {
    const redis = mockRedis();
    const app = createApp({redis, env: env(), now: () => NOW, fetchImpl: async () => {
      if (networkFailure) throw new Error("Disconnected");
      return new Response("unavailable", {status: 503});
    }});
    const token = await installationToken(app);
    for (let attempt = 0; attempt < 12; attempt++) {
      const response = await app.fetch(jsonPost("/v1/chat/completions", textBody, {Authorization: `Bearer ${token}`}));
      assert.equal(response.status, 502);
    }
    for (const [key, used] of redis.counters) {
      if (key.startsWith("usage:") || key.startsWith("global:")) assert.equal(used, 0);
    }
  }
});

test("stream meter preserves byte-split Chinese and refunds empty or interrupted output", async () => {
  const text = new TextEncoder().encode('data: {"choices":[{"delta":{"content":"繁體中文🙂"}}]}\n\ndata: [DONE]\n\n');
  for (let split = 1; split < text.length; split++) {
    let refunds = 0;
    const source = new ReadableStream<Uint8Array>({start(c) {
      c.enqueue(text.slice(0, split)); c.enqueue(text.slice(split)); c.close();
    }});
    const body = await new Response(meteredResponseStream(source, async () => { refunds++; })).text();
    assert.equal(body, new TextDecoder().decode(text));
    assert.equal(refunds, 0);
  }
  for (const fail of [false, true]) {
    let refunds = 0, pulls = 0;
    const source = new ReadableStream<Uint8Array>({pull(c) {
      if (pulls++ === 0) c.enqueue(new TextEncoder().encode('data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n'));
      else if (fail) c.error(new Error("Disconnected"));
      else c.close();
    }});
    const response = new Response(meteredResponseStream(source, async () => { refunds++; }));
    if (fail) await assert.rejects(response.text()); else await response.text();
    assert.equal(refunds, 1);
  }
});

test("malformed and empty non-streaming success responses refund quota", async () => {
  for (const response of ['garbled', '{}', '{"choices":[{"message":{"content":""}}]}']) {
    const redis = mockRedis();
    const app = createApp({redis, env: env(), now: () => NOW,
      fetchImpl: async () => new Response(response)});
    const token = await installationToken(app);
    const result = await app.fetch(jsonPost("/v1/chat/completions", {...textBody, stream: false}, {Authorization: `Bearer ${token}`}));
    assert.equal(result.status, 502);
    for (const [key, count] of redis.counters) if (key.startsWith("usage:")) assert.equal(count, 0);
  }
});

test("/health exposes metrics time zone and security headers", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), now: () => NOW });
  const response = await app.fetch(new Request("http://x/health"));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-content-type-options"), "nosniff");
  assert.deepEqual(await response.json(), {
    ok: true,
    metricsTimeZone: "Asia/Taipei",
    payments: { configured: false, mode: null },
  });
});
