-- Sign in with Google (the owner's decision of 2026-10-20), beside Sign in with Apple. An account
-- is a provider's identity: (provider, the provider's `sub`). `users.sub`, which installations
-- and sign-ins refer to, stays the account's key: Apple's `sub` as it was, so accounts made
-- before this keep their Macs, and `google:<sub>` for Google. A provider's `sub` is checked to
-- be letters, digits, `.`, `_` and `-` (src/signin.ts), never a colon, so the two can't meet.

ALTER TABLE users ADD COLUMN provider TEXT NOT NULL DEFAULT 'apple';
-- A Google account's two domains, which mean different things; never the email. Null for Apple,
-- which gives no email.
-- `workspace_domain` is Google's `hd`: set only for an account a Google Workspace manages, and
-- the only thing a company sphere ("only @deskree.com") may trust for membership.
ALTER TABLE users ADD COLUMN workspace_domain TEXT;
-- `email_domain` is the domain of the email Google verified. It shows only that the address was
-- reachable once (a personal Google account made on alice@deskree.com keeps it after Alice
-- leaves), so it never grants membership. Remote access uses COALESCE(workspace_domain,
-- email_domain) only to limit how much one domain's accounts can hold (src/app.ts, PER_DOMAIN).
ALTER TABLE users ADD COLUMN email_domain TEXT;
CREATE INDEX users_by_domain ON users (COALESCE(workspace_domain, email_domain));

-- Which provider a sign-in was started for: only that provider's callback finishes it.
ALTER TABLE sign_ins ADD COLUMN provider TEXT NOT NULL DEFAULT 'apple';
