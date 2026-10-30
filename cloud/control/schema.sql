-- agterm Cloud control plane: one row per agmux Teams user who has used cloud sessions.
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,               -- agmux Teams user id
  email TEXT,
  stripe_customer TEXT,
  subscription TEXT,                 -- Stripe subscription id
  status TEXT NOT NULL DEFAULT 'none', -- none | active | past_due | canceled
  period_start INTEGER,              -- current billing period, unix seconds
  machine TEXT,                      -- Fly machine id
  volume TEXT,                       -- Fly volume id
  region TEXT,
  unix_user TEXT,
  home TEXT,
  gateway_token TEXT,
  seconds_used INTEGER NOT NULL DEFAULT 0, -- running time this period
  metered_until INTEGER,             -- events up to here are counted
  cap_hours REAL,                    -- the user's own limit; null = included hours
  overage_reported INTEGER NOT NULL DEFAULT 0, -- hours past the included ones sent to Stripe's meter
  capped INTEGER NOT NULL DEFAULT 0, -- stopped for reaching the limit
  canceled_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS users_customer ON users(stripe_customer);
