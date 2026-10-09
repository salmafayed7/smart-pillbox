# SmartPillbox: backend setup and workflow

For anyone who works on the backend: the database, the access rules and the Edge Function. It assumes you have never used Supabase. Commands are for Windows PowerShell unless stated.

What the data looks like and who may do what: `database-and-flow.md`. How the app calls the backend: `frontend-notes.md`.

## 1. What the backend is

- **Supabase** is the whole backend: a PostgreSQL database, login (Supabase Auth), an automatic REST API over the tables, and Edge Functions (small server programs written in TypeScript, run by Deno).
- There are two copies of it:
  - **Local**: runs in Docker on your computer. Safe to break; `supabase db reset` rebuilds it with test data.
  - **Hosted**: the real project, reference `gljpxdrqnkmhgqsegvkz`. Real data. Treat it carefully.
- One Edge Function: `scan-prescription`. It sends prescription photos to Qwen2.5-VL 72B (a vision-language model) through OpenRouter and returns a medicine list. It saves nothing.

## 2. Repository layout

```
smart-pillbox/
  app/                      Flutter app (separate; not part of the backend)
  supabase/
    config.toml             local stack settings
    migrations/             the database, as numbered SQL files (the source of truth)
    seed.sql                local test data (never sent to hosted)
    tests/                  SQL tests for the access rules
    functions/
      .env                  local secrets (ignored by git, never commit)
      scan-prescription/    index.ts (web handling) and logic.ts (parsing and rules)
  docs/
    postman/                Postman collections and environment
    *.md                    these notes
  .gitignore
```

## 3. One-time setup

1. Install **Docker Desktop** and keep it running.
2. Install the **Supabase CLI** (this project was built with version 2.119). Check with `supabase --version`.
3. Optional: **Node.js**, only to run Postman collections from the terminal (`npx newman`). **Deno** is not required.
4. Log in and connect the folder to the hosted project (ask Salma to add you to the Supabase project first):

```powershell
supabase login
cd smart-pillbox
supabase link --project-ref gljpxdrqnkmhgqsegvkz
```

5. Create the local secret file `supabase/functions/.env` with one line:

```
OPENROUTER_API_KEY=<the OpenRouter key>
```

   Get the key from Salma, never from chat or git. Optionally add `OPENROUTER_MODEL=<model id>` to try another model; the default is `qwen/qwen2.5-vl-72b-instruct`. The file is ignored by git.

## 4. The local stack

```powershell
supabase start        # first run downloads images, then starts everything
supabase status       # shows the URLs
supabase status -o env   # shows the keys, including ANON_KEY
supabase db reset     # rebuild the database from the migrations, then load seed.sql
supabase stop
```

| What | Where |
|---|---|
| API and functions | `http://127.0.0.1:54321` (functions at `/functions/v1/<name>`) |
| Database | `127.0.0.1:54322` (user `postgres`, container `supabase_db_smart-pillbox`) |
| Studio (web view of the database) | `http://127.0.0.1:54323` |
| Test emails | `http://127.0.0.1:54324` |

`supabase db reset` is the answer to most local problems. It wipes local data only.

**Test logins** (created by the seed; password for all is `Test12345!`):

| Email | Role |
|---|---|
| `patient@test.com` | patient; link code `SEED0001` |
| `caregiver@test.com` | caregiver linked with Can manage |
| `viewer@test.com` | caregiver linked with View only |
| `newcaregiver@test.com` | caregiver not linked (use code `SEED0001`) |

A free box for pairing tests: `PB-DEMO0001`.

If the scan function answers 500 `Server is not configured`, the OpenRouter key is not loaded. Check `supabase/functions/.env`, then `supabase stop` and `supabase start`.

## 5. Changing the database: the rules

The database is defined **only** by the files in `supabase/migrations/`, applied in file-name order. Studio and ad-hoc SQL are for looking, not for changing.

- **Add a new file; never edit one that has been pushed.** Create it with `supabase migration new short_name`, write the SQL, then `supabase db reset` to prove all files apply cleanly from scratch.
- Every new table: turn on row-level security, add policies, and grant only the rights the app needs. The baseline gives `anon` nothing and signed-in users nothing until a migration grants it.
- Updates are granted **column by column** (`grant update (a, b) on ...`) so ids and owner columns stay unchangeable.
- Functions that run with the owner's rights (`security definer`) must `set search_path = public`, and must have `revoke execute ... from public, anon` followed by an explicit grant to `authenticated`.
- Helper checks must return true or false, never null.
- Child tables carry `patient_id` with composite foreign keys (see `database-and-flow.md`).
- `change_log` stores identifiers only. Never put prescription text (names, doses, notes) in a log, a table meant for auditing, or `console.log`.
- Never write phone numbers anywhere. There are none by design.

## 6. Testing

Three SQL tests live in `supabase/tests/`. Each runs inside one transaction that is never committed, so it leaves no data. A pass ends with a deliberate error:

```
ERROR:  ALL TESTS PASSED (test data rolled back)
```

Run `supabase db reset` first (they use the seed), then in PowerShell:

```powershell
Get-Content supabase\tests\auth_rls_test.sql -Raw | docker exec -i supabase_db_smart-pillbox psql -U postgres -d postgres -v ON_ERROR_STOP=1
```

In `cmd` you can use `docker exec -i supabase_db_smart-pillbox psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase\tests\auth_rls_test.sql`.

| File | Covers |
|---|---|
| `auth_rls_test.sql` | signup rules, linking and code rotation, access per role, pairing, change log |
| `save_prescription_test.sql` | `save_prescription`: permissions, limits, all-or-nothing, new columns |
| `privileges_test.sql` | no leftover truncate, references or trigger rights; the app's grants still exist |

Any other message means a check failed; it names which one. When you change the rules, change the test with it.

## 7. Postman

Files in `docs/postman/`:

- `SmartPillbox_API_tests.postman_collection.json`: 42 requests that exercise signup, linking, the three roles, writes, pairing and removal.
- `SmartPillbox_scan_prescription.postman_collection.json`: 5 requests for the scan function.
- `SmartPillbox Local.postman_environment.json`: the variables.

Steps (local):

1. `supabase db reset`.
2. Import all three files. Select the environment **SmartPillbox Local**.
3. Paste the local `ANON_KEY` into `anon_key`. **Never commit a filled-in environment.**
4. Run the API collection in order (Collection Runner). It signs up fresh users each run and fills `access_token`, `viewer_access_token` and `patient_id` in the environment.
5. Run the scan collection. Set `test_image_base64` once to a valid JPEG or PNG in base64 (any tiny PNG works for the 401, 400 and 403 requests). Its first request, "Scan prescription (manager) - 200", needs a **real prescription photo and spends OpenRouter credit**; use it deliberately. Tokens last one hour.

From a terminal without Postman: `npx newman run docs/postman/SmartPillbox_API_tests.postman_collection.json -e "docs/postman/SmartPillbox Local.postman_environment.json" --env-var "anon_key=<key>"`.

## 8. The Edge Function

- `index.ts` handles the request in this order: login check (401), then the body, then `can_manage_patient` using the caller's own token (403), then one model call per page in parallel (up to 3 pages), then merge. `logic.ts` holds the prompt, request validation, parsing and rules, with no network code.
- Model calls: temperature 0, `provider.data_collection = "deny"` (only providers that do not store or train on prompts), 45-second timeout, one retry on bad JSON, 429 or 5xx, none on other 4xx.
- **Privacy:** the photo is never stored and nothing from the image or the model's answer is logged. Only page numbers and HTTP status codes are logged. Keep it that way.
- The key is read from `OPENROUTER_API_KEY`. It must never be returned in a response, logged, or committed.
- The library import is pinned to an exact version (`npm:@supabase/supabase-js@2.117.3`) so every deploy behaves like what you tested. Update it on purpose, then retest.
- Deploy to hosted: `supabase functions deploy scan-prescription`. List what is deployed: `supabase functions list`.

## 9. The hosted project

Changing hosted is the only step that affects real data. Checklist:

1. Work and test locally first: `supabase db reset`, all three SQL tests, both Postman collections.
2. `supabase migration list` shows which migrations hosted has.
3. `supabase db push --dry-run` lists what would be applied. Read it.
4. `supabase db push` applies the new migrations only; existing data is untouched. The seed is never pushed.
5. `supabase functions deploy scan-prescription` if the function changed.
6. Never run `db reset` against hosted.

Secrets on hosted: `supabase secrets set OPENROUTER_API_KEY=...` sets the key. `supabase secrets list` shows names and a digest for each; do not paste that output anywhere.

Current hosted state (kept up to date by the team): migrations 1 to 6 applied; function `scan-prescription` deployed; email confirmation is **off** (fine for development; turn it on before real users); the box `PB-7K2M9Q4X` exists. New boxes are added by inserting a row into `devices` with an upper-case `device_code` (Dashboard, Table Editor).

## 10. Secrets and git

- Never commit: `supabase/functions/.env`, any OpenRouter key, the `service_role` key, a filled-in Postman environment, or anything in `supabase/.temp/` (it holds local keys). `.gitignore` covers `.env`, `.temp/`, `.branches/` and `snippets/`.
- If a key is ever pasted somewhere public, replace it at once (OpenRouter dashboard, then `supabase secrets set`).
- The anon key is public by design and may appear in the app.

## 11. Wording

Qwen2.5-VL is a **vision-language model**. Do not call it an OCR engine in code comments, docs or strings.

## 12. Not built yet

Putting medicines into box slots and creating dose times, refills, adherence queries, dosing logic, the box connection (MQTT) and caregiver alerts. See `database-and-flow.md`.
