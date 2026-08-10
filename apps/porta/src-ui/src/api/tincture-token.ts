import type { McpClient } from "./mcp-client";

/**
 * Short-lived, scoped credential for tincture URLs.
 *
 * Tincture iframes and `<img>` tags cannot carry headers, so whatever
 * authenticates them travels in the URL — where browsers keep it in history and
 * leak it through `Referer`, and intermediaries log it. Putting the account's
 * session token there means a full-permission bearer credential in all of those
 * places.
 *
 * `GET /t/access-token` exchanges the real credential (sent properly, in a
 * header) for a token that lasts an hour and carries `permissions: [:execute]`
 * and nothing else. That is what belongs in a URL.
 *
 * Cached until shortly before expiry, with concurrent callers sharing one
 * in-flight mint so a page of previews doesn't trigger a burst.
 */

interface CachedToken {
  token: string;
  /** Epoch ms after which the token must not be reused. */
  expiresAt: number;
}

/** Renew this long before actual expiry, so an in-flight load can't age out. */
const RENEW_MARGIN_MS = 60_000;

let cached: CachedToken | null = null;
let inflight: Promise<string> | null = null;

async function mint(client: McpClient): Promise<string> {
  const credential = client.apiKey || client.sessionId;
  if (!credential) throw new Error("no credential to exchange");

  const resp = await fetch(`${client.baseUrl}/t/access-token`, {
    method: "GET",
    headers: { authorization: `Bearer ${credential}` },
    credentials: "include",
  });

  if (!resp.ok) throw new Error(`access-token HTTP ${resp.status}`);

  const body = (await resp.json()) as { token?: string; expires_in?: number };
  if (!body.token) throw new Error("access-token response had no token");

  const ttlMs = (body.expires_in ?? 3600) * 1000;
  cached = { token: body.token, expiresAt: Date.now() + ttlMs };
  return body.token;
}

/**
 * A currently-valid tincture access token, minting or renewing as needed.
 * Returns "" when there is no credential to exchange or the mint fails, so
 * callers degrade to an unauthenticated URL rather than throwing mid-render.
 */
export async function tinctureAccessToken(client: McpClient): Promise<string> {
  if (cached && cached.expiresAt > Date.now() + RENEW_MARGIN_MS) {
    return cached.token;
  }

  if (!inflight) {
    inflight = mint(client)
      .catch(() => "")
      .finally(() => {
        inflight = null;
      });
  }

  return inflight;
}

/** Drop the cached token — call on logout, or when the credential changes. */
export function resetTinctureAccessToken(): void {
  cached = null;
  inflight = null;
}
