-- Test for migration 5 (revoke_extra_privileges). Needs the local seed data (supabase db reset).
-- Run in cmd with:
--   docker exec -i supabase_db_smart-pillbox psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase\tests\privileges_test.sql
-- A pass ends with the deliberate error: ALL TESTS PASSED (test data rolled back)

begin;

do $$
declare
  t text;
  p text;
  r text;
begin
  -- No table in public lets anon or authenticated truncate, reference, trigger or maintain
  for t in select c.oid::regclass::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r', 'p') loop
    foreach r in array array['anon', 'authenticated'] loop
      foreach p in array array['TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'] loop
        if has_table_privilege(r, t, p) then
          raise exception 'FAIL: % still has % on %', r, p, t;
        end if;
      end loop;
    end loop;
    -- anon has nothing at all
    foreach p in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE'] loop
      if has_table_privilege('anon', t, p) then
        raise exception 'FAIL: anon has % on %', p, t;
      end if;
    end loop;
  end loop;

  -- The app's own grants are still there
  if not has_table_privilege('authenticated', 'public.prescriptions', 'INSERT')
     or not has_table_privilege('authenticated', 'public.change_log', 'SELECT')
     or not has_column_privilege('authenticated', 'public.prescription_medicines', 'notes', 'UPDATE') then
    raise exception 'FAIL: an authenticated grant was lost';
  end if;
  if has_column_privilege('authenticated', 'public.prescription_medicines', 'patient_id', 'UPDATE') then
    raise exception 'FAIL: patient_id became updatable';
  end if;

  -- A table created later gets none of the extra privileges
  create table public.zz_privilege_probe (id int);
  foreach r in array array['anon', 'authenticated'] loop
    foreach p in array array['TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'] loop
      if has_table_privilege(r, 'public.zz_privilege_probe', p) then
        raise exception 'FAIL: new table gives % %', r, p;
      end if;
    end loop;
  end loop;

  -- Nobody but the owner can call rls_auto_enable
  if has_function_privilege('anon', 'public.rls_auto_enable()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.rls_auto_enable()', 'EXECUTE') then
    raise exception 'FAIL: rls_auto_enable is still callable';
  end if;
end $$;

-- The real attack: anon truncating a table no foreign key points at
set local role anon;
do $$
begin
  begin
    truncate public.change_log;
    raise exception 'FAIL: anon could truncate change_log';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

set local role authenticated;
do $$
begin
  begin
    truncate public.push_tokens;
    raise exception 'FAIL: authenticated could truncate push_tokens';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

do $$ begin raise exception 'ALL TESTS PASSED (test data rolled back)'; end $$;
