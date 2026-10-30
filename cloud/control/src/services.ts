// The outside services the control plane uses, behind small interfaces so tests can fake them.

export interface TeamsUser { id: string; email: string | null }

/** agmux Teams: who a device token belongs to. */
export interface Teams { whoami(token: string): Promise<TeamsUser | null> }

export interface MachineSpec {
  name: string;
  region: string;
  image: string;
  env: Record<string, string>;
  volume: string;
  mountPath: string;
}

export interface MachineEvent { type: string; status: string; timestamp: number }

/** Fly Machines API, for one app. */
export interface Fly {
  createVolume(name: string, region: string, sizeGB: number): Promise<string>;
  createMachine(spec: MachineSpec): Promise<string>;
  machineState(id: string): Promise<string | null>;
  events(id: string): Promise<MachineEvent[]>;
  stop(id: string): Promise<void>;
  setAutostart(id: string, autostart: boolean): Promise<void>;
  destroyMachine(id: string): Promise<void>;
  destroyVolume(id: string): Promise<void>;
}

export interface Stripe {
  checkout(input: { customer: string | null; email: string | null; userID: string; price: string; successURL: string; cancelURL: string }): Promise<string>;
  portal(customer: string, returnURL: string): Promise<string>;
}

export class HttpTeams implements Teams {
  constructor(private base: string) {}
  async whoami(token: string): Promise<TeamsUser | null> {
    const response = await fetch(`${this.base}/api/auth/me`, { headers: { authorization: `Bearer ${token}`, accept: "application/json" } });
    if (!response.ok) return null;
    const body = (await response.json()) as { data?: { user?: { id?: string; email?: string } } };
    const user = body.data?.user;
    return user?.id ? { id: user.id, email: user.email ?? null } : null;
  }
}

export class HttpFly implements Fly {
  private base: string;
  constructor(app: string, private token: string) {
    this.base = `https://api.machines.dev/v1/apps/${app}`;
  }

  private async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    const response = await fetch(this.base + path, {
      method,
      // Deploy tokens come as "FlyV1 …", which is the whole header; older tokens take Bearer.
      headers: { authorization: this.token.startsWith("FlyV1 ") ? this.token : `Bearer ${this.token}`, "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!response.ok) throw new Error(`Fly ${method} ${path}: ${response.status} ${await response.text()}`);
    const text = await response.text();
    return (text ? JSON.parse(text) : {}) as T;
  }

  async createVolume(name: string, region: string, sizeGB: number): Promise<string> {
    return (await this.call<{ id: string }>("POST", "/volumes", { name, region, size_gb: sizeGB, encrypted: true })).id;
  }

  async createMachine(spec: MachineSpec): Promise<string> {
    const config = {
      image: spec.image,
      env: spec.env,
      // New Fly orgs allow 2 cores a machine; 4 GB is the plan's memory.
      guest: { cpu_kind: "shared", cpus: 2, memory_mb: 4096 },
      mounts: [{ volume: spec.volume, path: spec.mountPath }],
      // The helper exits 0 when idle, which stops the machine; it restarts only after a crash.
      restart: { policy: "on-failure" },
      services: [{
        protocol: "tcp",
        internal_port: 8080,
        autostart: true,
        autostop: "off",
        ports: [{ port: 443, handlers: ["tls", "http"] }],
        checks: [{ type: "http", path: "/health", interval: "30s", timeout: "5s", grace_period: "10s", method: "GET" }],
      }],
    };
    return (await this.call<{ id: string }>("POST", "/machines", { name: spec.name, region: spec.region, config })).id;
  }

  async machineState(id: string): Promise<string | null> {
    try {
      return (await this.call<{ state: string }>("GET", `/machines/${id}`)).state;
    } catch {
      return null;
    }
  }

  async events(id: string): Promise<MachineEvent[]> {
    const machine = await this.call<{ events?: MachineEvent[] }>("GET", `/machines/${id}`);
    return machine.events ?? [];
  }

  async stop(id: string): Promise<void> {
    await this.call("POST", `/machines/${id}/stop`, {});
  }

  async setAutostart(id: string, autostart: boolean): Promise<void> {
    const machine = await this.call<{ config: { services?: { autostart?: boolean }[] } }>("GET", `/machines/${id}`);
    const config = machine.config;
    for (const service of config.services ?? []) service.autostart = autostart;
    // Updating a stopped machine leaves it stopped.
    await this.call("POST", `/machines/${id}`, { config, skip_launch: true });
  }

  async destroyMachine(id: string): Promise<void> {
    await this.call("DELETE", `/machines/${id}?force=true`);
  }

  async destroyVolume(id: string): Promise<void> {
    await this.call("DELETE", `/volumes/${id}`);
  }
}

export class HttpStripe implements Stripe {
  constructor(private key: string) {}

  private async form(path: string, fields: Record<string, string>): Promise<{ url: string }> {
    const response = await fetch(`https://api.stripe.com/v1${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${this.key}`, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(fields),
    });
    if (!response.ok) throw new Error(`Stripe ${path}: ${response.status} ${await response.text()}`);
    return (await response.json()) as { url: string };
  }

  async checkout(input: { customer: string | null; email: string | null; userID: string; price: string; successURL: string; cancelURL: string }): Promise<string> {
    const fields: Record<string, string> = {
      mode: "subscription",
      "line_items[0][price]": input.price,
      "line_items[0][quantity]": "1",
      client_reference_id: input.userID,
      "subscription_data[metadata][agterm_user]": input.userID,
      success_url: input.successURL,
      cancel_url: input.cancelURL,
    };
    if (input.customer) fields.customer = input.customer;
    else if (input.email) fields.customer_email = input.email;
    return (await this.form("/checkout/sessions", fields)).url;
  }

  async portal(customer: string, returnURL: string): Promise<string> {
    return (await this.form("/billing_portal/sessions", { customer, return_url: returnURL })).url;
  }
}
