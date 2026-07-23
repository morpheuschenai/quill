import { test } from "node:test";
import assert from "node:assert/strict";
import { createApp, type QuillEnv, type RedisLike } from "./server.ts";

type MockRedis = RedisLike & {
  counters: Map<string, number>;
  sets: Map<string, Set<string>>;
};

function mockRedis(): MockRedis {
  const counters = new Map<string, number>();
  const sets = new Map<string, Set<string>>();
  return {
    counters,
    sets,
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
    async eval(_script, _numberOfKeys, deviceKey, globalKey, dailyLimit, globalLimit) {
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
    return new Response("data: {}\n\ndata: [DONE]\n\n", { status });
  };
  return { fn: fn as unknown as typeof fetch, calls };
}

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

async function installationToken(app: ReturnType<typeof createApp>, id = INSTALLATION_ID): Promise<string> {
  const response = await app.fetch(jsonPost("/v1/installations", { installation_id: id }));
  assert.equal(response.status, 201);
  return (await response.json()).token;
}

test("installation registration returns a token; invalid id is rejected", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), now: () => NOW });
  assert.equal((await app.fetch(jsonPost("/v1/installations", { installation_id: "change-me" }))).status, 400);
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

test("/health → ok with configured time zone", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), now: () => NOW });
  const response = await app.fetch(new Request("http://x/health"));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, timeZone: "Asia/Taipei" });
});
