import { handle, hourly, type Deps } from "./app";
import { HttpFly, HttpStripe, HttpTeams } from "./services";

export interface Env {
  DB: D1Database;
  TEAMS_URL: string;
  FLY_APP: string;
  CLOUD_IMAGE: string;
  INCLUDED_HOURS: string;
  VOLUME_GB: string;
  STRIPE_PRICE: string;
  APP_ORIGIN: string;
  FLY_API_TOKEN: string;
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
}

function deps(env: Env): Deps {
  return {
    db: env.DB,
    teams: new HttpTeams(env.TEAMS_URL),
    fly: new HttpFly(env.FLY_APP, env.FLY_API_TOKEN),
    stripe: new HttpStripe(env.STRIPE_SECRET_KEY),
    config: {
      flyApp: env.FLY_APP,
      image: env.CLOUD_IMAGE,
      includedHours: Number(env.INCLUDED_HOURS),
      volumeGB: Number(env.VOLUME_GB),
      price: env.STRIPE_PRICE,
      appOrigin: env.APP_ORIGIN,
      webhookSecret: env.STRIPE_WEBHOOK_SECRET,
    },
    now: () => Math.floor(Date.now() / 1000),
    token: () => [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, "0")).join(""),
  };
}

export default {
  fetch: (request: Request, env: Env) => handle(request, deps(env)),
  scheduled: async (_event: ScheduledEvent, env: Env, context: ExecutionContext) => context.waitUntil(hourly(deps(env))),
};
