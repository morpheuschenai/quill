import { createHmac, randomInt, randomUUID } from "node:crypto";
import type { QuillEnv, RedisLike } from "./server.ts";
import { reconcilePendingCheckout, providerRead } from "./billingReconciliation.ts";
export { reconcilePendingCheckout } from "./billingReconciliation.ts";

export type RecoverySender = (message: { to: string; code: string; language: "zh-TW" | "en" }) => Promise<void>;
export class RecoveryError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) { super(message); this.status = status; this.code = code; }
}
const unavailable = () => new RecoveryError(503, "recovery_unavailable", "Purchase recovery is temporarily unavailable. Please try again later.");
const invalid = () => new RecoveryError(400, "recovery_invalid_code", "The code is invalid or expired. Request a new code if needed.");
const aliasKey = (id: string) => `subscription:alias:${id}`;
const subKey = (id: string) => `subscription:installation:${id}`;
const canonicalKey = (id: string) => `subscription:canonical:${id}`;
const challengeKey = (id: string) => `recovery:challenge:${id}`;
const hash = (secret: string, value: string) => createHmac("sha256", secret).update(value).digest("hex");
const normalize = (email: string) => email.trim().toLowerCase();

export const CHECKOUT_KNOWN_SCRIPT = `
-- checkout_known_v1
if redis.call("GET", KEYS[1]) ~= ARGV[1] then return 0 end
redis.call("SET", KEYS[2], ARGV[2])
return 1
`;

// All limits are reserved together before sending; failed delivery retains the
// reservation to prevent provider outages becoming an unbounded send loop.
export const RECOVERY_REQUEST_SCRIPT = `
-- recovery_request_v1
for i = 1, #KEYS do
  local kind = redis.call("TYPE", KEYS[i]).ok
  if kind ~= "none" and kind ~= "string" then return redis.error_reply("Invalid recovery key type") end
end
for i = 1, 5 do
  if tonumber(redis.call("GET", KEYS[i]) or "0") >= tonumber(ARGV[i * 2 - 1]) then return 0 end
end
for i = 1, 5 do
  if redis.call("INCR", KEYS[i]) == 1 then redis.call("EXPIRE", KEYS[i], ARGV[i * 2]) end
end
redis.call("SET", KEYS[6], ARGV[11], "EX", 600)
redis.call("SET", KEYS[7], ARGV[12], "EX", 600)
return 1
`;
export const RECOVERY_VERIFY_SCRIPT = `
-- recovery_verify_v1
local raw = redis.call("GET", KEYS[1])
if not raw then return 0 end
local c = cjson.decode(raw)
if redis.call("GET", KEYS[2]) ~= ARGV[4] then return 0 end
if c.device ~= ARGV[1] or c.expires <= tonumber(ARGV[3]) then return 0 end
if tonumber(redis.call("GET", KEYS[3]) or "0") >= 5 then return -2 end
if c.attempts >= 5 then return 0 end
if redis.call("INCR", KEYS[3]) == 1 then redis.call("EXPIRE", KEYS[3], 3600) end
c.attempts = c.attempts + 1
c.verified = c.digest == ARGV[2]
redis.call("SET", KEYS[1], cjson.encode(c), "KEEPTTL")
if not c.verified then return 0 end
return c.email
`;
export const RECOVERY_COMMIT_SCRIPT = `
-- recovery_commit_v1
for i = 1, #KEYS do
  local kind = redis.call("TYPE", KEYS[i]).ok
  if kind ~= "none" and kind ~= "string" then return redis.error_reply("Invalid recovery key type") end
end
local raw = redis.call("GET", KEYS[1])
if not raw then return 0 end
local c = cjson.decode(raw)
if not c.verified or c.device ~= ARGV[1] or c.digest ~= ARGV[2] or c.expires <= tonumber(ARGV[3]) then return 0 end
if redis.call("GET", KEYS[9]) ~= ARGV[6] then return 0 end
if redis.call("EXISTS", KEYS[10]) == 1 then return -1 end
if redis.call("GET", KEYS[2]) ~= ARGV[4] or redis.call("GET", KEYS[3]) ~= ARGV[5] then return -1 end
if redis.call("EXISTS", KEYS[5]) == 1 then return -1 end
if ARGV[1] ~= ARGV[4] then
  if redis.call("EXISTS", KEYS[6]) == 1 or redis.call("EXISTS", KEYS[7]) == 1 then return -1 end
  local alias = redis.call("GET", KEYS[4])
  if alias and alias ~= ARGV[4] then return -1 end
  redis.call("SET", KEYS[4], ARGV[4])
end
redis.call("SET", KEYS[8], "1")
redis.call("DEL", KEYS[1])
return 1
`;

export async function resolveCanonicalInstallation(redis: RedisLike, device: string): Promise<string> {
  const owner = await redis.get(aliasKey(device));
  if (!owner) return device;
  if (!/^[a-f0-9]{64}$/.test(owner) || owner === device || await redis.get(aliasKey(owner))) throw unavailable();
  return owner;
}

export function createPurchaseRecovery({ redis, env, fetchImpl = fetch, now = () => new Date(), sendEmail }: {
  redis: RedisLike; env: QuillEnv; fetchImpl?: typeof fetch; now?: () => Date; sendEmail?: RecoverySender;
}) {
  const configured = () => {
    if (env.EMAIL_RECOVERY_ENABLED !== "true") throw unavailable();
    if (!env.PORTALY_API_KEY || !/^pcs_(live|test)_/.test(env.PORTALY_API_KEY) || !env.PORTALY_PLAN_ID || !env.INSTALLATION_TOKEN_SECRET || (!sendEmail && (!env.RESEND_API_KEY || !env.RECOVERY_EMAIL_FROM))) throw unavailable();
  };
  const digest = (device: string, challenge: string, code: string) => hash(env.INSTALLATION_TOKEN_SECRET, `recovery-otp:${device}:${challenge}:${code}`);
  const sender: RecoverySender = sendEmail ?? (async ({ to, code, language }) => {
    const response = await fetchImpl("https://api.resend.com/emails", {
      method: "POST", signal: AbortSignal.timeout(10_000),
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: env.RECOVERY_EMAIL_FROM, to: [to],
        subject: language === "zh-TW" ? "Quill 購買恢復驗證碼" : "Quill purchase recovery code",
        text: language === "zh-TW" ? `您的 Quill 驗證碼：${code}。10 分鐘內有效。若非您本人操作，請忽略此信。` : `Your Quill code is ${code}. It expires in 10 minutes. If you did not request this, ignore this email.` }),
    });
    if (!response.ok) throw unavailable();
  });
  return {
    async request(device: string, ip: string, body: any) {
      configured();
      if (typeof body?.email !== "string" || body.email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalize(body.email)) || !["en", "zh-TW"].includes(body.language)) throw new RecoveryError(400, "recovery_invalid_request", "Enter a valid email address.");
      const email = normalize(body.email);
      const id = randomUUID();
      const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
      const emailHash = hash(env.INSTALLATION_TOKEN_SECRET, `recovery-email:${email}`);
      const ipHash = hash(env.INSTALLATION_TOKEN_SECRET, `recovery-ip:${ip}`);
      const result = await redis.eval(RECOVERY_REQUEST_SCRIPT, 7,
        `recovery:cooldown:${emailHash}`, `recovery:email:${emailHash}`, `recovery:device:${device}`, `recovery:ip:${ipHash}`, "recovery:global",
        challengeKey(id), `recovery:active:${device}`, 1, 60, 5, 3600, 5, 3600, 20, 3600, 100, 3600,
        JSON.stringify({ device, email, digest: digest(device, id, code), attempts: 0, verified: false, expires: now().getTime() + 600_000 }), id);
      if (Number(result) !== 1) throw new RecoveryError(429, "recovery_rate_limited", "Too many requests. Please wait before trying again.");
      try { await sender({ to: email, code, language: body.language }); }
      catch {
        await redis.eval('return redis.call("DEL", KEYS[1])', 1, challengeKey(id));
        throw unavailable();
      }
      return { challenge_id: id, expires_in: 600, resend_after: 60 };
    },
    async verify(device: string, body: any) {
      configured();
      if (typeof body?.challenge_id !== "string" || !/^[a-f0-9-]{36}$/.test(body.challenge_id) || typeof body.code !== "string" || !/^\d{6}$/.test(body.code)) throw invalid();
      const key = challengeKey(body.challenge_id);
      const codeDigest = digest(device, body.challenge_id, body.code);
      const email = await redis.eval(RECOVERY_VERIFY_SCRIPT, 3, key, `recovery:active:${device}`, `recovery:guesses:${device}`, device, codeDigest, now().getTime(), body.challenge_id);
      if (Number(email) === -2) throw new RecoveryError(429, "recovery_rate_limited", "Too many verification attempts. Please wait up to one hour before trying again; requesting another code will not reset this limit.");
      if (typeof email !== "string") throw invalid();
      const mode = env.PORTALY_API_KEY!.startsWith("pcs_live_") ? "live" : "test";
      const candidates = new Map<string, any>();
      let cursor: string | undefined;
      const seen = new Set<string>();
      let complete = false;
      try {
        for (let page = 0; page < 5; page++) {
          const url = new URL("/api/creator-subscription/subscriptions", env.PORTALY_API_HOST || "https://portaly.ai");
          url.searchParams.set("customerEmail", email); url.searchParams.set("limit", "100");
          if (cursor) url.searchParams.set("startAfter", cursor);
          const data = await providerRead(redis, env, url.toString(), fetchImpl, now, true);
          if (!Array.isArray(data.data) || data.data.length > 100 || typeof data.pagination?.hasMore !== "boolean") throw unavailable();
          for (const sub of data.data) {
            if (typeof sub?.customerEmail !== "string" || normalize(sub.customerEmail) !== email || sub.planId !== env.PORTALY_PLAN_ID || sub.mode !== mode) continue;
            if (typeof sub.id !== "string" || !/^[A-Za-z0-9_-]{1,200}$/.test(sub.id)) throw unavailable();
            if (!["active", "past_due", "cancel_requested"].includes(sub.status) || !Number.isFinite(Date.parse(sub.nextBillingAt)) || Date.parse(sub.nextBillingAt) <= now().getTime()) continue;
            candidates.set(sub.id, sub);
          }
          if (!data.pagination.hasMore) { complete = true; break; }
          cursor = data.pagination.nextCursor;
          if (typeof cursor !== "string" || !cursor || cursor.length > 1000 || seen.has(cursor)) throw unavailable();
          seen.add(cursor);
        }
      } catch { throw unavailable(); }
      if (!complete) throw unavailable();
      if (candidates.size !== 1) throw new RecoveryError(409, "recovery_no_unique_purchase", "No single eligible purchase could be restored. Please contact support.");
      await reconcilePendingCheckout(redis, env, device, fetchImpl, now);
      const [id] = candidates.keys();
      const owner = await redis.get(`subscription:portaly:${id}`);
      if (!owner || !/^[a-f0-9]{64}$/.test(owner)) throw new RecoveryError(409, "recovery_not_linked", "This purchase is not ready to restore. Please contact support.");
      const raw = await redis.get(subKey(owner));
      let local: any;
      try { local = JSON.parse(raw || "null"); } catch { local = null; }
      if (!local || local.subscriptionId !== id || local.planId !== env.PORTALY_PLAN_ID || local.mode !== mode || !["active", "past_due", "cancel_requested"].includes(local.status) || !Number.isFinite(Date.parse(local.periodStart)) || !Number.isFinite(Date.parse(local.periodEnd)) || Date.parse(local.periodEnd) <= now().getTime()) throw new RecoveryError(409, "recovery_not_linked", "This purchase is not ready to restore. Please contact support.");
      const committed = await redis.eval(RECOVERY_COMMIT_SCRIPT, 10, key, `subscription:portaly:${id}`, subKey(owner), aliasKey(device), aliasKey(owner), subKey(device), canonicalKey(device), canonicalKey(owner), `recovery:active:${device}`, `checkout:pending:${device}`, device, codeDigest, now().getTime(), owner, raw!, body.challenge_id);
      if (Number(committed) === 0) throw invalid();
      if (Number(committed) !== 1) throw new RecoveryError(409, "recovery_conflict", "An existing purchase changed or conflicts with this recovery. Please contact support.");
      return { restored: true };
    },
  };
}
