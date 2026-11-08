import { describe, expect, it } from "vitest";
import worker from "../src/index";
import { makeEnv } from "./helpers/d1";

const env = () => makeEnv({ APP_ORIGIN: "https://teams.agterm.dev" });
const fetchAt = (url: string, init: RequestInit = {}) => worker.fetch(new Request(url, init), env());

describe("teams.agmux.dev, the old host", () => {
  it("sends page visits to teams.agterm.dev, keeping path and query", async () => {
    const res = await fetchAt("https://teams.agmux.dev/join/abc?x=1");
    expect(res.status).toBe(308);
    expect(res.headers.get("Location")).toBe("https://teams.agterm.dev/join/abc?x=1");
  });

  it("sends browser sign-in to the new host so cookies and the OAuth callback share it", async () => {
    const res = await fetchAt("https://teams.agmux.dev/api/auth/github/start?link=1", { headers: { Accept: "text/html" } });
    expect(res.status).toBe(308);
    expect(res.headers.get("Location")).toBe("https://teams.agterm.dev/api/auth/github/start?link=1");
  });

  it("still answers API calls from agmux and older agterm builds", async () => {
    const res = await fetchAt("https://teams.agmux.dev/api/health");
    expect(res.status).toBe(200);
    const unauthorized = await fetchAt("https://teams.agmux.dev/api/me");
    expect(unauthorized.status).not.toBe(308);
  });

  it("still accepts webhooks and other POSTs", async () => {
    const res = await fetchAt("https://teams.agmux.dev/api/billing/webhook", { method: "POST", body: "{}", headers: { Accept: "text/html" } });
    expect(res.status).not.toBe(308);
  });

  it("leaves requests on the new host alone", async () => {
    const res = await fetchAt("https://teams.agterm.dev/join/abc");
    expect(res.status).not.toBe(308);
  });
});
