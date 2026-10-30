import type { Fly, Stripe, Teams, TeamsUser } from "./services";
import { nearestRegion } from "./regions";
import { runningSeconds } from "./usage";
import { verifyStripeSignature } from "./webhook";

export interface Config {
  flyApp: string;
  image: string;
  includedHours: number;
  volumeGB: number;
  price: string;
  appOrigin: string;
  webhookSecret: string;
}

/** The part of D1 used here; tests pass SQLite. */
export interface Statement {
  bind(...values: unknown[]): Statement;
  first<T>(): Promise<T | null>;
  all<T>(): Promise<{ results: T[] }>;
  run(): Promise<unknown>;
}
export interface Database { prepare(sql: string): Statement }

export interface Deps {
  db: Database;
  teams: Teams;
  fly: Fly;
  stripe: Stripe;
  config: Config;
  now(): number;
  token(): string;
}

interface UserRow {
  id: string;
  email: string | null;
  stripe_customer: string | null;
  subscription: string | null;
  status: string;
  period_start: number | null;
  machine: string | null;
  volume: string | null;
  region: string | null;
  unix_user: string | null;
  home: string | null;
  gateway_token: string | null;
  seconds_used: number;
  metered_until: number | null;
  cap_hours: number | null;
  capped: number;
  canceled_at: number | null;
}

class Failure extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/** The pages Stripe Checkout returns to. */
function page(title: string, text: string): Response {
  const escape = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escape(title)}</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111;color:#e8e6e1;font:16px/1.5 -apple-system,system-ui,sans-serif}
main{max-width:30rem;padding:24px}h1{font-size:22px;font-weight:600;margin:0 0 8px}p{margin:0;color:#a8a49c}</style>
<main><h1>${escape(title)}</h1><p>${escape(text)}</p></main>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
}

export async function handle(request: Request, deps: Deps): Promise<Response> {
  const url = new URL(request.url);
  try {
    if (url.pathname === "/v1/stripe/webhook" && request.method === "POST") return await webhook(request, deps);
    if (url.pathname === "/health") return json({ ok: true });
    if (url.pathname === "/cloud/welcome") return page("You're subscribed to agterm Cloud", "Back in agterm, open Settings → Cloud and choose Set Up Machine. Then Shell → Move All Tabs to Cloud moves your tabs there.");
    if (url.pathname === "/cloud") return page("agterm Cloud", "Nothing was charged. You can subscribe any time from agterm's Settings → Cloud.");
    const user = await authenticate(request, deps);
    switch (`${request.method} ${url.pathname}`) {
      case "GET /v1/cloud": return json(await status(user, deps));
      case "POST /v1/cloud/checkout": return json({ url: await checkout(user, deps) });
      case "POST /v1/cloud/portal": return json({ url: await portal(user, deps) });
      case "POST /v1/cloud/machine": return json(await machine(user, request, deps));
      case "POST /v1/cloud/cap": return json(await setCap(user, request, deps));
      default: return json({ error: "not_found" }, 404);
    }
  } catch (error) {
    if (error instanceof Failure) return json({ error: error.code, message: error.message }, error.status);
    console.error(error);
    return json({ error: "internal", message: "Something went wrong." }, 500);
  }
}

// MARK: Accounts

async function authenticate(request: Request, deps: Deps): Promise<UserRow> {
  const token = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
  const teamsUser = token ? await deps.teams.whoami(token) : null;
  if (!teamsUser) throw new Failure(401, "unauthorized", "Sign in to agmux Teams in agterm first.");
  return await upsertUser(teamsUser, deps);
}

async function upsertUser(user: TeamsUser, deps: Deps): Promise<UserRow> {
  await deps.db.prepare("INSERT INTO users (id, email, created_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET email = excluded.email")
    .bind(user.id, user.email, deps.now()).run();
  return (await row(user.id, deps))!;
}

async function row(id: string, deps: Deps): Promise<UserRow | null> {
  return await deps.db.prepare("SELECT * FROM users WHERE id = ?").bind(id).first<UserRow>();
}

function limitHours(user: UserRow, config: Config): number {
  return Math.min(user.cap_hours ?? config.includedHours, config.includedHours);
}

async function status(user: UserRow, deps: Deps) {
  return {
    plan: user.status,
    hoursUsed: Math.round((user.seconds_used / 3600) * 10) / 10,
    hoursLimit: limitHours(user, deps.config),
    capped: user.capped === 1,
    machine: user.machine ? { id: user.machine, state: await deps.fly.machineState(user.machine), region: user.region } : null,
  };
}

// MARK: Billing

async function checkout(user: UserRow, deps: Deps): Promise<string> {
  if (user.status === "active") throw new Failure(409, "already_subscribed", "agterm Cloud is already active.");
  return await deps.stripe.checkout({
    customer: user.stripe_customer, email: user.email, userID: user.id, price: deps.config.price,
    successURL: `${deps.config.appOrigin}/cloud/welcome`, cancelURL: `${deps.config.appOrigin}/cloud`,
  });
}

async function portal(user: UserRow, deps: Deps): Promise<string> {
  if (!user.stripe_customer) throw new Failure(404, "no_customer", "There is no subscription to manage.");
  return await deps.stripe.portal(user.stripe_customer, `${deps.config.appOrigin}/cloud`);
}

async function webhook(request: Request, deps: Deps): Promise<Response> {
  const body = await request.text();
  const valid = await verifyStripeSignature(body, request.headers.get("stripe-signature"), deps.config.webhookSecret, deps.now());
  if (!valid) return json({ error: "bad_signature" }, 400);
  const event = JSON.parse(body) as { type: string; data: { object: Record<string, any> } };
  const object = event.data.object;
  switch (event.type) {
    case "checkout.session.completed": {
      const id = object.client_reference_id as string | undefined;
      if (!id) break;
      await deps.db.prepare("UPDATE users SET stripe_customer = ?, subscription = ?, status = 'active', canceled_at = NULL WHERE id = ?")
        .bind(object.customer ?? null, object.subscription ?? null, id).run();
      break;
    }
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      const status = event.type === "customer.subscription.deleted" ? "canceled"
        : object.status === "active" || object.status === "trialing" ? "active"
        : object.status === "past_due" || object.status === "unpaid" ? "past_due" : "canceled";
      const user = await deps.db.prepare("SELECT * FROM users WHERE stripe_customer = ? OR subscription = ?")
        .bind(object.customer, object.id).first<UserRow>();
      if (!user) break;
      const start = typeof object.current_period_start === "number" ? object.current_period_start : user.period_start;
      const newPeriod = start !== user.period_start;
      await deps.db.prepare(`UPDATE users SET status = ?, subscription = ?, period_start = ?,
          seconds_used = CASE WHEN ? THEN 0 ELSE seconds_used END, capped = CASE WHEN ? THEN 0 ELSE capped END,
          canceled_at = CASE WHEN ? = 'canceled' THEN COALESCE(canceled_at, ?) ELSE NULL END WHERE id = ?`)
        .bind(status, object.id, start, newPeriod ? 1 : 0, newPeriod ? 1 : 0, status, deps.now(), user.id).run();
      if (user.machine && newPeriod && user.capped) await deps.fly.setAutostart(user.machine, true);
      if (user.machine && status !== "active") await stopFor(user.machine, deps);
      break;
    }
  }
  return json({ received: true });
}

// MARK: Machines

const unixName = /^[a-z_][a-z0-9_.-]{0,31}$/;

/** The user's machine, made on first use; the app connects through Fly's proxy, which starts it. */
async function machine(user: UserRow, request: Request, deps: Deps) {
  if (user.status !== "active") throw new Failure(402, "not_subscribed", "Subscribe to agterm Cloud first.");
  if (user.capped) throw new Failure(429, "capped", "This month's cloud hours are used up.");
  let current = user;
  if (!user.machine) {
    const body = (await request.json().catch(() => ({}))) as { user?: string; home?: string };
    const unixUser = body.user ?? "";
    const home = body.home ?? "";
    if (!unixName.test(unixUser) || !/^\/[A-Za-z0-9._\/-]{1,200}$/.test(home) || home.includes("..") || home === "/") {
      throw new Failure(400, "bad_account", "The Mac's user name or home folder can't be used on Linux.");
    }
    const cf = (request as Request & { cf?: { continent?: string; longitude?: string } }).cf;
    const region = nearestRegion(cf?.continent, cf?.longitude ? Number(cf.longitude) : undefined);
    const token = deps.token();
    const name = `u-${user.id}`.toLowerCase().replace(/[^a-z0-9-]/g, "-").slice(0, 60);
    const volume = await deps.fly.createVolume(name.replace(/-/g, "_").slice(0, 30), region, deps.config.volumeGB);
    let machineID: string;
    try {
      machineID = await deps.fly.createMachine({
        name, region, image: deps.config.image, volume, mountPath: home,
        env: { AGTERM_USER: unixUser, AGTERM_HOME: home, AGTERM_GATEWAY_TOKEN: token },
      });
    } catch (error) {
      await deps.fly.destroyVolume(volume).catch(() => {});
      throw error;
    }
    await deps.db.prepare(`UPDATE users SET machine = ?, volume = ?, region = ?, unix_user = ?, home = ?, gateway_token = ?,
        metered_until = ? WHERE id = ?`)
      .bind(machineID, volume, region, unixUser, home, token, deps.now(), user.id).run();
    current = (await row(user.id, deps))!;
  }
  return {
    url: `wss://${deps.config.flyApp}.fly.dev/`,
    machine: current.machine,
    token: current.gateway_token,
    user: current.unix_user,
    home: current.home,
  };
}

async function setCap(user: UserRow, request: Request, deps: Deps) {
  const body = (await request.json().catch(() => ({}))) as { hours?: number | null };
  const hours = body.hours === null || body.hours === undefined ? null : Number(body.hours);
  if (hours !== null && !(hours >= 0 && hours <= deps.config.includedHours)) {
    throw new Failure(400, "bad_cap", `The limit must be between 0 and ${deps.config.includedHours} hours.`);
  }
  await deps.db.prepare("UPDATE users SET cap_hours = ? WHERE id = ?").bind(hours, user.id).run();
  return status((await row(user.id, deps))!, deps);
}

async function stopFor(machineID: string, deps: Deps) {
  await deps.fly.setAutostart(machineID, false).catch((error) => console.error(error));
  await deps.fly.stop(machineID).catch((error) => console.error(error));
}

// MARK: Hourly

const retainAfterCancel = 30 * 24 * 3600;

/** Meters every machine's running time, stops machines past their limit, and deletes machines
 *  and volumes 30 days after a subscription ends. */
export async function hourly(deps: Deps): Promise<void> {
  const users = (await deps.db.prepare("SELECT * FROM users WHERE machine IS NOT NULL").all<UserRow>()).results;
  const now = deps.now();
  for (const user of users) {
    try {
      if (user.status === "canceled" && user.canceled_at && now - user.canceled_at > retainAfterCancel) {
        await deps.fly.destroyMachine(user.machine!);
        if (user.volume) await deps.fly.destroyVolume(user.volume);
        await deps.db.prepare("UPDATE users SET machine = NULL, volume = NULL, gateway_token = NULL WHERE id = ?").bind(user.id).run();
        continue;
      }
      const from = Math.max(user.metered_until ?? now, user.period_start ?? 0);
      const used = user.seconds_used + runningSeconds(await deps.fly.events(user.machine!), from, now);
      const over = used >= limitHours(user, deps.config) * 3600;
      await deps.db.prepare("UPDATE users SET seconds_used = ?, metered_until = ?, capped = ? WHERE id = ?")
        .bind(used, now, over ? 1 : user.capped, user.id).run();
      if (over && !user.capped) await stopFor(user.machine!, deps);
    } catch (error) {
      console.error(`metering ${user.id}`, error);
    }
  }
}
