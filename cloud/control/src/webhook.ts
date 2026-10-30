/** Stripe's webhook signature (`t=…,v1=…`): HMAC-SHA256 of `t.body`, within 5 minutes. */
export async function verifyStripeSignature(body: string, header: string | null, secret: string, now: number): Promise<boolean> {
  if (!header || !secret) return false;
  const parts = new Map<string, string[]>();
  for (const item of header.split(",")) {
    const [key, value] = item.split("=", 2);
    if (key && value) parts.set(key, [...(parts.get(key) ?? []), value]);
  }
  const timestamp = Number(parts.get("t")?.[0]);
  if (!Number.isFinite(timestamp) || Math.abs(now - timestamp) > 300) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${body}`)));
  const expected = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  return (parts.get("v1") ?? []).some((candidate) => constantTimeEqual(candidate, expected));
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
