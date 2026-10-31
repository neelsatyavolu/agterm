-- Accounts that are active without a subscription: no limit, never billed.
ALTER TABLE users ADD COLUMN free INTEGER NOT NULL DEFAULT 0;
