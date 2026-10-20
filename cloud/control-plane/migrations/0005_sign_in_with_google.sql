-- Sign in with Google (the owner's decision of 2026-10-20), beside Sign in with Apple. An account
-- is a provider's identity: (provider, the provider's `sub`). `users.sub`, which installations
-- and sign-ins refer to, stays the account's key: Apple's `sub` as it was, so accounts made
-- before this keep their Macs, and `google:<sub>` for Google. A provider's `sub` is checked to
-- be letters, digits, `.`, `_` and `-` (src/signin.ts), never a colon, so the two can't meet.

ALTER TABLE users ADD COLUMN provider TEXT NOT NULL DEFAULT 'apple';
-- The account's domain, for company spheres later ("only @deskree.com"): Google's `hd` (the
-- Workspace domain), else the domain of the email Google verified. Never the email. Remote
-- access doesn't use it. Null for Apple, which gives no email.
ALTER TABLE users ADD COLUMN domain TEXT;

-- Which provider a sign-in was started for: only that provider's callback finishes it.
ALTER TABLE sign_ins ADD COLUMN provider TEXT NOT NULL DEFAULT 'apple';
