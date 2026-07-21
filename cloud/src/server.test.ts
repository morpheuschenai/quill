import { test } from "node:test";
import assert from "node:assert/strict";
import { createApp, isVisionRequest, type QuillEnv, type RedisLike } from "./server.ts";

// ── mock Redis(Map + 原子 incr)──
function mockRedis(): RedisLike & { store: Map<string, number> } {
  const store = new Map<string, number>();
  return {
    store,
    async incr(key: string) {
      const v = (store.get(key) || 0) + 1;
      store.set(key, v);
      return v;
    },
    async expire() {
      return 1;
    },
  };
}

// ── mock fetch:記錄最後一次上游呼叫 ──
function mockFetch() {
  const calls: any[] = [];
  const fn = async (url: any, init: any) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return new Response("data: {}\n\ndata: [DONE]\n\n", { status: 200 });
  };
  return { fn: fn as unknown as typeof fetch, calls };
}

const SECRET = "sekret";
function env(overrides: Partial<QuillEnv> = {}): QuillEnv {
  return {
    QUILL_APP_SECRET: SECRET,
    GEMINI_KEY: "gk",
    OPENAI_KEY: "ok",
    ...overrides,
  };
}
function post(headers: Record<string, string>, body: any) {
  return new Request("http://x/v1/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}
const textBody = { messages: [{ role: "user", content: "hi" }], stream: true };
const visionBody = {
  messages: [{ role: "user", content: [{ type: "text", text: "x" }, { type: "image_url", image_url: { url: "data:..." } }] }],
  stream: true,
};

test("isVisionRequest detects image content", () => {
  assert.equal(isVisionRequest(visionBody), true);
  assert.equal(isVisionRequest(textBody), false);
});

test("wrong secret → 401", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), fetchImpl: mockFetch().fn });
  const r = await app.fetch(post({ Authorization: "Bearer nope", "X-Quill-Device": "d1" }, textBody));
  assert.equal(r.status, 401);
});

test("missing device → 400", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), fetchImpl: mockFetch().fn });
  const r = await app.fetch(post({ Authorization: `Bearer ${SECRET}` }, textBody));
  assert.equal(r.status, 400);
});

test("text request → routed to OpenAI with gpt-4o-mini", async () => {
  const mf = mockFetch();
  const app = createApp({ redis: mockRedis(), env: env(), fetchImpl: mf.fn });
  const r = await app.fetch(post({ Authorization: `Bearer ${SECRET}`, "X-Quill-Device": "d1" }, textBody));
  assert.equal(r.status, 200);
  assert.match(mf.calls[0].url, /openai\.com/);
  assert.equal(mf.calls[0].init.headers.Authorization, "Bearer ok");
  assert.equal(mf.calls[0].body.model, "gpt-4o-mini");
});

test("vision request → routed to Gemini with flash", async () => {
  const mf = mockFetch();
  const app = createApp({ redis: mockRedis(), env: env(), fetchImpl: mf.fn });
  const r = await app.fetch(post({ Authorization: `Bearer ${SECRET}`, "X-Quill-Device": "d1" }, visionBody));
  assert.equal(r.status, 200);
  assert.match(mf.calls[0].url, /generativelanguage\.googleapis\.com/);
  assert.equal(mf.calls[0].init.headers.Authorization, "Bearer gk");
  assert.equal(mf.calls[0].body.model, "gemini-2.0-flash");
});

test("over daily limit → 429", async () => {
  const redis = mockRedis();
  const app = createApp({ redis, env: env({ DAILY_LIMIT: "2" }), fetchImpl: mockFetch().fn });
  const hdr = { Authorization: `Bearer ${SECRET}`, "X-Quill-Device": "d1" };
  await app.fetch(post(hdr, textBody)); // 1
  await app.fetch(post(hdr, textBody)); // 2
  const r = await app.fetch(post(hdr, textBody)); // 3 → 超過
  assert.equal(r.status, 429);
});

test("over global cap → 503", async () => {
  const redis = mockRedis();
  const app = createApp({ redis, env: env({ GLOBAL_DAILY_CAP: "1" }), fetchImpl: mockFetch().fn });
  await app.fetch(post({ Authorization: `Bearer ${SECRET}`, "X-Quill-Device": "d1" }, textBody)); // 1
  const r = await app.fetch(post({ Authorization: `Bearer ${SECRET}`, "X-Quill-Device": "d2" }, textBody)); // 全域第2 → 超過
  assert.equal(r.status, 503);
});

test("/health → ok", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), fetchImpl: mockFetch().fn });
  const r = await app.fetch(new Request("http://x/health"));
  assert.equal(r.status, 200);
});
