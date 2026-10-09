# SmartPillbox: notes for the app developer

For whoever builds the Flutter app. The backend is **Supabase** (database, login and one Edge Function). You do not need to read SQL. Everything below is an HTTP call with JSON; the Supabase Flutter library makes the same calls and adds the headers for you.

If a call is not described here, it does not exist yet. Ask Salma before assuming.

## 1. Connecting

| | Local (testing) | Hosted |
|---|---|---|
| Base URL | `http://127.0.0.1:54321` | `https://gljpxdrqnkmhgqsegvkz.supabase.co` |
| Anon key | printed by `supabase status -o env` as `ANON_KEY` | Dashboard, Project Settings, API |

Every request sends:

```
apikey: <anon key>
Authorization: Bearer <access token>     (after login; before login send the anon key here too)
Content-Type: application/json
```

The anon key is meant to be inside the app. It is safe because every table is locked down by access rules (section 7). **Never** put any other key in the app. The OpenRouter key and the service_role key must never leave the server.

Four kinds of call:

| Kind | URL | Used for |
|---|---|---|
| Table read or write | `{base}/rest/v1/<table>?select=col1,col2` | reading data |
| Function call | `POST {base}/rest/v1/rpc/<function>` with the arguments as a JSON object | linking, pairing, saving |
| Login | `{base}/auth/v1/...` | signup and login |
| Scan | `POST {base}/functions/v1/scan-prescription` | reading a prescription photo |

## 2. Signup and login

Email and password only. There are no phone numbers anywhere. The role (patient or caregiver) is chosen **once, at signup**, and cannot change.

**Signup:** `POST /auth/v1/signup`

```json
{ "email": "a@example.com", "password": "secret123", "data": { "role": "patient", "name": "Ahmed" } }
```

- `role` must be `"patient"` or `"caregiver"`. `name` is required and cannot be blank. Anything else is rejected.
- Email confirmation is currently **off**, so the response already contains `access_token` and `refresh_token`.
- This creates the patient (or caregiver) record automatically. There is nothing else to create.

**Login:** `POST /auth/v1/token?grant_type=password` with `{ "email": "...", "password": "..." }`. The response has `access_token` (valid 1 hour) and `refresh_token`. The Supabase library refreshes it for you.

**Who am I (patient or caregiver)?** Ask for your own row in both tables. The one that returns a row is your role:

```
GET /rest/v1/patients?select=id,name,email,timezone
GET /rest/v1/caregivers?select=id,name,email
```

A patient also sees linked caregivers in the second call, and a caregiver also sees linked patients in the first. Use the `role` you chose at signup (kept in the user's metadata) to decide which screen to show.

> **Always list the columns.** `select=*` on `patients` fails, because `link_code` is hidden from the table (section 3). Use `select=id,name,email,timezone`.

## 3. Linking a caregiver to a patient

A caregiver sees a patient's data only after the patient approves. One caregiver can follow many patients and one patient can have many caregivers.

1. **The patient shows their link code.** It is 8 characters, for example `SEED0001`.
   `POST /rest/v1/rpc/my_link_code` with `{}`. The answer is the code as a JSON string. Caregivers get `null`.
2. **The patient tells the caregiver the code** (in person or by message; the app does not send it).
3. **The caregiver enters it.**
   `POST /rest/v1/rpc/request_patient_link` with `{ "p_code": "SEED0001" }`. Upper or lower case both work.
   Possible errors (in the response `message`): `invalid code`, `already linked`, `request already pending`, `not a caregiver`.
4. **The patient sees pending requests.**
   `GET /rest/v1/caregiver_patients?select=id,caregiver_id,status,created_at&status=eq.pending&order=id`
   To show names: `GET /rest/v1/caregivers?select=id,name,email` (a patient can read every caregiver who has requested a link to them).
5. **The patient answers.**
   `POST /rest/v1/rpc/respond_to_link` with `{ "p_link_id": 7, "p_accept": true, "p_access_level": "manage" }`
   - `p_access_level` is `"view"` (read only) or `"manage"` (can also scan, save and edit medications, and load and pair the box). Default is `"view"`. Any other value is refused, even when rejecting; a rejected link always ends up as `view`.
   - `link not found` means the request is not pending or is not theirs.
6. **The code changes after every answer**, accept or reject. A rejected caregiver can try again only with the new code, so the patient must share it again. The patient can also get a new code any time: `POST /rest/v1/rpc/regenerate_link_code` with `{}` (returns the new code).
7. **Ending a link.** `POST /rest/v1/rpc/remove_link` with `{ "p_link_id": 7 }`. A patient removes a caregiver; a caregiver cancels a request or leaves a patient.

**Caregiver screens:** `GET /rest/v1/patients?select=id,name,email,timezone` returns only patients with an **accepted** link. `GET /rest/v1/caregiver_patients?select=id,patient_id,status,access_level` shows the caregiver's own links, including pending and rejected ones. Use `access_level` to hide edit buttons from View only caregivers; the server enforces it either way.

## 4. The box

One box per patient. Box codes look like `PB-7K2M9Q4X`. Boxes are added to the database by the team, not by the app.

| Action | Call |
|---|---|
| Pair | `POST /rest/v1/rpc/pair_device` with `{ "p_patient_id": 12, "p_code": "PB-7K2M9Q4X" }` |
| Unpair | `POST /rest/v1/rpc/unpair_device` with `{ "p_patient_id": 12 }` |
| See the box | `GET /rest/v1/devices?select=device_code,paired_at` |

Allowed for the patient and for caregivers with **Can manage**. The code is case-insensitive. Errors: `not allowed`, `box not found or already paired`, `this patient already has a box`, `no box paired`.

## 5. Scanning a prescription

The scan reads a photo with a vision-language model (Qwen2.5-VL 72B, through OpenRouter). **It saves nothing.** It returns a list; the user checks and edits it; the app then saves it (section 6).

`POST {base}/functions/v1/scan-prescription`, with the headers from section 1 and this body:

```json
{ "patient_id": 12, "images": ["<base64 JPEG or PNG>", "<page 2>", "<page 3>"] }
```

- `patient_id`: the patient's number. `12` and `"12"` both work. A caregiver sends the patient they are working on.
- `images`: 1 to 3 pages. **JPEG or PNG only. At most 2 MB per image** (after decoding). Shrink the photo in the app first. A `data:image/jpeg;base64,` prefix is accepted and optional.
- Allowed for the patient and for caregivers with **Can manage**. View only gets 403.
- Each page is read separately, so a scan can take **up to about 90 seconds** in a bad case. Show a progress state and set the client timeout above 100 seconds.

**Success (200):**

```json
{
  "medicines": [
    {
      "name": "Augmentin",
      "dose": "625 mg",
      "frequency": "twice a day",
      "duration": "5 days",
      "schedule": { "morning": 1, "noon": 0, "evening": 0, "night": 1 },
      "tablets_per_dose": 1,
      "form": "tablet",
      "notes": "after meals",
      "times_per_day": 2,
      "duration_days": 5
    }
  ],
  "failed_pages": []
}
```

| Field | Type | Meaning |
|---|---|---|
| `name` | text | always present |
| `dose` | text | strength as written, `""` if none |
| `frequency` | text | in words, `""` if none |
| `duration` | text or `null` | as written ("5 days") |
| `schedule` | object or `null` | tablets in each part of the day; only when written as numbers like `1-0-1` |
| `tablets_per_dose` | number or `null` | 0.5 steps, 0.5 to 10 |
| `form` | `"tablet"`, `"other"` or `null` | `other` = gel, cream, syrup, drops, injection... |
| `notes` | text | special instructions, `""` if none |
| `times_per_day` | 1 to 12 or `null` | worked out from `frequency` (not from "once a week") |
| `duration_days` | 1 to 365 or `null` | worked out from `duration`; ranges like "5-7 days" stay `null` |
| `failed_pages` | list of page numbers | pages (starting at 1) that could not be read; the others are still returned |

**Schedule rule:** three written numbers are morning-noon-night (evening is 0); four numbers are morning-noon-evening-night. The scan never invents a schedule from the frequency: if none is written, `schedule` is `null`.

Medicines with the same name and dose on a later page are dropped as duplicates.

**Errors** are always `{ "error": "<code>", "message": "<text>" }`:

| Status | `error` | When |
|---|---|---|
| 400 | `bad_request` | bad JSON, missing or invalid `patient_id`, not 1 to 3 images, not valid base64, not a JPEG or PNG |
| 401 | `unauthorized` | no login, or expired token (the gateway may answer in a different shape; just treat 401 as "log in again") |
| 403 | `forbidden` | this user cannot manage this patient |
| 405 | `method_not_allowed` | not a POST |
| 413 | `payload_too_large` | an image over 2 MB, or the whole request too big |
| 422 | `nothing_readable` | no medicine could be read: ask for a clearer photo |
| 500 | `server_error` | server problem |
| 502 | `upstream_error` | the reading service is down: try again later |

**Screens to build:** the result must be shown as an **editable list**, never saved straight away. Let the user fix names and doses, change `form`, add or delete rows, and see which pages failed.

## 6. Saving the confirmed list

`POST /rest/v1/rpc/save_prescription` with:

```json
{
  "p_patient_id": 12,
  "p_medicines": [
    { "name": "Augmentin", "dose": "625 mg", "frequency": "twice a day", "duration": "5 days",
      "schedule": { "morning": 1, "noon": 0, "evening": 0, "night": 1 },
      "tablets_per_dose": 1, "form": "tablet", "notes": "", "times_per_day": 2, "duration_days": 5 }
  ]
}
```

Send the same objects the scan returned, after the user's edits. Everything except `name` may be missing or `null`.

- **All or nothing:** if one medicine is invalid, nothing is saved.
- Returns `{ "prescription_id": 31, "medicine_ids": [88, 89] }`. The ids are in the same order as the list you sent.
- Limits: 1 to 30 medicines. `name` 1 to 120 characters; `dose` up to 60; `frequency` up to 120; `duration` up to 60; `notes` up to 300. `form` is `"tablet"`, `"other"` or missing. `tablets_per_dose` 0.5 to 10 in steps of 0.5. `times_per_day` 1 to 12. `duration_days` 1 to 365. A `schedule` needs all four parts between 0 and 10 in steps of 0.5, and not all zero. A part left out counts as 0.
- Errors (in `message`): `not allowed` (no manage rights), `invalid medicine list` (not a list, empty, more than 30), `invalid medicine` (blank or too long name or text, bad `form`), or the name of the broken rule, for example `prescription_medicines_tablets_check`.
- **Schedules are not created here.** The times of day come later, when medicines are put into box slots (not built yet). Until then the scan's pattern is kept on the medicine.
- **Half tablets:** the scan can return 0.5, but the box dispenses whole pills. This will be handled when slots are assigned. You can show a warning.

Reading saved data: `GET /rest/v1/prescriptions?select=id,created_at&order=created_at.desc` and `GET /rest/v1/prescription_medicines?select=*&prescription_id=eq.31`. Medicines can be edited with `PATCH /rest/v1/prescription_medicines?id=eq.88` (columns: `med_name`, `dosage`, `frequency`, `duration`, `tablets_per_dose`, `form`, `notes`, `duration_days`, `times_per_day`, `dose_morning`, `dose_noon`, `dose_evening`, `dose_night`). Note: the saved column names differ slightly from the scan's: `name` is saved as `med_name`, `dose` as `dosage`, and `schedule` as the four `dose_*` columns.

## 7. Who can do what

| | Patient | Caregiver, Can manage | Caregiver, View only | Not linked, pending or rejected |
|---|---|---|---|---|
| Read the patient's profile, prescriptions, medicines, slots, schedules, log, box | yes | yes | yes | no |
| Scan, save, edit, delete prescriptions and medicines | yes | yes | no | no |
| Create and edit slots (`compartments`) and dose times (`schedules`) | yes | yes | no | no |
| Pair and unpair the box | yes | yes | no | no |
| Approve, reject, remove caregivers, see the link code | yes | no | no | no |
| Read the activity log (`change_log`) | yes | yes | yes | no |

- Not logged in: nothing at all.
- The server enforces all of this. A forbidden write fails with HTTP 403 (`code: 42501`) or silently changes 0 rows; a failed function call answers 400 with its message. The app should still hide buttons the user cannot use.
- `change_log` records who changed what (names and ids, never the medicine text). It is for a "recent activity" screen for the patient.
- The ids and owner columns (`id`, `patient_id`, `prescription_id`, and so on) can never be changed after creation.

## 8. Not built yet

Putting medicines into box slots and creating dose times, refills and low-stock alerts, adherence history, dosing logic, the box connection (MQTT) and caregiver alerts. The tables for slots (`compartments`), dose times (`schedules`) and taken or missed doses (`adherence_log`) already exist and follow the same access rules, but the flow around them is not final.

Push notifications use Firebase Cloud Messaging: the app stores its token in `push_tokens` (`fcm_token`, `platform` = `android` or `ios`). Firebase is used for nothing else; the backend is Supabase.
