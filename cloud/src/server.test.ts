import { test } from "node:test";
import assert from "node:assert/strict";
import { createApp, type QuillEnv, type RedisLike } from "./server.ts";
import {
  openaiToAnthropic,
  anthropicToOpenAIResponse,
  anthropicLineToOpenAI,
} from "./anthropic.ts";

// ── mock Redis ──
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

function mockFetch(streaming = false) {
  const calls: any[] = [];
  const fn = async (url: any, init: any) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    if (streaming) {
      return new Response(
        'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}\n\ndata: {"type":"message_stop"}\n\n',
        { status: 200 }
      );
    }
    return new Response(JSON.stringify({ content: [{ type: "text", text: "hello" }], stop_reason: "end_turn" }), {
      status: 200,
    });
  };
  return { fn: fn as unknown as typeof fetch, calls };
}

const SECRET = "sekret";
function env(overrides: Partial<QuillEnv> = {}): QuillEnv {
  return { QUILL_APP_SECRET: SECRET, ANTHROPIC_KEY: "ak", ...overrides };
}
function post(headers: Record<string, string>, body: any) {
  return new Request("http://x/v1/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}
const textBody = { messages: [{ role: "system", content: "sys" }, { role: "user", content: "hi" }], stream: true };
const visionBody = {
  messages: [{ role: "user", content: [{ type: "text", text: "x" }, { type: "image_url", image_url: { url: "data:image/png;base64,QUJD" } }] }],
  max_tokens: 500,
};

// ── 純函式:格式轉換 ──
test("openaiToAnthropic pulls system out and keeps messages", () => {
  const a = openaiToAnthropic(textBody, "claude-haiku-4-5");
  assert.equal(a.system, "sys");
  assert.equal(a.messages.length, 1);
  assert.equal(a.messages[0].role, "user");
  assert.equal(a.model, "claude-haiku-4-5");
  assert.equal(a.max_tokens, 2048);
});

test("openaiToAnthropic converts image_url data URL to base64 image block", () => {
  const a = openaiToAnthropic(visionBody, "claude-haiku-4-5");
  const parts = a.messages[0].content;
  const img = parts.find((p: any) => p.type === "image");
  assert.ok(img);
  assert.equal(img.source.type, "base64");
  assert.equal(img.source.media_type, "image/png");
  assert.equal(img.source.data, "QUJD");
  assert.equal(a.max_tokens, 500);
});

test("anthropicToOpenAIResponse extracts text + finish_reason", () => {
  const o = anthropicToOpenAIResponse({ content: [{ type: "text", text: "hello" }], stop_reason: "max_tokens" });
  assert.equal(o.choices[0].message.content, "hello");
  assert.equal(o.choices[0].finish_reason, "length");
});

test("anthropicLineToOpenAI maps text_delta and message_stop", () => {
  const delta = anthropicLineToOpenAI('data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}');
  assert.ok(delta && delta.includes('"content":"hi"'));
  const done = anthropicLineToOpenAI('data: {"type":"message_stop"}');
  assert.equal(done, "data: [DONE]\n\n");
  assert.equal(anthropicLineToOpenAI("event: ping"), null);
});

// ── 端點:守門 + 路由到 Anthropic ──
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

test("request → routed to Anthropic with x-api-key + claude model", async () => {
  const mf = mockFetch();
  const app = createApp({ redis: mockRedis(), env: env(), fetchImpl: mf.fn });
  const r = await app.fetch(post({ Authorization: `Bearer ${SECRET}`, "X-Quill-Device": "d1" }, { messages: [{ role: "user", content: "hi" }] }));
  assert.equal(r.status, 200);
  assert.match(mf.calls[0].url, /api\.anthropic\.com/);
  assert.equal(mf.calls[0].init.headers["x-api-key"], "ak");
  assert.equal(mf.calls[0].body.model, "claude-haiku-4-5");
  const json = await r.json();
  assert.equal(json.choices[0].message.content, "hello");
});

test("streaming → Anthropic SSE converted to OpenAI SSE", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), fetchImpl: mockFetch(true).fn });
  const r = await app.fetch(post({ Authorization: `Bearer ${SECRET}`, "X-Quill-Device": "d1" }, textBody));
  assert.equal(r.status, 200);
  const text = await r.text();
  assert.ok(text.includes('"content":"hi"'));
  assert.ok(text.includes("data: [DONE]"));
});

test("over daily limit (10) → 429", async () => {
  const redis = mockRedis();
  const app = createApp({ redis, env: env({ DAILY_LIMIT: "10" }), fetchImpl: mockFetch().fn });
  const hdr = { Authorization: `Bearer ${SECRET}`, "X-Quill-Device": "d1" };
  for (let i = 0; i < 10; i++) await app.fetch(post(hdr, textBody));
  const r = await app.fetch(post(hdr, textBody));
  assert.equal(r.status, 429);
});

test("over global cap → 503", async () => {
  const redis = mockRedis();
  const app = createApp({ redis, env: env({ GLOBAL_DAILY_CAP: "1" }), fetchImpl: mockFetch().fn });
  await app.fetch(post({ Authorization: `Bearer ${SECRET}`, "X-Quill-Device": "d1" }, textBody));
  const r = await app.fetch(post({ Authorization: `Bearer ${SECRET}`, "X-Quill-Device": "d2" }, textBody));
  assert.equal(r.status, 503);
});

test("/health → ok", async () => {
  const app = createApp({ redis: mockRedis(), env: env(), fetchImpl: mockFetch().fn });
  const r = await app.fetch(new Request("http://x/health"));
  assert.equal(r.status, 200);
});
