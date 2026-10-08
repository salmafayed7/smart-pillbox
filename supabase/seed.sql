-- supabase/seed.sql
-- Runs automatically at the end of `supabase db reset`. LOCAL DEVELOPMENT ONLY:
-- `supabase db push` never sends this file to the hosted project.
--
-- Test logins (password for all of them: Test12345!)
--   patient@test.com       patient, link code SEED0001
--   caregiver@test.com     caregiver, linked to the patient, "Can manage"
--   viewer@test.com        caregiver, linked to the patient, "View only"
--   newcaregiver@test.com  caregiver, NOT linked (use code SEED0001 to try the link flow)
-- Box code to try pairing: PB-DEMO0001

-- ---------------------------------------------------------------- logins
-- Rows are inserted straight into auth.users, with the same role/name metadata the app
-- sends at signup, so the handle_new_user trigger creates the patients/caregivers rows.
-- The token columns are '' and not NULL: a NULL there can break login in some Auth versions.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  email_change_token_current, phone_change, phone_change_token, reauthentication_token
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'authenticated', 'authenticated',
   'patient@test.com', extensions.crypt('Test12345!', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{"role":"patient","name":"Test Patient"}', now(), now(),
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'authenticated', 'authenticated',
   'caregiver@test.com', extensions.crypt('Test12345!', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{"role":"caregiver","name":"Test Caregiver"}', now(), now(),
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a3', 'authenticated', 'authenticated',
   'viewer@test.com', extensions.crypt('Test12345!', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{"role":"caregiver","name":"Test Viewer"}', now(), now(),
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a4', 'authenticated', 'authenticated',
   'newcaregiver@test.com', extensions.crypt('Test12345!', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{"role":"caregiver","name":"New Caregiver"}', now(), now(),
   '', '', '', '', '', '', '', '');

-- Password login needs a matching identity row for each user.
insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text,
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true, 'phone_verified', false),
       'email', now(), now(), now()
from auth.users u
where u.email in ('patient@test.com', 'caregiver@test.com', 'viewer@test.com', 'newcaregiver@test.com');

-- A fixed link code so the "Link a patient" screen can be tried the same way every time.
update public.patients set link_code = 'SEED0001' where email = 'patient@test.com';

-- ---------------------------------------------------------------- links
insert into public.caregiver_patients (caregiver_id, patient_id, status, access_level, responded_at)
select c.id, p.id, 'accepted', 'manage', now()
from public.caregivers c, public.patients p
where c.email = 'caregiver@test.com' and p.email = 'patient@test.com';

insert into public.caregiver_patients (caregiver_id, patient_id, status, access_level, responded_at)
select c.id, p.id, 'accepted', 'view', now()
from public.caregivers c, public.patients p
where c.email = 'viewer@test.com' and p.email = 'patient@test.com';

-- ---------------------------------------------------------------- one prescription, three medicines
insert into public.prescriptions (patient_id)
select id from public.patients where email = 'patient@test.com';

insert into public.prescription_medicines (prescription_id, patient_id, med_name, dosage, frequency, duration)
select pr.id, pr.patient_id, v.med_name, v.dosage, v.frequency, v.duration
from public.prescriptions pr,
     (values
       ('Paracetamol', '500mg',    'twice daily',       '5 days'),
       ('Amoxicillin', '500mg',    'three times daily', '7 days'),
       ('Vitamin D',   '1000 IU',  'once daily',        '30 days')
     ) as v(med_name, dosage, frequency, duration);

-- ---------------------------------------------------------------- box slots (Amoxicillin is low on stock)
insert into public.compartments (patient_id, prescription_medicine_id, slot_number, pill_count)
select pm.patient_id, pm.id,
       case pm.med_name when 'Paracetamol' then 1 when 'Amoxicillin' then 2 else 3 end,
       case pm.med_name when 'Paracetamol' then 20 when 'Amoxicillin' then 4 else 30 end
from public.prescription_medicines pm;

-- ---------------------------------------------------------------- dose times
insert into public.schedules (patient_id, compartment_id, start_date, end_date, med_time)
select c.patient_id, c.id, current_date - 2, current_date + (v.days - 3), v.t
from public.compartments c
join public.prescription_medicines pm on pm.id = c.prescription_medicine_id
join (values
       ('Paracetamol', 5,  '08:00'::time),
       ('Paracetamol', 5,  '20:00'::time),
       ('Amoxicillin', 7,  '08:00'::time),
       ('Amoxicillin', 7,  '14:00'::time),
       ('Amoxicillin', 7,  '22:00'::time),
       ('Vitamin D',   30, '09:00'::time)
     ) as v(med_name, days, t) on v.med_name = pm.med_name;

-- ---------------------------------------------------------------- two days of history (for the dashboard)
-- The day before yesterday: everything taken. Yesterday: all taken except the 22:00 dose.
insert into public.adherence_log (patient_id, schedule_id, scheduled_for, status, taken_at)
select s.patient_id, s.id,
       ((current_date - d.back) + s.med_time) at time zone 'Africa/Cairo',
       case when d.back = 1 and s.med_time = '22:00' then 'missed' else 'taken' end,
       case when d.back = 1 and s.med_time = '22:00' then null
            else (((current_date - d.back) + s.med_time) at time zone 'Africa/Cairo') + interval '5 minutes' end
from public.schedules s, (values (1), (2)) as d(back);

-- ---------------------------------------------------------------- an unpaired box
insert into public.devices (device_code) values ('PB-DEMO0001');
