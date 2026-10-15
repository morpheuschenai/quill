/** Forward SSE without storing content. Refund only when no useful text was delivered. */
export function meteredResponseStream(
  source: ReadableStream<Uint8Array>,
  refund: () => Promise<void>
): ReadableStream<Uint8Array> {
  const reader = source.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let useful = false;
  let ended = false;
  let refunded = false;
  const refundEmpty = async () => {
    if (!useful && !refunded) { await refund(); refunded = true; }
  };
  const inspect = (chunk: Uint8Array) => {
    if (useful) return;
    buffer += decoder.decode(chunk, { stream: true });
    let newline: number;
    while ((newline = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line.startsWith("data:")) continue;
      if (line.slice(5).trim() === "[DONE]") { ended = true; continue; }
      try {
        const event = JSON.parse(line.slice(5).trim());
        const text = event.choices?.[0]?.delta?.content;
        if (typeof text === "string" && text.trim().length > 0) { useful = true; buffer = ""; return; }
      } catch { /* [DONE] and malformed events contain no usable answer. */ }
    }
    if (buffer.length > 1024 * 1024) throw new Error("Oversized stream event");
  };
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        const { value, done } = await reader.read();
        if (done) {
          await refundEmpty();
          controller.close();
          return;
        }
        inspect(value);
        // Settle empty responses before forwarding the terminator, so a client
        // querying usage on completion sees the refund.
        if (ended) await refundEmpty();
        controller.enqueue(value);
      } catch (error) {
        await refundEmpty();
        controller.error(error);
        await reader.cancel().catch(() => {});
      }
    },
    async cancel(reason) {
      try { await reader.cancel(reason); } finally { await refundEmpty(); }
    }
  });
}
