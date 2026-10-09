-- Test for save_prescription (migration 3, the 4th migration file). Needs the local seed data (supabase db reset).
-- Run in cmd with:
--   docker exec -i supabase_db_smart-pillbox psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase\tests\save_prescription_test.sql
-- A pass ends with the deliberate error: ALL TESTS PASSED (test data rolled back)
-- Everything runs in one transaction that is never committed, helpers included.
-- Counts are compared before and after, because the seed adds rows.

begin;

create schema th;
grant usage on schema th to anon, authenticated;

-- Become a seed user (run while still the superuser; call "reset role" first when switching)
create function th.act_as(p_email text) returns void
language plpgsql as $$
declare u uuid;
begin
  select id into u from auth.users where email = p_email;
  if u is null then raise exception 'test user % is missing', p_email; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

-- Call save_prescription as whoever is current; return 'ok' or the error text
create function th.try_save(p_pid int, p_meds jsonb) returns text
language plpgsql as $$
begin
  perform public.save_prescription(p_pid, p_meds);
  return 'ok';
exception when others then
  return sqlerrm;
end $$;

create function th.check(c boolean, msg text) returns void
language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', msg; end if;
end $$;

do $$
declare
  pt int;
  r jsonb;
  res text;
  p0 int; m0 int; l0 int;
  good jsonb := '[
    {"name":"Augmentin","dose":"625 mg","frequency":"twice a day","duration":"5 days",
     "schedule":{"morning":1,"noon":0,"evening":0,"night":1},"tablets_per_dose":1,"form":"tablet",
     "notes":"after meals","times_per_day":2,"duration_days":5},
    {"name":" Hexigel gum paint ","dose":"","frequency":"","duration":"1 week","schedule":null,
     "tablets_per_dose":null,"form":"other","notes":"massage","times_per_day":null,"duration_days":7}
  ]';
  rec record;
begin
  select id into pt from patients where email = 'patient@test.com';
  perform th.check(pt is not null, 'seed patient exists');

  select count(*) into p0 from prescriptions;
  select count(*) into m0 from prescription_medicines;
  select count(*) into l0 from change_log where patient_id = pt;

  ------------------------------------------------------------------ the patient saves
  perform th.act_as('patient@test.com');
  r := public.save_prescription(pt, good);
  execute 'reset role';

  perform th.check((select count(*) from prescriptions) = p0 + 1, 'one prescription added');
  perform th.check((select count(*) from prescription_medicines) = m0 + 2, 'two medicines added');
  perform th.check(jsonb_array_length(r -> 'medicine_ids') = 2, 'two ids returned');
  perform th.check((select patient_id from prescriptions where id = (r ->> 'prescription_id')::int) = pt, 'prescription belongs to patient');
  perform th.check((select image_path from prescriptions where id = (r ->> 'prescription_id')::int) is null, 'no image path');
  perform th.check((select count(*) from change_log where patient_id = pt) = l0 + 3, 'change_log has 1 prescription + 2 medicine rows');

  select * into rec from prescription_medicines where id = (r -> 'medicine_ids' ->> 0)::int;
  perform th.check(rec.med_name = 'Augmentin' and rec.dosage = '625 mg', 'first id is the first medicine');
  perform th.check(rec.prescription_id = (r ->> 'prescription_id')::int and rec.patient_id = pt, 'medicine linked to prescription and patient');
  perform th.check(rec.dose_morning = 1 and rec.dose_noon = 0 and rec.dose_evening = 0 and rec.dose_night = 1, 'schedule stored');
  perform th.check(rec.tablets_per_dose = 1 and rec.times_per_day = 2 and rec.duration_days = 5 and rec.form = 'tablet', 'numbers stored');

  select * into rec from prescription_medicines where id = (r -> 'medicine_ids' ->> 1)::int;
  perform th.check(rec.med_name = 'Hexigel gum paint', 'name trimmed, second id is the second medicine');
  perform th.check(rec.dosage is null and rec.frequency is null, 'empty strings become null');
  perform th.check(rec.dose_morning is null and rec.dose_night is null, 'null schedule stays null');
  perform th.check(rec.form = 'other' and rec.duration_days = 7 and rec.tablets_per_dose is null, 'second medicine fields');

  ------------------------------------------------------------------ who may save
  select count(*) into p0 from prescriptions;

  execute 'reset role'; perform th.act_as('caregiver@test.com');
  res := th.try_save(pt, good);
  execute 'reset role';
  perform th.check(res = 'ok', 'caregiver with manage can save, got: ' || res);

  select count(*) into p0 from prescriptions;
  select count(*) into m0 from prescription_medicines;

  perform th.act_as('viewer@test.com');
  res := th.try_save(pt, good);
  execute 'reset role';
  perform th.check(res = 'not allowed', 'view-only caregiver is refused, got: ' || res);

  perform th.act_as('newcaregiver@test.com');
  res := th.try_save(pt, good);
  execute 'reset role';
  perform th.check(res = 'not allowed', 'unlinked caregiver is refused, got: ' || res);

  perform set_config('role', 'anon', true);
  res := th.try_save(pt, good);
  execute 'reset role';
  perform th.check(res like 'permission denied%', 'anonymous caller has no execute right, got: ' || res);

  perform th.act_as('patient@test.com');
  res := th.try_save(null, good);
  execute 'reset role';
  perform th.check(res = 'not allowed', 'null patient id is refused, got: ' || res);

  perform th.check((select count(*) from prescriptions) = p0, 'refused calls added no prescriptions');
  perform th.check((select count(*) from prescription_medicines) = m0, 'refused calls added no medicines');

  ------------------------------------------------------------------ bad input is refused and nothing is kept
  perform th.act_as('patient@test.com');

  res := th.try_save(pt, '[]');                          perform th.check(res = 'invalid medicine list', 'empty list: ' || res);
  res := th.try_save(pt, '{}');                          perform th.check(res = 'invalid medicine list', 'not an array: ' || res);
  res := th.try_save(pt, 'null');                        perform th.check(res = 'invalid medicine list', 'json null: ' || res);
  res := th.try_save(pt, null);                          perform th.check(res = 'invalid medicine list', 'sql null: ' || res);
  res := th.try_save(pt, '["Augmentin"]');               perform th.check(res = 'invalid medicine list', 'element not an object: ' || res);
  res := th.try_save(pt, (select jsonb_agg(jsonb_build_object('name', 'M' || g)) from generate_series(1, 31) g));
  perform th.check(res = 'invalid medicine list', '31 medicines: ' || res);
  res := th.try_save(pt, (select jsonb_agg(jsonb_build_object('name', 'M' || g)) from generate_series(1, 30) g));
  perform th.check(res = 'ok', '30 medicines is allowed: ' || res);

  select count(*) into p0 from prescriptions;
  select count(*) into m0 from prescription_medicines;

  res := th.try_save(pt, '[{"name":""}]');               perform th.check(res = 'invalid medicine', 'blank name: ' || res);
  res := th.try_save(pt, '[{"dose":"5 mg"}]');           perform th.check(res = 'invalid medicine', 'missing name: ' || res);
  res := th.try_save(pt, jsonb_build_array(jsonb_build_object('name', repeat('x', 121))));
  perform th.check(res = 'invalid medicine', 'name too long: ' || res);
  res := th.try_save(pt, '[{"name":"A","form":"capsule"}]');
  perform th.check(res = 'invalid medicine', 'unknown form: ' || res);
  res := th.try_save(pt, '[{"name":"A","tablets_per_dose":11}]');
  perform th.check(res like '%prescription_medicines_tablets_check%', 'too many tablets: ' || res);
  res := th.try_save(pt, '[{"name":"A","tablets_per_dose":0.3}]');
  perform th.check(res like '%prescription_medicines_tablets_check%', 'not a half step: ' || res);
  res := th.try_save(pt, '[{"name":"A","duration_days":400}]');
  perform th.check(res like '%prescription_medicines_duration_days_check%', 'duration too long: ' || res);
  res := th.try_save(pt, '[{"name":"A","times_per_day":13}]');
  perform th.check(res like '%prescription_medicines_times_per_day_check%', 'times per day too high: ' || res);
  res := th.try_save(pt, '[{"name":"A","schedule":{"morning":0,"noon":0,"evening":0,"night":0}}]');
  perform th.check(res like '%prescription_medicines_dose_slots_check%', 'all-zero schedule: ' || res);
  res := th.try_save(pt, '[{"name":"A","schedule":{"morning":-1,"noon":1}}]');
  perform th.check(res like '%prescription_medicines_dose_slots_check%', 'negative dose: ' || res);
  res := th.try_save(pt, '[{"name":"A","schedule":{"morning":1}}]');
  perform th.check(res = 'ok', 'missing slots count as 0: ' || res);

  -- A valid first medicine followed by an invalid second one must leave nothing behind
  select count(*) into p0 from prescriptions;
  select count(*) into m0 from prescription_medicines;
  res := th.try_save(pt, '[{"name":"Good"},{"name":"Bad","tablets_per_dose":99}]');
  perform th.check(res like '%prescription_medicines_tablets_check%', 'second medicine invalid: ' || res);
  execute 'reset role';
  perform th.check((select count(*) from prescriptions) = p0, 'rolled back: no prescription left behind');
  perform th.check((select count(*) from prescription_medicines) = m0, 'rolled back: no medicine left behind');

  ------------------------------------------------------------------ direct writes still follow the column grants
  perform th.act_as('patient@test.com');
  update prescription_medicines set notes = 'edited', dose_night = 2
   where id = (r -> 'medicine_ids' ->> 0)::int;
  execute 'reset role';
  perform th.check((select notes from prescription_medicines where id = (r -> 'medicine_ids' ->> 0)::int) = 'edited',
                   'new columns can be edited by the app');
end $$;

do $$ begin raise exception 'ALL TESTS PASSED (test data rolled back)'; end $$;
