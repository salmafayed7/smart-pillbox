do $$
declare
  p1 uuid := gen_random_uuid();  -- patient 1
  p2 uuid := gen_random_uuid();  -- patient 2 (outsider)
  c1 uuid := gen_random_uuid();  -- caregiver 1 (will be linked to p1)
  c2 uuid := gen_random_uuid();  -- caregiver 2 (never linked)
  code text; link_id int; n int; nm text; failed boolean;
begin
  -- Signup trigger creates the right role rows
  insert into auth.users (id, aud, role, email, raw_user_meta_data) values
    (p1, 'authenticated', 'authenticated', 'p1@test.com', '{"role":"patient","name":"Patient One"}'),
    (p2, 'authenticated', 'authenticated', 'p2@test.com', '{"role":"patient","name":"Patient Two"}'),
    (c1, 'authenticated', 'authenticated', 'c1@test.com', '{"role":"caregiver","name":"Caregiver One"}'),
    (c2, 'authenticated', 'authenticated', 'c2@test.com', '{"role":"caregiver","name":"Caregiver Two"}');
  assert (select count(*) from patients where auth_user_id in (p1, p2)) = 2, 'trigger: patient rows missing';
  assert (select count(*) from caregivers where auth_user_id in (c1, c2)) = 2, 'trigger: caregiver rows missing';
  select link_code into code from patients where auth_user_id = p1;

  -- Signup without a role must fail
  failed := false;
  begin
    insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'norole@test.com');
  exception when others then failed := true; end;
  assert failed, 'signup without role should fail';

  -- Anonymous users get nothing
  set local role anon;
  failed := false;
  begin perform 1 from patients; exception when insufficient_privilege then failed := true; end;
  reset role;
  assert failed, 'anon should not read patients';

  -- Caregiver 1: sees nothing, requests link, still sees nothing
  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from patients;
  assert n = 0, 'caregiver sees patients before linking';
  failed := false;
  begin perform request_patient_link('ZZZZZZZZ'); exception when others then failed := true; end;
  assert failed, 'invalid code should fail';
  perform request_patient_link(code);
  select count(*) into n from patients;
  assert n = 0, 'caregiver sees patient while link is still pending';
  select count(*) into n from caregiver_patients where status = 'pending';
  assert n = 1, 'caregiver should see own pending link';
  reset role;

  -- Caregiver 2 and Patient 2 can't see the link
  perform set_config('request.jwt.claims', json_build_object('sub', c2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from caregiver_patients;
  assert n = 0, 'outsider caregiver sees links';
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', p2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from caregiver_patients;
  assert n = 0, 'other patient sees links';
  select count(*) into n from patients;
  assert n = 1, 'patient should only see themselves';
  reset role;

  -- Patient 1: sees pending link, caregiver can't approve themselves, patient can
  perform set_config('request.jwt.claims', json_build_object('sub', p1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into link_id from caregiver_patients where status = 'pending';
  assert link_id is not null, 'patient should see pending link';
  failed := false;
  begin update patients set link_code = 'HACKED' where auth_user_id = p1;
  exception when insufficient_privilege then failed := true; end;
  assert failed, 'patient should not edit link_code';
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  failed := false;
  begin perform respond_to_link(link_id, true); exception when others then failed := true; end;
  assert failed, 'caregiver approved their own link';
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', p1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform respond_to_link(link_id, true);
  reset role;

  -- After approval: caregiver 1 sees exactly patient 1; others still see nothing
  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*), min(name) into n, nm from patients;
  assert n = 1 and nm = 'Patient One', 'accepted caregiver should see exactly patient 1';
  select count(*) into n from caregivers;
  assert n = 1, 'caregiver should only see themselves';
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', c2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from patients;
  assert n = 0, 'unlinked caregiver sees patients';
  reset role;

  -- Patient 1 sees caregiver 1 but not caregiver 2
  perform set_config('request.jwt.claims', json_build_object('sub', p1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*), min(name) into n, nm from caregivers;
  assert n = 1 and nm = 'Caregiver One', 'patient should see only their linked caregiver';
  reset role;

  -- Roll everything back so no test data is left behind
  raise exception 'ALL TESTS PASSED (test data rolled back)';
end $$;