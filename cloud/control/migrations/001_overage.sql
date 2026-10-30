-- Overage hours already sent to Stripe's meter this period.
ALTER TABLE users ADD COLUMN overage_reported INTEGER NOT NULL DEFAULT 0;
