# SmartPillbox: database and flow

How the data is organised, who may touch it, and how a prescription travels from a photo to the box. The backend is **Supabase** (PostgreSQL, login, and one Edge Function). The project was first planned on Firebase; the backend is now Supabase. Firebase is used only to deliver push notifications.

For how to run and change the backend, see `backend-setup.md`. For how to call it from the app, see `frontend-notes.md`.

## 1. The idea

A smart pillbox dispenses pills. A **patient** owns the box and the prescription. **Caregivers** (family, a nurse) can follow a patient, and the patient decides how much each caregiver may do. A prescription is scanned from a photo, checked by a person, and only then saved.

- Two roles, chosen once at signup: patient or caregiver. Email and password only; no phone numbers.
- Many-to-many: a patient can have several caregivers and a caregiver can follow several patients.
- One box per patient.

## 2. Tables

All tables are in the `public` schema. Row-level security is on for every one of them.

**People and links**

| Table | What it holds |
|---|---|
| `patients` | `id`, `name`, `email`, `auth_user_id` (the login), `link_code` (8 characters, private), `timezone` (default `Africa/Cairo`), `fingerprint_id` (from the original schema, unused) |
| `caregivers` | `id`, `name`, `email`, `auth_user_id` |
| `caregiver_patients` | one row per link: `caregiver_id`, `patient_id`, `status` (`pending`, `accepted`, `rejected`), `access_level` (`view`, `manage`), `created_at`, `responded_at`. Each pair appears once. |

**The prescription chain**

```
patients ─┬─ prescriptions ── prescription_medicines ── compartments ── schedules ── adherence_log
          └─ devices (the box)
```

| Table | What it holds |
|---|---|
| `prescriptions` | one saved prescription: `patient_id`, `created_at`, `image_path` (unused; the photo is never stored) |
| `prescription_medicines` | one medicine: `med_name`, `dosage`, `frequency`, `duration`, plus the scan data (`tablets_per_dose`, `form` = tablet or other, `notes`, `duration_days`, `times_per_day`, and `dose_morning`, `dose_noon`, `dose_evening`, `dose_night`) |
| `compartments` | a box slot (1 to 12): `slot_number`, `pill_count`, `low_stock_threshold`, and the medicine in it. A medicine sits in at most one slot, and a slot number is used once per patient. |
| `schedules` | a dose time for a slot: `med_time`, `start_date`, `end_date` (not before the start) |
| `adherence_log` | what happened to each dose: `status` (`taken`, `missed`, `snoozed`, `skipped`), `scheduled_for`, `taken_at`. One row per dose. |

**Other**

| Table | What it holds |
|---|---|
| `devices` | boxes: `device_code` (unique, stored in upper case, like `PB-7K2M9Q4X`), `patient_id` (unique: one box per patient), `paired_at` |
| `push_tokens` | the phone's notification token per user (`fcm_token`, `platform` = android or ios) |
| `change_log` | who changed what: `actor_name`, `actor_role`, `table_name`, `action`, `row_id`. **Identifiers only, never prescription content.** Only real logged-in users are recorded (not the box or scheduled jobs). |

**Why every child table has `patient_id`.** Each child row stores its patient and uses a *composite* foreign key (for example `schedules (compartment_id, patient_id)` must match `compartments (id, patient_id)`). A row can therefore never be attached to another patient's parent, even by mistake or by a crafted request.

## 3. Who can do what

Three rules, applied by the database itself (not by the app):

- **Read:** the patient, and any caregiver whose link is `accepted`.
- **Write:** the patient, and caregivers whose accepted link is `manage`.
- **Never:** `anon` (not logged in), pending or rejected caregivers, unlinked caregivers.

| | Patient | Caregiver, Can manage | Caregiver, View only |
|---|---|---|---|
| Read prescriptions, medicines, slots, schedules, adherence, box, log | yes | yes | yes |
| Add, edit, delete prescriptions, medicines, slots, schedules | yes | yes | no |
| Scan a photo and save the result | yes | yes | no |
| Pair or unpair the box | yes | yes | no |
| Approve, reject or remove caregivers; read the link code | yes | no | no |

Extra protections:

- **Column-level edit rights.** The app can only edit the working columns (for example `med_name`, `pill_count`, `med_time`). The id and owner columns (`id`, `patient_id`, `prescription_id`) can never be changed.
- **No table-wide extras.** `anon` has no table privileges at all. Signed-in users have only select, insert, update (on the columns above) and delete where it makes sense. Truncate, references and trigger were removed (migration 5).
- **The link code is private to the patient** (migration 6). Caregivers cannot read the `link_code` column; the patient reads it with `my_link_code()`.
- **Helper checks** `can_access_patient(id)` and `can_manage_patient(id)` always answer true or false, never "unknown", so a missing answer can never let someone through.
- **Server functions** (`SECURITY DEFINER`) fix their search path, and are revoked from `anon` and the public role.

## 4. Flows

**Signup.** The app signs the user up with `role` and `name`. A database trigger (`handle_new_user`) creates the patient or caregiver record. Any other role, or a missing name, rejects the signup.

**Linking.** Patient shows the code, tells the caregiver, the caregiver enters it (`request_patient_link`), the link is `pending`, the patient answers (`respond_to_link`: accept as `view` or `manage`, or reject). **The code changes after every answer** and can be renewed any time (`regenerate_link_code`). `remove_link` ends a link. Calls and errors are in `frontend-notes.md`.

**Pairing the box.** `pair_device(patient, code)` matches the code (case-insensitive) to an unpaired box. One box per patient. `unpair_device` frees it.

**Scan, check, save.**

1. The app sends 1 to 3 photos to the `scan-prescription` Edge Function with the user's login.
2. The function checks the login, then that the user may manage that patient (`can_manage_patient`, using the user's own token), then validates the images (JPEG or PNG, up to 2 MB each).
3. One request per page goes to a **vision-language model** (Qwen2.5-VL 72B) through OpenRouter, asking only for providers that do not store or train on prompts. A page that gives bad output, or a temporary error, is retried once.
4. The function merges the pages, works out `times_per_day` and `duration_days`, and returns the list. **It saves nothing and logs nothing from the photo or the model's answer.**
5. The app shows an editable list. When the user confirms, the app calls `save_prescription`.
6. `save_prescription` checks permission first, validates everything, and writes one prescription with its medicines in a single step: all or nothing.
7. Putting medicines into box slots and creating dose times is the next step (not built). Until then the scan's morning, noon, evening and night pattern stays on `prescription_medicines`.

## 5. Server functions

| Function | Who | What |
|---|---|---|
| `request_patient_link(p_code)` | caregiver | ask to follow a patient |
| `respond_to_link(p_link_id, p_accept, p_access_level)` | patient | accept or reject; rotates the code |
| `remove_link(p_link_id)` | patient or caregiver | end or cancel a link |
| `regenerate_link_code()` | patient | new code on demand |
| `my_link_code()` | any signed-in user | the patient's code; `null` for caregivers |
| `pair_device(p_patient_id, p_code)` | patient or manager | pair a box |
| `unpair_device(p_patient_id)` | patient or manager | free the box |
| `save_prescription(p_patient_id, p_medicines)` | patient or manager | save a confirmed scan (runs as the caller, so the table rules apply too) |
| `can_access_patient`, `can_manage_patient`, `my_patient_id`, `my_caregiver_id` | signed-in users | helpers for the rules above |
| `handle_new_user`, `log_change`, `generate_link_code` | internal | triggers and code generation; nobody can call them directly |

## 6. How the database was built (migrations)

Files in `supabase/migrations/`, applied in order. Never edit one that has been pushed; add a new one.

| # | File | What it did |
|---|---|---|
| 1 | `20261008121012_remote_schema.sql` | baseline pulled from the original database: the tables above in their first form, with access closed by default |
| 2 | `20261008121626_auth_roles_and_linking.sql` | login-to-record link, the signup trigger, the link code, link status, first access rules |
| 3 | `20261008130000_core_schema_and_permissions.sql` | access levels, code rotation, box pairing, composite foreign keys, `devices`, `push_tokens`, `change_log`, the rules and grants for every table, phone columns removed (its header comment says "Migration 2"; it is the third file) |
| 4 | `20261009140000_save_prescription.sql` | scan columns on `prescription_medicines` and `save_prescription` |
| 5 | `20261009150000_revoke_extra_privileges.sql` | removed truncate, references and trigger rights from `anon` and signed-in users |
| 6 | `20261009160000_link_code_private.sql` | `link_code` readable only by the patient, through `my_link_code()` |

## 7. Not built yet

- Putting medicines into box slots (compartments) and creating dose times (schedules)
- Refills and low-stock handling
- Adherence queries and reports
- Dosing logic and the connection to the box (MQTT)
- Alerts to caregivers
- Half tablets: the scan can return 0.5 of a tablet but the box dispenses whole pills. To be decided when slots are assigned.
