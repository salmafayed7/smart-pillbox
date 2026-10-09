-- Migration 6: only the patient can read their own link_code.
--
-- Before, any accepted caregiver (including View only) could read it through patients_select,
-- because that policy lets caregivers read the whole patients row. Row-level security cannot
-- hide one column, so the table grant now leaves link_code out and the patient reads it
-- through my_link_code(). Caregivers get NULL from that function.
--
-- App impact: `select *` on patients now fails for signed-in users. List the columns:
--   id, name, fingerprint_id, auth_user_id, email, timezone

revoke select on public.patients from authenticated;
grant select (id, name, fingerprint_id, auth_user_id, email, timezone) on public.patients to authenticated;

create or replace function public.my_link_code()
returns text language sql stable security definer set search_path = public as $$
  select link_code from patients where auth_user_id = auth.uid();
$$;

revoke execute on function public.my_link_code() from public, anon;
grant execute on function public.my_link_code() to authenticated;
