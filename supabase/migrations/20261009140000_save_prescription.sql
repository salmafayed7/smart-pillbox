-- Migration 3 (the 4th file, after the baseline): save a confirmed (user-edited) scan result as a prescription.
--
-- The scan-prescription Edge Function saves nothing. After the user checks and edits the
-- list, the app calls save_prescription once. Schedules are NOT created here: they hang off
-- compartments, so they are created later, when medicines are assigned to box slots.
-- Because of that, what the scan returned (tablets per dose, morning/noon/evening/night
-- pattern, ...) is kept on prescription_medicines until the box is loaded.

-- =====================================================================
-- 1. Columns for the confirmed scan data
--    Doses are in half steps (0.5 tablet) because that is what the scan can return.
--    The box dispenses whole pills, so the compartment step must handle halves.
-- =====================================================================
alter table public.prescription_medicines
  add column tablets_per_dose numeric(3,1)
    constraint prescription_medicines_tablets_check
    check (tablets_per_dose > 0 and tablets_per_dose <= 10 and tablets_per_dose * 2 = trunc(tablets_per_dose * 2)),
  add column form text
    constraint prescription_medicines_form_check check (form in ('tablet', 'other')),
  add column notes text,
  add column duration_days integer
    constraint prescription_medicines_duration_days_check check (duration_days between 1 and 365),
  add column times_per_day integer
    constraint prescription_medicines_times_per_day_check check (times_per_day between 1 and 12),
  -- Tablets per dose in each part of the day. All four are set together, or all four are null
  -- (the prescription did not write a pattern).
  add column dose_morning numeric(3,1),
  add column dose_noon    numeric(3,1),
  add column dose_evening numeric(3,1),
  add column dose_night   numeric(3,1),
  add constraint prescription_medicines_dose_slots_check check (
    num_nonnulls(dose_morning, dose_noon, dose_evening, dose_night) = 0
    or (
      num_nonnulls(dose_morning, dose_noon, dose_evening, dose_night) = 4
      and dose_morning between 0 and 10 and dose_morning * 2 = trunc(dose_morning * 2)
      and dose_noon    between 0 and 10 and dose_noon    * 2 = trunc(dose_noon    * 2)
      and dose_evening between 0 and 10 and dose_evening * 2 = trunc(dose_evening * 2)
      and dose_night   between 0 and 10 and dose_night   * 2 = trunc(dose_night   * 2)
      and dose_morning + dose_noon + dose_evening + dose_night > 0
    )
  );

-- Insert is already granted on the whole table. Editing is column by column.
grant update (
  tablets_per_dose, form, notes, duration_days, times_per_day,
  dose_morning, dose_noon, dose_evening, dose_night
) on public.prescription_medicines to authenticated;

-- =====================================================================
-- 2. save_prescription
--    Takes the same medicine objects the scan returns (after the user's edits):
--    { name, dose, frequency, duration, schedule: {morning, noon, evening, night} | null,
--      tablets_per_dose, form, notes, times_per_day, duration_days }
--    Runs as the caller (SECURITY INVOKER), so the RLS policies still apply as a second
--    line of defence behind the explicit can_manage_patient check.
--    One call is one transaction: if anything is invalid, nothing is saved.
--    Returns { prescription_id, medicine_ids } with the ids in the same order as the list.
-- =====================================================================
create or replace function public.save_prescription(p_patient_id int, p_medicines jsonb)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_prescription_id int;
  v_ids int[];
begin
  if p_patient_id is null or not can_manage_patient(p_patient_id) then
    raise exception 'not allowed';
  end if;

  if jsonb_typeof(p_medicines) is distinct from 'array' then
    raise exception 'invalid medicine list';
  end if;
  if jsonb_array_length(p_medicines) not between 1 and 30 then
    raise exception 'invalid medicine list';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_medicines) e(value)
    where jsonb_typeof(e.value) is distinct from 'object'
  ) then
    raise exception 'invalid medicine list';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_medicines)
         as x(name text, dose text, frequency text, duration text, notes text, form text)
    where nullif(btrim(x.name), '') is null
       or length(btrim(x.name)) > 120
       or length(x.dose) > 60
       or length(x.frequency) > 120
       or length(x.duration) > 60
       or length(x.notes) > 300
       or x.form not in ('tablet', 'other')
  ) then
    raise exception 'invalid medicine';
  end if;

  insert into prescriptions (patient_id) values (p_patient_id)
  returning id into v_prescription_id;

  with ins as (
    insert into prescription_medicines (
      prescription_id, patient_id, med_name, dosage, frequency, duration,
      tablets_per_dose, form, notes, duration_days, times_per_day,
      dose_morning, dose_noon, dose_evening, dose_night)
    select
      v_prescription_id, p_patient_id,
      btrim(x.name),
      nullif(btrim(x.dose), ''),
      nullif(btrim(x.frequency), ''),
      nullif(btrim(x.duration), ''),
      x.tablets_per_dose, x.form,
      nullif(btrim(x.notes), ''),
      x.duration_days, x.times_per_day,
      case when jsonb_typeof(x.schedule) = 'object' then coalesce((x.schedule ->> 'morning')::numeric, 0) end,
      case when jsonb_typeof(x.schedule) = 'object' then coalesce((x.schedule ->> 'noon')::numeric, 0) end,
      case when jsonb_typeof(x.schedule) = 'object' then coalesce((x.schedule ->> 'evening')::numeric, 0) end,
      case when jsonb_typeof(x.schedule) = 'object' then coalesce((x.schedule ->> 'night')::numeric, 0) end
    from jsonb_array_elements(p_medicines) with ordinality as e(value, ord),
         lateral jsonb_to_record(e.value) as x(
           name text, dose text, frequency text, duration text, notes text, form text,
           tablets_per_dose numeric, duration_days int, times_per_day int, schedule jsonb)
    order by e.ord
    returning id
  )
  select array_agg(id order by id) into v_ids from ins;

  return jsonb_build_object('prescription_id', v_prescription_id, 'medicine_ids', to_jsonb(v_ids));
end $$;

comment on function public.save_prescription(int, jsonb) is
  'Saves a confirmed scan result as one prescription with its medicines (all or nothing). Patient, or caregiver with manage access.';

-- Signed-in users only
revoke execute on function public.save_prescription(int, jsonb) from public, anon;
grant execute on function public.save_prescription(int, jsonb) to authenticated;
