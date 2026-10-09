-- Access-rule tests. Run against the LOCAL database only.
-- Everything is rolled back at the end: a pass shows "ERROR: ALL TESTS PASSED".
begin;

-- helper: act as a logged-in user
create function public.t_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

-- helper: true if the statement raises an error
create function public.t_fails(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;

insert into public.devices (device_code) values ('PB-TEST0001');

do $$
declare
  p1 uuid := gen_random_uuid();  -- patient 1
  p2 uuid := gen_random_uuid();  -- patient 2 (outsider)
  c1 uuid := gen_random_uuid();  -- caregiver, will get 'manage'
  c2 uuid := gen_random_uuid();  -- caregiver, will get 'view'
  c3 uuid := gen_random_uuid();  -- caregiver, rejected then retries
  pid1 int; pid2 int; cg1 int; cg2 int; cg3 int;
  code text; code2 text; code3 text; code4 text;
  l1 int; l2 int; l3 int; presc int; med int; med2 int; comp int; n int; nm text;
begin
  ---------------------------------------------------------------- signup
  insert into auth.users (id, aud, role, email, raw_user_meta_data) values
    (p1, 'authenticated', 'authenticated', 'p1@test.com', '{"role":"patient","name":"Patient One"}'),
    (p2, 'authenticated', 'authenticated', 'p2@test.com', '{"role":"patient","name":"Patient Two"}'),
    (c1, 'authenticated', 'authenticated', 'c1@test.com', '{"role":"caregiver","name":"Caregiver One"}'),
    (c2, 'authenticated', 'authenticated', 'c2@test.com', '{"role":"caregiver","name":"Caregiver Two"}'),
    (c3, 'authenticated', 'authenticated', 'c3@test.com', '{"role":"caregiver","name":"Caregiver Three"}');
  select id, link_code into pid1, code from patients where auth_user_id = p1;
  select id into pid2 from patients where auth_user_id = p2;
  select id into cg1 from caregivers where auth_user_id = c1;
  select id into cg2 from caregivers where auth_user_id = c2;
  select id into cg3 from caregivers where auth_user_id = c3;
  assert pid1 is not null and pid2 is not null and cg1 is not null, 'signup trigger did not create role rows';
  assert (select email from patients where id = pid1) = 'p1@test.com', 'patient email not stored';
  assert (select timezone from patients where id = pid1) = 'Africa/Cairo', 'default timezone missing';
  assert length(code) = 8, 'link code should be 8 characters';

  assert public.t_fails($q$ insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'norole@test.com') $q$), 'signup without role should fail';
  assert public.t_fails($q$ insert into auth.users (id, aud, role, email, raw_user_meta_data) values (gen_random_uuid(), 'authenticated', 'authenticated', 'noname@test.com', '{"role":"patient","name":"   "}') $q$), 'signup without a name should fail';
  assert not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('patients', 'caregivers') and column_name = 'phone'), 'phone column should be gone';

  ---------------------------------------------------------------- anonymous
  perform set_config('role', 'anon', true);
  assert public.t_fails('select 1 from patients'), 'anon should not read patients';
  reset role;

  ---------------------------------------------------------------- linking + code rotation
  perform public.t_as(c1);
  assert (select count(*) from patients) = 0, 'caregiver sees patients before linking';
  assert public.t_fails($q$ select request_patient_link('ZZZZZZZZ') $q$), 'invalid code should fail';
  perform request_patient_link(code);
  assert (select count(*) from patients) = 0, 'caregiver sees patient while pending';
  assert public.t_fails(format('select request_patient_link(%L)', code)), 'duplicate pending request should fail';
  reset role;

  perform public.t_as(c2); perform request_patient_link(code); reset role;   -- same code, not rotated yet
  select id into l1 from caregiver_patients where caregiver_id = cg1;
  select id into l2 from caregiver_patients where caregiver_id = cg2;

  perform public.t_as(c1);
  assert public.t_fails(format('select respond_to_link(%s, true, ''manage'')', l1)), 'caregiver approved their own link';
  reset role;

  perform public.t_as(p1);
  assert (select count(*) from caregiver_patients where status = 'pending') = 2, 'patient should see 2 pending requests';
  assert public.t_fails($q$ update patients set link_code = 'HACKED' $q$), 'patient should not edit link_code';
  assert public.t_fails(format('select respond_to_link(%s, true, ''admin'')', l1)), 'invalid access level should fail';
  perform respond_to_link(l1, true, 'manage');
  select my_link_code() into code2;
  assert code2 <> code, 'code should rotate after accept';
  assert length(code2) = 8, 'patient can read their own 8-character link code';
  perform respond_to_link(l2, true, 'view');
  select my_link_code() into code3;
  assert code3 <> code2, 'code should rotate after second accept';
  reset role;

  perform public.t_as(c3);
  assert public.t_fails(format('select request_patient_link(%L)', code)), 'old code should no longer work';
  perform request_patient_link(code3);
  reset role;
  select id into l3 from caregiver_patients where caregiver_id = cg3;

  perform public.t_as(p1);
  perform respond_to_link(l3, false);
  select my_link_code() into code4;
  assert code4 <> code3, 'code should rotate after reject';
  assert (select status from caregiver_patients where id = l3) = 'rejected', 'link should be rejected';
  reset role;

  perform public.t_as(c3);
  assert public.t_fails(format('select request_patient_link(%L)', code3)), 'code used for a rejected request should be dead';
  perform request_patient_link(code4);        -- retry with the new code
  assert (select status from caregiver_patients where id = l3) = 'pending', 'retry after reject should be pending again';
  reset role;

  ---------------------------------------------------------------- visibility
  perform public.t_as(c1);
  select count(*), min(name) into n, nm from patients;
  assert n = 1 and nm = 'Patient One', 'accepted caregiver should see exactly patient 1';
  assert public.t_fails('select link_code from patients'), 'accepted caregiver must not read link_code';
  assert public.t_fails('select * from patients'), 'select * on patients should be refused (link_code is not readable)';
  assert my_link_code() is null, 'caregiver gets no link code from my_link_code()';
  assert (select count(*) from caregivers) = 1, 'caregiver should only see themselves';
  reset role;
  perform public.t_as(c3);
  assert (select count(*) from patients) = 0, 'pending caregiver sees patient';
  reset role;
  perform public.t_as(p2);
  assert (select count(*) from patients) = 1, 'other patient should only see themselves';
  assert (select count(*) from caregiver_patients) = 0, 'other patient sees links';
  reset role;
  perform public.t_as(p1);
  assert (select count(*) from caregivers) = 3, 'patient should see their 3 linked/pending caregivers';
  reset role;

  ---------------------------------------------------------------- writes: manage vs view
  perform public.t_as(c1);                       -- 'manage' caregiver
  insert into prescriptions (patient_id) values (pid1) returning id into presc;
  insert into prescription_medicines (prescription_id, patient_id, med_name, dosage, frequency, duration)
    values (presc, pid1, 'Aspirin', '100mg', 'twice daily', '7 days') returning id into med;
  insert into compartments (slot_number, pill_count, patient_id, prescription_medicine_id)
    values (1, 20, pid1, med) returning id into comp;
  insert into schedules (patient_id, compartment_id, start_date, end_date, med_time)
    values (pid1, comp, current_date, current_date + 7, '08:00');
  assert public.t_fails(format('insert into schedules (patient_id, compartment_id, start_date, end_date, med_time) values (%s, %s, current_date, current_date - 1, ''09:00'')', pid1, comp)), 'end before start should fail';
  reset role;

  select count(*) into n from schedules;
  perform public.t_as(c2);                       -- 'view' caregiver
  assert (select count(*) from prescriptions) = 1, 'view caregiver should read prescriptions';
  assert public.t_fails(format('insert into prescriptions (patient_id) values (%s)', pid1)), 'view caregiver should not insert';
  update compartments set pill_count = 0;        -- silently affects 0 rows
  delete from schedules;
  reset role;
  assert (select pill_count from compartments where id = comp) = 20, 'view caregiver changed a compartment';
  assert (select count(*) from schedules) = n, 'view caregiver deleted a schedule';

  perform public.t_as(c3);                       -- pending caregiver
  assert (select count(*) from prescriptions) = 0, 'pending caregiver reads prescriptions';
  reset role;

  perform public.t_as(p2);                       -- other patient, then try to attach to patient 1
  insert into prescriptions (patient_id) values (pid2) returning id into presc;
  insert into prescription_medicines (prescription_id, patient_id, med_name) values (presc, pid2, 'Other') returning id into med2;
  assert (select count(*) from prescriptions) = 1, 'other patient should see only their prescription';
  assert public.t_fails(format('insert into prescriptions (patient_id) values (%s)', pid1)), 'other patient wrote to patient 1';
  reset role;

  perform public.t_as(c1);                       -- cross-patient attach is blocked by the composite foreign key
  assert public.t_fails(format('insert into compartments (slot_number, pill_count, patient_id, prescription_medicine_id) values (2, 5, %s, %s)', pid1, med2)), 'attached another patient''s medicine';
  assert public.t_fails(format('update compartments set patient_id = %s', pid2)), 'patient_id should not be editable';
  reset role;

  perform public.t_as(p1);                       -- patient can add a second scan, and sees the change log
  insert into prescriptions (patient_id) values (pid1);
  assert (select count(*) from prescriptions) = 2, 'patient should be able to add a second prescription';
  assert exists (select 1 from change_log where actor_name = 'Caregiver One' and table_name = 'schedules'), 'change log missing caregiver change';
  assert exists (select 1 from change_log where actor_role = 'patient' and table_name = 'prescriptions'), 'change log missing patient change';
  assert public.t_fails('insert into change_log (patient_id, actor_name, actor_role, table_name, action) values (1, ''x'', ''x'', ''x'', ''insert'')'), 'users should not write the change log';
  reset role;
  perform public.t_as(p2);
  assert (select count(*) from change_log where patient_id = pid1) = 0, 'other patient sees patient 1 change log';
  assert (select count(*) from change_log where patient_id = pid2) > 0, 'patient should see their own change log';
  reset role;

  ---------------------------------------------------------------- boxes
  perform public.t_as(c2);
  assert public.t_fails(format('select pair_device(%s, ''PB-TEST0001'')', pid1)), 'view caregiver paired a box';
  reset role;
  perform public.t_as(p2);
  assert public.t_fails(format('select pair_device(%s, ''PB-TEST0001'')', pid1)), 'other patient paired a box for patient 1';
  reset role;
  perform public.t_as(c1);
  assert public.t_fails(format('select pair_device(%s, ''PB-NOPE'')', pid1)), 'unknown box should fail';
  perform pair_device(pid1, 'pb-test0001');      -- lower case is accepted
  assert (select count(*) from devices) = 1, 'manage caregiver should see the box';
  reset role;
  perform public.t_as(p2);
  assert public.t_fails(format('select pair_device(%s, ''PB-TEST0001'')', pid2)), 'paired box should not be claimable';
  assert (select count(*) from devices) = 0, 'other patient sees the box';
  reset role;
  perform public.t_as(c1); perform unpair_device(pid1); reset role;
  perform public.t_as(p1); perform pair_device(pid1, 'PB-TEST0001'); reset role;

  ---------------------------------------------------------------- remove / regenerate
  perform public.t_as(p1);
  select my_link_code() into code;
  assert regenerate_link_code() <> code, 'regenerate should change the code';
  perform remove_link(l2);                       -- patient removes the view caregiver
  reset role;
  perform public.t_as(c2);
  assert (select count(*) from patients) = 0 and (select count(*) from prescriptions) = 0, 'removed caregiver still has access';
  reset role;
  perform public.t_as(c3);
  perform remove_link(l3);                       -- caregiver cancels their own request
  assert public.t_fails(format('select remove_link(%s)', l1)), 'caregiver removed someone else''s link';
  reset role;

  ---------------------------------------------------------------- account deletion cascades
  delete from auth.users where id = p1;
  assert not exists (select 1 from patients where id = pid1), 'patient row remains';
  assert not exists (select 1 from prescriptions where patient_id = pid1), 'prescriptions remain';
  assert not exists (select 1 from change_log where patient_id = pid1), 'change log remains';
  assert (select patient_id from devices where device_code = 'PB-TEST0001') is null, 'box should be freed';
  assert exists (select 1 from caregivers where id = cg1), 'caregiver should survive patient deletion';

  raise exception 'ALL TESTS PASSED (test data rolled back)';
end $$;

rollback;
