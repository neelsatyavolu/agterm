import type { Env } from "./env";

/** The service's first home. agmux and agterm builds before 1.1.8 call its API there. */
const LEGACY_HOSTS = new Set(["teams.agmux.dev"]);

/**
 * A browser visit to the old host moves to APP_ORIGIN, so pages, sign-in
 * cookies and OAuth callbacks all live on one host. API calls, webhooks and
 * other non-GET requests are answered where they arrive. Browsers send
 * `Accept: text/html` on navigations; app fetches don't.
 */
export function legacyRedirect(req: Request, env: Env): Response | null {
  const url = new URL(req.url);
  if (!LEGACY_HOSTS.has(url.hostname)) return null;
  const target = new URL(env.APP_ORIGIN);
  if (url.hostname === target.hostname) return null;
  if (req.method !== "GET" && req.method !== "HEAD") return null;
  const isPage = !url.pathname.startsWith("/api/");
  const isNavigation = (req.headers.get("Accept") ?? "").includes("text/html");
  if (!isPage && !isNavigation) return null;
  return Response.redirect(`${target.origin}${url.pathname}${url.search}`, 308);
}
