-- 1. Patients: link to auth user + private link code
alter table public.patients
  add column auth_user_id uuid unique
    references auth.users(id) on delete cascade,
  add column link_code text unique
    default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

-- 2. Links: status (the pair is already unique in the baseline)
alter table public.caregiver_patients
  add column status text not null default 'pending'
    check (status in ('pending', 'accepted', 'rejected')),
  add column responded_at timestamptz;

create index caregiver_patients_patient_idx on public.caregiver_patients (patient_id);

-- 3. Deleting an auth user deletes the caregiver row
alter table public.caregivers
  drop constraint caregivers_auth_user_id_fkey,
  add constraint caregivers_auth_user_id_fkey
    foreign key (auth_user_id) references auth.users(id) on delete cascade;

-- 4. Create the role row on signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  r  text := new.raw_user_meta_data->>'role';
  n  text := coalesce(new.raw_user_meta_data->>'name', '');
  ph text := new.raw_user_meta_data->>'phone';
begin
  if r = 'patient' then
    insert into patients (auth_user_id, name, phone) values (new.id, n, ph);
  elsif r = 'caregiver' then
    insert into caregivers (auth_user_id, name, phone, email)
    values (new.id, n, ph, new.email);
  else
    raise exception 'invalid role';
  end if;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 5. Helpers (security definer = no RLS recursion)
create or replace function public.my_patient_id()
returns int language sql stable security definer set search_path = public as $$
  select id from patients where auth_user_id = auth.uid();
$$;

create or replace function public.my_caregiver_id()
returns int language sql stable security definer set search_path = public as $$
  select id from caregivers where auth_user_id = auth.uid();
$$;

create or replace function public.can_access_patient(pid int)
returns boolean language sql stable security definer set search_path = public as $$
  select pid = my_patient_id()
      or exists (select 1 from caregiver_patients cp
                 where cp.patient_id = pid
                   and cp.caregiver_id = my_caregiver_id()
                   and cp.status = 'accepted');
$$;

-- 6. Caregiver enters a code -> pending link
create or replace function public.request_patient_link(p_code text)
returns void language plpgsql security definer set search_path = public as $$
declare cg int := my_caregiver_id(); pt int;
begin
  if cg is null then raise exception 'not a caregiver'; end if;
  select id into pt from patients where link_code = upper(trim(p_code));
  if pt is null then raise exception 'invalid code'; end if;
  insert into caregiver_patients (caregiver_id, patient_id)
  values (cg, pt) on conflict do nothing;
end $$;

-- 7. Patient approves / rejects
create or replace function public.respond_to_link(p_link_id int, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  update caregiver_patients
     set status = case when p_accept then 'accepted' else 'rejected' end,
         responded_at = now()
   where id = p_link_id and status = 'pending'
     and patient_id = my_patient_id();
  if not found then raise exception 'link not found'; end if;
end $$;

-- 8. RLS policies (RLS is already enabled in the baseline)
create policy patients_select on public.patients
  for select using (can_access_patient(id));
create policy patients_update on public.patients
  for update using (auth_user_id = auth.uid()) with check (auth_user_id = auth.uid());

create policy caregivers_select_self on public.caregivers
  for select using (auth_user_id = auth.uid());
create policy caregivers_select_for_patient on public.caregivers
  for select using (exists (select 1 from caregiver_patients cp
                            where cp.caregiver_id = caregivers.id
                              and cp.patient_id = my_patient_id()));
create policy caregivers_update on public.caregivers
  for update using (auth_user_id = auth.uid()) with check (auth_user_id = auth.uid());

create policy links_select on public.caregiver_patients
  for select using (caregiver_id = my_caregiver_id() or patient_id = my_patient_id());
-- No insert/update/delete policies: all changes go through the two functions.

-- 9. Grants (the baseline revoked table access from anon/authenticated)
grant select on public.patients, public.caregivers, public.caregiver_patients to authenticated;
grant update (name, phone) on public.patients to authenticated;
grant update (name, phone) on public.caregivers to authenticated;

revoke execute on function
  public.handle_new_user(), public.my_patient_id(), public.my_caregiver_id(),
  public.can_access_patient(int), public.request_patient_link(text),
  public.respond_to_link(int, boolean)
from public, anon;

grant execute on function
  public.my_patient_id(), public.my_caregiver_id(),
  public.can_access_patient(int), public.request_patient_link(text),
  public.respond_to_link(int, boolean)
to authenticated;