import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { beforeEach, describe, expect, it } from "vitest";
import { handle, hourly, type Database, type Deps, type Statement } from "../src/app";
import type { Fly, MachineEvent, MachineSpec, Stripe, Teams } from "../src/services";
import { runningSeconds } from "../src/usage";

/** D1's interface over SQLite. */
function sqlite(): Database {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(new URL("../schema.sql", import.meta.url), "utf8"));
  const statement = (sql: string, values: unknown[] = []): Statement => ({
    bind: (...next: unknown[]) => statement(sql, next),
    first: async <T>() => (db.prepare(sql).get(...(values as never[])) as T) ?? null,
    all: async <T>() => ({ results: db.prepare(sql).all(...(values as never[])) as T[] }),
    run: async () => db.prepare(sql).run(...(values as never[])),
  });
  return { prepare: (sql) => statement(sql) };
}

class FakeFly implements Fly {
  machines = new Map<string, { spec: MachineSpec; state: string; autostart: boolean; events: MachineEvent[] }>();
  volumes = new Set<string>();
  async createVolume(name: string) { const id = `vol_${name}`; this.volumes.add(id); return id; }
  async createMachine(spec: MachineSpec) {
    const id = `m${this.machines.size + 1}`;
    this.machines.set(id, { spec, state: "created", autostart: true, events: [] });
    return id;
  }
  async machineState(id: string) { return this.machines.get(id)?.state ?? null; }
  async machineImage(id: string) { return this.machines.get(id)?.spec.image ?? null; }
  async updateImage(id: string, image: string) { this.machines.get(id)!.spec.image = image; }
  async events(id: string) { return this.machines.get(id)?.events ?? []; }
  async stop(id: string) { this.machines.get(id)!.state = "stopped"; }
  async setAutostart(id: string, on: boolean) { this.machines.get(id)!.autostart = on; }
  async destroyMachine(id: string) { this.machines.delete(id); }
  async destroyVolume(id: string) { this.volumes.delete(id); }
}

const meterEvents: { customer: string; hours: number; identifier: string }[] = [];
const stripe: Stripe = {
  checkout: async (input) => `https://checkout.test/${input.userID}?price=${input.price}&overage=${input.overagePrice}`,
  portal: async (customer) => `https://portal.test/${customer}`,
  meterEvent: async (_event, customer, hours, identifier) => { meterEvents.push({ customer, hours, identifier }); },
};
const teams: Teams = { whoami: async (token) => (token === "good" ? { id: "U1", email: "neel@example.com" } : null) };
const secret = "whsec_test";

let deps: Deps;
let fly: FakeFly;
let clock: number;

beforeEach(() => {
  fly = new FakeFly();
  clock = 1_800_000_000;
  meterEvents.length = 0;
  deps = {
    db: sqlite(), teams, fly, stripe, now: () => clock, token: () => "gw-token",
    config: { flyApp: "agterm-cloud-machines", image: "img", includedHours: 100, maxHours: 500, overagePrice: "price_over", meterEvent: "hours", volumeGB: 20, price: "price_1", appOrigin: "https://agterm.test", webhookSecret: secret },
  };
});

async function call(method: string, path: string, body?: unknown, token = "good") {
  const response = await handle(new Request(`https://cloud.test${path}`, {
    method, headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), deps);
  return { status: response.status, body: (await response.json()) as any };
}

async function stripeEvent(type: string, object: Record<string, unknown>, at = clock) {
  const body = JSON.stringify({ type, data: { object } });
  const signature = createHmac("sha256", secret).update(`${at}.${body}`).digest("hex");
  const response = await handle(new Request("https://cloud.test/v1/stripe/webhook", {
    method: "POST", headers: { "stripe-signature": `t=${at},v1=${signature}` }, body,
  }), deps);
  return response.status;
}

async function subscribe() {
  expect(await stripeEvent("checkout.session.completed", { client_reference_id: "U1", customer: "cus_1", subscription: "sub_1" })).toBe(200);
  expect(await stripeEvent("customer.subscription.updated", { id: "sub_1", customer: "cus_1", status: "active", current_period_start: clock - 100 })).toBe(200);
}

describe("accounts", () => {
  it("needs an agmux Teams token", async () => {
    expect((await call("GET", "/v1/cloud", undefined, "bad")).status).toBe(401);
    const me = await call("GET", "/v1/cloud");
    expect(me.status).toBe(200);
    expect(me.body).toMatchObject({ plan: "none", hoursUsed: 0, hoursLimit: 100, machine: null });
  });

  it("checkout carries the user so the webhook can find them", async () => {
    expect((await call("POST", "/v1/cloud/checkout")).body.url).toBe("https://checkout.test/U1?price=price_1&overage=price_over");
  });
});

describe("webhook", () => {
  it("rejects bad and stale signatures", async () => {
    await call("GET", "/v1/cloud");
    const body = JSON.stringify({ type: "checkout.session.completed", data: { object: { client_reference_id: "U1" } } });
    const bad = await handle(new Request("https://cloud.test/v1/stripe/webhook", { method: "POST", headers: { "stripe-signature": `t=${clock},v1=00` }, body }), deps);
    expect(bad.status).toBe(400);
    expect(await stripeEvent("checkout.session.completed", { client_reference_id: "U1" }, clock - 3600)).toBe(400);
    expect((await call("GET", "/v1/cloud")).body.plan).toBe("none");
  });

  it("activates on checkout", async () => {
    await call("GET", "/v1/cloud");
    await subscribe();
    expect((await call("GET", "/v1/cloud")).body.plan).toBe("active");
  });
});

describe("machines", () => {
  it("needs a subscription", async () => {
    expect((await call("POST", "/v1/cloud/machine", { user: "neel", home: "/Users/neel" })).status).toBe(402);
  });

  it("refuses names Linux can't use", async () => {
    await call("GET", "/v1/cloud");
    await subscribe();
    for (const bad of [{ user: "Neel Smith", home: "/Users/neel" }, { user: "neel", home: "/Users/../etc" }, { user: "neel", home: "/" }, { user: "neel", home: "relative" }]) {
      expect((await call("POST", "/v1/cloud/machine", bad)).status).toBe(400);
    }
    expect(fly.machines.size).toBe(0);
  });

  it("makes one machine with the volume at the Mac's home path, then reuses it", async () => {
    await call("GET", "/v1/cloud");
    await subscribe();
    const first = await call("POST", "/v1/cloud/machine", { user: "neel", home: "/Users/neel" });
    expect(first.body).toEqual({ url: "wss://agterm-cloud-machines.fly.dev/", machine: "m1", token: "gw-token", user: "neel", home: "/Users/neel" });
    const spec = fly.machines.get("m1")!.spec;
    expect(spec.mountPath).toBe("/Users/neel");
    expect(spec.env).toEqual({ AGTERM_USER: "neel", AGTERM_HOME: "/Users/neel", AGTERM_GATEWAY_TOKEN: "gw-token" });
    expect((await call("POST", "/v1/cloud/machine", { user: "other", home: "/home/other" })).body.machine).toBe("m1");
    expect(fly.machines.size).toBe(1);
  });

  it("stops the machine when the subscription ends, and deletes it 30 days later", async () => {
    await call("GET", "/v1/cloud");
    await subscribe();
    await call("POST", "/v1/cloud/machine", { user: "neel", home: "/Users/neel" });
    fly.machines.get("m1")!.state = "started";
    expect(await stripeEvent("customer.subscription.deleted", { id: "sub_1", customer: "cus_1", status: "canceled" })).toBe(200);
    expect(fly.machines.get("m1")).toMatchObject({ state: "stopped", autostart: false });
    clock += 31 * 24 * 3600;
    await hourly(deps);
    expect(fly.machines.size).toBe(0);
    expect(fly.volumes.size).toBe(0);
  });
});

describe("metering", () => {
  it("counts running time and stops the machine at the limit until the next period", async () => {
    await call("GET", "/v1/cloud");
    await subscribe();
    await call("POST", "/v1/cloud/machine", { user: "neel", home: "/Users/neel" });
    expect((await call("POST", "/v1/cloud/cap", { hours: 2 })).body.hoursLimit).toBe(2);
    const machine = fly.machines.get("m1")!;
    machine.state = "started";
    machine.events = [{ type: "start", status: "started", timestamp: clock * 1000 }];
    clock += 3600;
    await hourly(deps);
    expect((await call("GET", "/v1/cloud")).body).toMatchObject({ hoursUsed: 1, capped: false });
    clock += 3600;
    await hourly(deps);
    expect((await call("GET", "/v1/cloud")).body).toMatchObject({ hoursUsed: 2, capped: true });
    expect(machine).toMatchObject({ state: "stopped", autostart: false });
    expect((await call("POST", "/v1/cloud/machine")).status).toBe(429);
    // Next month.
    expect(await stripeEvent("customer.subscription.updated", { id: "sub_1", customer: "cus_1", status: "active", current_period_start: clock })).toBe(200);
    expect((await call("GET", "/v1/cloud")).body).toMatchObject({ hoursUsed: 0, capped: false });
    expect(machine.autostart).toBe(true);
  });

  it("bills whole hours past the included ones, once each, up to the user's limit", async () => {
    await call("GET", "/v1/cloud");
    await subscribe();
    await call("POST", "/v1/cloud/machine", { user: "neel", home: "/Users/neel" });
    expect((await call("POST", "/v1/cloud/cap", { hours: 103 })).body.hoursLimit).toBe(103);
    const machine = fly.machines.get("m1")!;
    machine.events = [{ type: "start", status: "started", timestamp: clock * 1000 }];
    clock += 101.5 * 3600;
    await hourly(deps);
    expect(meterEvents).toEqual([{ customer: "cus_1", hours: 1, identifier: `U1-${clock - 101.5 * 3600 - 100}-1` }]);
    await hourly(deps);
    expect(meterEvents.length).toBe(1);
    clock += 3600;
    await hourly(deps);
    expect(meterEvents.map((e) => e.hours)).toEqual([1, 1]);
    expect((await call("GET", "/v1/cloud")).body.capped).toBe(false);
    clock += 3600;
    await hourly(deps);
    expect((await call("GET", "/v1/cloud")).body.capped).toBe(true);
    // Raising the limit lets it run again.
    expect((await call("POST", "/v1/cloud/cap", { hours: 200 })).body.capped).toBe(false);
    expect(machine.autostart).toBe(true);
  });

  it("never stops or bills a free account", async () => {
    await call("GET", "/v1/cloud");
    await deps.db.prepare("UPDATE users SET status = 'active', free = 1 WHERE id = 'U1'").run();
    await call("POST", "/v1/cloud/machine", { user: "neel", home: "/Users/neel" });
    const machine = fly.machines.get("m1")!;
    machine.state = "started";
    machine.events = [{ type: "start", status: "started", timestamp: clock * 1000 }];
    clock += 600 * 3600;
    await hourly(deps);
    expect((await call("GET", "/v1/cloud")).body).toMatchObject({ plan: "active", free: true, hoursUsed: 600, capped: false });
    expect(machine).toMatchObject({ state: "started", autostart: true });
    expect(meterEvents.length).toBe(0);
  });

  it("limits stay within the most allowed", async () => {
    expect((await call("POST", "/v1/cloud/cap", { hours: 501 })).status).toBe(400);
    expect((await call("POST", "/v1/cloud/cap", { hours: -1 })).status).toBe(400);
  });
});

describe("image updates", () => {
  it("moves stopped machines to the current image and leaves running ones alone", async () => {
    await call("GET", "/v1/cloud");
    await subscribe();
    await call("POST", "/v1/cloud/machine", { user: "neel", home: "/Users/neel" });
    const machine = fly.machines.get("m1")!;
    deps.config.image = "img:2";
    machine.state = "started";
    await hourly(deps);
    expect(machine.spec.image).toBe("img");
    machine.state = "stopped";
    await hourly(deps);
    expect(machine.spec.image).toBe("img:2");
    expect(machine.state).toBe("stopped");
  });
});

describe("runningSeconds", () => {
  const at = (seconds: number) => seconds * 1000;
  it("adds the intervals between starts and stops inside the window", () => {
    const events: MachineEvent[] = [
      { type: "start", status: "started", timestamp: at(50) },
      { type: "exit", status: "stopped", timestamp: at(150) },
      { type: "start", status: "started", timestamp: at(300) },
      { type: "update", status: "started", timestamp: at(320) },
    ];
    expect(runningSeconds(events, 100, 400)).toBe(50 + 100);
    expect(runningSeconds(events, 0, 200)).toBe(100);
    expect(runningSeconds([], 0, 100)).toBe(0);
  });
});
