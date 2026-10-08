-- Migration 2: access levels, link code rotation, box pairing, patient email,
-- schema cleanup, RLS + grants for the remaining tables, change log.
-- Assumes the data tables are still empty (new NOT NULL columns have no backfill).
-- If a table has rows, this fails and nothing is applied.

-- =====================================================================
-- 1. Link code generator (security definer so the uniqueness check sees all patients)
-- =====================================================================
create or replace function public.generate_link_code()
returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  loop
    c := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from patients where link_code = c);
  end loop;
  return c;
end $$;

revoke execute on function public.generate_link_code() from public, anon, authenticated;
grant execute on function public.generate_link_code() to service_role;

-- =====================================================================
-- 2. Patients, caregivers, links
-- =====================================================================
alter table public.patients
  alter column link_code set default public.generate_link_code(),
  alter column link_code set not null,
  add column email text unique,
  add column timezone text not null default 'Africa/Cairo';

-- Phone numbers are not used anywhere in the app
alter table public.patients drop column phone;
alter table public.caregivers drop column phone;

alter table public.caregiver_patients
  add column access_level text not null default 'view'
    check (access_level in ('view', 'manage'));

-- =====================================================================
-- 3. Signup trigger: patients now store their email too
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  r text := new.raw_user_meta_data->>'role';
  n text := nullif(trim(coalesce(new.raw_user_meta_data->>'name', '')), '');
begin
  if r is null or r not in ('patient', 'caregiver') then raise exception 'invalid role'; end if;
  if n is null then raise exception 'name is required'; end if;
  if new.email is null then raise exception 'email is required'; end if;
  if r = 'patient' then
    insert into patients (auth_user_id, name, email) values (new.id, n, new.email);
  else
    insert into caregivers (auth_user_id, name, email) values (new.id, n, new.email);
  end if;
  return new;
end $$;

-- =====================================================================
-- 4. Prescription chain cleanup
--    Every child row carries patient_id, and composite foreign keys make it
--    impossible to attach a row to another patient's parent.
-- =====================================================================
alter table public.prescriptions
  alter column created_at type timestamptz using created_at at time zone 'UTC',
  drop constraint prescriptions_patient_id_fkey,
  add constraint prescriptions_patient_id_fkey
    foreign key (patient_id) references public.patients (id) on delete cascade,
  add constraint prescriptions_id_patient_key unique (id, patient_id);

alter table public.prescription_medicines
  add column patient_id integer not null,
  drop constraint prescription_medicines_prescription_id_fkey,
  add constraint prescription_medicines_prescription_fkey
    foreign key (prescription_id, patient_id) references public.prescriptions (id, patient_id) on delete cascade,
  add constraint prescription_medicines_id_patient_key unique (id, patient_id);

alter table public.compartments
  drop constraint unique_slot_number,          -- global unique: blocked slot 1 for a second patient
  drop constraint check_pill_count,            -- duplicates of the *_check constraints
  drop constraint check_slot_number,
  drop constraint compartments_prescription_medicine_id_fkey,
  alter column pill_count set not null,
  add column low_stock_threshold integer not null default 5 check (low_stock_threshold >= 0),
  add constraint compartments_medicine_fkey
    foreign key (prescription_medicine_id, patient_id) references public.prescription_medicines (id, patient_id) on delete cascade,
  add constraint compartments_id_patient_key unique (id, patient_id);

alter table public.schedules
  add column patient_id integer not null,
  drop column prescription_medicine_id,        -- the compartment already points to the medication
  drop constraint schedules_compartment_id_fkey,
  add constraint schedules_compartment_fkey
    foreign key (compartment_id, patient_id) references public.compartments (id, patient_id) on delete cascade,
  add constraint schedules_id_patient_key unique (id, patient_id);

alter table public.adherence_log
  drop column prescription_medicine_id,
  drop constraint adherence_log_schedule_id_fkey,
  add column patient_id integer not null,
  add column scheduled_for timestamptz not null,
  add column taken_at timestamptz,
  alter column schedule_id set not null,
  alter column status set not null,
  add constraint adherence_log_status_check
    check (status in ('taken', 'missed', 'snoozed', 'skipped')),
  add constraint adherence_log_schedule_fkey
    foreign key (schedule_id, patient_id) references public.schedules (id, patient_id) on delete cascade,
  add constraint adherence_log_dose_key unique (schedule_id, scheduled_for);  -- one row per dose

create index prescriptions_patient_idx          on public.prescriptions (patient_id);
create index prescription_medicines_patient_idx on public.prescription_medicines (patient_id);
create index prescription_medicines_presc_idx   on public.prescription_medicines (prescription_id);
create index schedules_patient_idx              on public.schedules (patient_id);
create index schedules_compartment_idx          on public.schedules (compartment_id);
create index adherence_log_patient_idx          on public.adherence_log (patient_id);

-- =====================================================================
-- 5. Boxes (one per patient for now)
--    To allow several boxes later: drop devices_patient_id_key.
-- =====================================================================
create table public.devices (
  id          integer generated always as identity primary key,
  device_code text not null unique,
  patient_id  integer constraint devices_patient_id_key unique
              references public.patients (id) on delete set null,
  paired_at   timestamptz
);
alter table public.devices enable row level security;

-- =====================================================================
-- 6. Push tokens (for Youssef's notifications)
-- =====================================================================
create table public.push_tokens (
  id         integer generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  fcm_token  text not null,
  platform   text not null check (platform in ('android', 'ios')),
  created_at timestamptz not null default now(),
  unique (user_id, fcm_token)
);
alter table public.push_tokens enable row level security;

-- =====================================================================
-- 7. Change log (who changed what, shown to the patient)
--    Stores identifiers only, never prescription contents.
-- =====================================================================
create table public.change_log (
  id          bigint generated always as identity primary key,
  patient_id  integer not null references public.patients (id) on delete cascade,
  actor_id    uuid,
  actor_name  text not null,
  actor_role  text not null,
  table_name  text not null,
  action      text not null check (action in ('insert', 'update', 'delete')),
  row_id      integer,
  created_at  timestamptz not null default now()
);
create index change_log_patient_idx on public.change_log (patient_id, created_at desc);
alter table public.change_log enable row level security;

create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare pid int; rid int; who text; role_ text;
begin
  -- Only changes made by a logged-in user are recorded (the box and scheduled jobs are not)
  if auth.uid() is null then return null; end if;

  if tg_op = 'DELETE' then
    pid := old.patient_id; rid := old.id;
  elsif tg_op = 'UPDATE' then
    pid := coalesce(new.patient_id, old.patient_id); rid := new.id;
  else
    pid := new.patient_id; rid := new.id;
  end if;
  if pid is null then return null; end if;
  -- During account deletion the patient row is already gone: nothing to log
  if not exists (select 1 from patients where id = pid) then return null; end if;

  select 'patient', name into role_, who from patients where auth_user_id = auth.uid();
  if not found then
    select 'caregiver', name into role_, who from caregivers where auth_user_id = auth.uid();
  end if;
  if not found then return null; end if;

  insert into change_log (patient_id, actor_id, actor_name, actor_role, table_name, action, row_id)
  values (pid, auth.uid(), who, role_, tg_table_name, lower(tg_op), rid);
  return null;
end $$;

revoke execute on function public.log_change() from public, anon, authenticated;

create trigger log_prescriptions         after insert or update or delete on public.prescriptions
  for each row execute function public.log_change();
create trigger log_prescription_medicines after insert or update or delete on public.prescription_medicines
  for each row execute function public.log_change();
create trigger log_compartments          after insert or update or delete on public.compartments
  for each row execute function public.log_change();
create trigger log_schedules             after insert or update or delete on public.schedules
  for each row execute function public.log_change();
create trigger log_devices               after update on public.devices
  for each row execute function public.log_change();

-- =====================================================================
-- 8. Access helpers: always return true or false, never NULL
--    (NULL is treated as "no" by RLS, but `if not NULL` in a function does not raise,
--    so a NULL here would let a caller through)
-- =====================================================================
create or replace function public.can_access_patient(pid int)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(pid = my_patient_id(), false)
      or exists (select 1 from caregiver_patients cp
                 where cp.patient_id = pid
                   and cp.caregiver_id = my_caregiver_id()
                   and cp.status = 'accepted');
$$;

-- Patient, or caregiver with an accepted 'manage' link
create or replace function public.can_manage_patient(pid int)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(pid = my_patient_id(), false)
      or exists (select 1 from caregiver_patients cp
                 where cp.patient_id = pid
                   and cp.caregiver_id = my_caregiver_id()
                   and cp.status = 'accepted'
                   and cp.access_level = 'manage');
$$;

-- =====================================================================
-- 9. Link functions
-- =====================================================================
-- Caregiver enters the patient's code
create or replace function public.request_patient_link(p_code text)
returns void language plpgsql security definer set search_path = public as $$
declare cg int := my_caregiver_id(); pt int; cur text;
begin
  if cg is null then raise exception 'not a caregiver'; end if;
  select id into pt from patients where link_code = upper(trim(p_code));
  if pt is null then raise exception 'invalid code'; end if;
  select status into cur from caregiver_patients where caregiver_id = cg and patient_id = pt;
  if cur = 'accepted' then raise exception 'already linked'; end if;
  if cur = 'pending'  then raise exception 'request already pending'; end if;
  if cur = 'rejected' then
    update caregiver_patients
       set status = 'pending', responded_at = null, created_at = now()
     where caregiver_id = cg and patient_id = pt;
  else
    insert into caregiver_patients (caregiver_id, patient_id) values (cg, pt);
  end if;
end $$;

-- Patient answers a request. The code changes after every answer.
drop function public.respond_to_link(int, boolean);

create or replace function public.respond_to_link(
  p_link_id int, p_accept boolean, p_access_level text default 'view')
returns void language plpgsql security definer set search_path = public as $$
declare pt int := my_patient_id();
begin
  if p_access_level not in ('view', 'manage') then raise exception 'invalid access level'; end if;
  update caregiver_patients
     set status       = case when p_accept then 'accepted' else 'rejected' end,
         access_level = case when p_accept then p_access_level else 'view' end,
         responded_at = now()
   where id = p_link_id and status = 'pending' and patient_id = pt;
  if not found then raise exception 'link not found'; end if;
  update patients set link_code = generate_link_code() where id = pt;
end $$;

-- Patient removes a caregiver, or a caregiver cancels a request / leaves a patient
create or replace function public.remove_link(p_link_id int)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from caregiver_patients
   where id = p_link_id
     and (patient_id = my_patient_id() or caregiver_id = my_caregiver_id());
  if not found then raise exception 'link not found'; end if;
end $$;

-- Patient gets a fresh code on demand
create or replace function public.regenerate_link_code()
returns text language plpgsql security definer set search_path = public as $$
declare pt int := my_patient_id(); c text;
begin
  if pt is null then raise exception 'not a patient'; end if;
  c := generate_link_code();
  update patients set link_code = c where id = pt;
  return c;
end $$;

-- =====================================================================
-- 10. Box pairing (patient, or caregiver with 'manage')
-- =====================================================================
create or replace function public.pair_device(p_patient_id int, p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not can_manage_patient(p_patient_id) then raise exception 'not allowed'; end if;
  update devices set patient_id = p_patient_id, paired_at = now()
   where device_code = upper(trim(p_code)) and patient_id is null;
  if not found then raise exception 'box not found or already paired'; end if;
exception when unique_violation then
  raise exception 'this patient already has a box';
end $$;

create or replace function public.unpair_device(p_patient_id int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not can_manage_patient(p_patient_id) then raise exception 'not allowed'; end if;
  update devices set patient_id = null, paired_at = null where patient_id = p_patient_id;
  if not found then raise exception 'no box paired'; end if;
end $$;

-- =====================================================================
-- 11. RLS policies
--     Read: patient + any accepted caregiver. Write: patient + 'manage' caregivers.
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['prescriptions', 'prescription_medicines', 'compartments', 'schedules'] loop
    execute format('create policy %I on public.%I for select using (can_access_patient(patient_id))', t || '_select', t);
    execute format('create policy %I on public.%I for insert with check (can_manage_patient(patient_id))', t || '_insert', t);
    execute format('create policy %I on public.%I for update using (can_manage_patient(patient_id)) with check (can_manage_patient(patient_id))', t || '_update', t);
    execute format('create policy %I on public.%I for delete using (can_manage_patient(patient_id))', t || '_delete', t);
  end loop;
end $$;

create policy adherence_log_select on public.adherence_log
  for select using (can_access_patient(patient_id));
create policy adherence_log_insert on public.adherence_log
  for insert with check (can_manage_patient(patient_id));
create policy adherence_log_update on public.adherence_log
  for update using (can_manage_patient(patient_id)) with check (can_manage_patient(patient_id));

create policy devices_select on public.devices
  for select using (patient_id is not null and can_access_patient(patient_id));

create policy change_log_select on public.change_log
  for select using (can_access_patient(patient_id));

create policy push_tokens_own on public.push_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- =====================================================================
-- 12. Grants
--     Column-level UPDATE keeps ownership columns (patient_id, ids) immutable from the app.
-- =====================================================================
grant update (timezone) on public.patients to authenticated;

grant select, insert, delete on public.prescriptions to authenticated;
grant update (image_path) on public.prescriptions to authenticated;

grant select, insert, delete on public.prescription_medicines to authenticated;
grant update (med_name, dosage, frequency, duration) on public.prescription_medicines to authenticated;

grant select, insert, delete on public.compartments to authenticated;
grant update (slot_number, pill_count, low_stock_threshold) on public.compartments to authenticated;

grant select, insert, delete on public.schedules to authenticated;
grant update (start_date, end_date, med_time) on public.schedules to authenticated;

grant select, insert on public.adherence_log to authenticated;
grant update (status, taken_at) on public.adherence_log to authenticated;

grant select on public.devices, public.change_log to authenticated;

grant select, insert, delete on public.push_tokens to authenticated;
grant update (fcm_token, platform) on public.push_tokens to authenticated;

-- Edge Functions (service_role) need table access, because the baseline revoked the defaults
grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;

-- Functions: signed-in users only
revoke execute on function
  public.can_manage_patient(int),
  public.respond_to_link(int, boolean, text),
  public.remove_link(int),
  public.regenerate_link_code(),
  public.pair_device(int, text),
  public.unpair_device(int)
from public, anon;

grant execute on function
  public.can_manage_patient(int),
  public.respond_to_link(int, boolean, text),
  public.remove_link(int),
  public.regenerate_link_code(),
  public.pair_device(int, text),
  public.unpair_device(int)
to authenticated;
