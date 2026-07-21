/**
 * OpenAI ↔ Anthropic 格式轉換。
 *
 * App 端一律送 OpenAI chat/completions 格式(streaming/vision 都是),
 * 但 Anthropic Messages API 格式不同,所以在後端做雙向轉換,App 不用改。
 *
 * 這裡的純函式都可單元測試。
 */

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";

/** 把 OpenAI 的 chat body 轉成 Anthropic Messages body */
export function openaiToAnthropic(body: any, model: string): any {
  const systemParts: string[] = [];
  const messages: any[] = [];

  for (const m of body?.messages ?? []) {
    if (m.role === "system") {
      if (typeof m.content === "string") systemParts.push(m.content);
      continue;
    }
    messages.push({ role: m.role, content: convertContent(m.content) });
  }

  const out: any = {
    model,
    max_tokens: typeof body?.max_tokens === "number" ? body.max_tokens : 2048,
    messages,
    stream: body?.stream === true,
  };
  if (systemParts.length) out.system = systemParts.join("\n\n");
  if (typeof body?.temperature === "number") out.temperature = body.temperature;
  return out;
}

/** OpenAI content(字串或 parts 陣列)→ Anthropic content blocks */
function convertContent(content: any): any {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";

  return content.map((part: any) => {
    if (part?.type === "text") {
      return { type: "text", text: part.text ?? "" };
    }
    if (part?.type === "image_url") {
      const url: string = part.image_url?.url ?? "";
      const m = url.match(/^data:([^;]+);base64,(.*)$/s);
      if (m) {
        return { type: "image", source: { type: "base64", media_type: m[1], data: m[2] } };
      }
      // 非 data URL:當一般 URL 圖片
      return { type: "image", source: { type: "url", url } };
    }
    return { type: "text", text: "" };
  });
}

/** Anthropic 非串流回應 → OpenAI 非串流格式 */
export function anthropicToOpenAIResponse(anthropic: any): any {
  const text = Array.isArray(anthropic?.content)
    ? anthropic.content.filter((b: any) => b?.type === "text").map((b: any) => b.text).join("")
    : "";
  const finish = anthropic?.stop_reason === "max_tokens" ? "length" : "stop";
  return {
    id: anthropic?.id ?? "chatcmpl-quill",
    object: "chat.completion",
    choices: [{ index: 0, message: { role: "assistant", content: text }, finish_reason: finish }],
  };
}

/**
 * 解析一行 Anthropic SSE,轉成對應的 OpenAI SSE chunk(或 null)。
 * - content_block_delta(text_delta)→ delta.content
 * - message_stop → [DONE]
 * 純函式,供單元測試。
 */
export function anthropicLineToOpenAI(line: string): string | null {
  const trimmed = line.trim();
  if (!trimmed.startsWith("data:")) return null;
  const payload = trimmed.slice(5).trim();
  if (!payload) return null;

  let evt: any;
  try {
    evt = JSON.parse(payload);
  } catch {
    return null;
  }

  if (evt.type === "content_block_delta" && evt.delta?.type === "text_delta") {
    const chunk = { choices: [{ index: 0, delta: { content: evt.delta.text ?? "" } }] };
    return `data: ${JSON.stringify(chunk)}\n\n`;
  }
  if (evt.type === "message_stop") {
    return "data: [DONE]\n\n";
  }
  return null;
}

/** 把 Anthropic 的 SSE ReadableStream 轉成 OpenAI SSE ReadableStream */
export function anthropicStreamToOpenAI(upstream: ReadableStream<Uint8Array>): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  let buffer = "";

  const transform = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      buffer += decoder.decode(chunk, { stream: true });
      let idx: number;
      while ((idx = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 1);
        const out = anthropicLineToOpenAI(line);
        if (out) controller.enqueue(encoder.encode(out));
      }
    },
    flush(controller) {
      const out = anthropicLineToOpenAI(buffer);
      if (out) controller.enqueue(encoder.encode(out));
    },
  });

  return upstream.pipeThrough(transform);
}

export interface AnthropicCall {
  url: string;
  headers: Record<string, string>;
  body: string;
}

/** 組出呼叫 Anthropic 所需的 url/headers/body */
export function buildAnthropicCall(openaiBody: any, apiKey: string, model: string): AnthropicCall {
  return {
    url: ANTHROPIC_URL,
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(openaiToAnthropic(openaiBody, model)),
  };
}
