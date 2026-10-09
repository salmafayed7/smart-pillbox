-- Migration 5: remove privileges the app never needs.
--
-- The baseline revoked SELECT/INSERT/UPDATE/DELETE from anon and authenticated, but left
-- TRUNCATE, REFERENCES, TRIGGER and MAINTAIN. TRUNCATE skips row-level security, so with a
-- direct database connection anon could empty tables that no foreign key points at
-- (change_log, push_tokens, adherence_log, devices). The API does not expose TRUNCATE,
-- so this is hardening, not a hole that was reachable from the app.

-- anon has no use for any table in public
revoke all on all tables in schema public from anon;

-- signed-in users keep exactly the SELECT/INSERT/UPDATE/DELETE grants from migrations 2 to 4
revoke truncate, references, trigger, maintain on all tables in schema public from anon, authenticated;

-- same for tables created later by the postgres role (the role migrations run as)
alter default privileges for role postgres in schema public
  revoke truncate, references, trigger, maintain on tables from anon, authenticated;

-- rls_auto_enable() is an event-trigger helper from the baseline. The baseline revoked it from
-- the named roles but not from PUBLIC, so anon and authenticated could still call it.
revoke execute on function public.rls_auto_enable() from public;
