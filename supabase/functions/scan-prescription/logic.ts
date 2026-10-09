// Pure logic for scan-prescription: prompt, request validation, model-output
// parsing, normalization and merging. No Deno or network code in here, so it
// can be tested anywhere.

export const DEFAULT_MODEL = "qwen/qwen2.5-vl-72b-instruct";
export const MAX_IMAGES = 3;
export const MAX_IMAGE_BYTES = 2 * 1024 * 1024; // decoded size per image
export const MAX_BODY_CHARS = 8_600_000; // 3 images at 2 MB, base64-encoded, plus JSON overhead

export const PROMPT = `Extract every medicine from this prescription image.

For each medicine return:
- name: drug name only (no "Tab." or "Cap." prefix)
- dose: strength written for the medicine (e.g. "625 mg", "40 mg"), or "" if none is written
- frequency: how often, in words (e.g. "3 times a day"). Expand abbreviations: o.d./q.d. = once a day, b.i.d. = twice a day, t.i.d. = three times a day, q.i.d. = four times a day, p.o. = by mouth.
- duration: treatment length as written (e.g. "5 days", "1 week"), or null if none is written
- tablets_per_dose: number of tablets or capsules per dose, only if written explicitly (e.g. "2 tablets"; a handwritten "ii" or "TT" before "tablets" means 2). Otherwise null.
- form: "tablet" for tablets and capsules, "other" for anything that is not swallowed as a pill (gel, cream, syrup, drops, injection, paint, ...)
- schedule: only if a dosing pattern is written as numbers separated by dashes, e.g. 1-0-1
- notes: special instructions or conditions (e.g. "only if fever", "take with food", "after meals", "before meals"). A note written beside a bracket or brace that covers several medicines applies to each of them.

Schedule rules:
- 4 numbers are morning-noon-evening-night.
- 3 numbers are morning-noon-night. Set "evening" to 0.
- Example: 1-0-1 (3 numbers) becomes {"morning": 1, "noon": 0, "evening": 0, "night": 1}
- Example: 0-1-1-0 (4 numbers) becomes {"morning": 0, "noon": 1, "evening": 1, "night": 0}
- Do NOT infer schedules from frequency.
- If no explicit schedule exists, set "schedule" to null.

Other rules:
- If no duration is written, set "duration" to null.
- Ignore patient, doctor, clinic and pharmacy details (names, addresses, phone numbers, dates, ID numbers). Do not output them.
- If you cannot read a medicine name, skip that medicine.
- Return valid JSON only, with no markdown and no extra text.

Schema:
{
  "medications": [
    {
      "name": "",
      "dose": "",
      "frequency": "",
      "duration": "",
      "schedule": {
        "morning": 0,
        "noon": 0,
        "evening": 0,
        "night": 0
      },
      "tablets_per_dose": null,
      "form": "tablet",
      "notes": ""
    }
  ]
}`;

export type Schedule = { morning: number; noon: number; evening: number; night: number };

export type Medicine = {
  name: string;
  dose: string;
  frequency: string;
  duration: string | null;
  schedule: Schedule | null;
  tablets_per_dose: number | null;
  form: "tablet" | "other" | null;
  notes: string;
  times_per_day: number | null;
  duration_days: number | null;
};

// ---------------------------------------------------------------- request

export type Image = { mime: "image/jpeg" | "image/png"; b64: string };

type Fail = { ok: false; status: 400 | 413; message: string };

export function parseImage(input: unknown): ({ ok: true } & Image) | Fail {
  if (typeof input !== "string" || input.length === 0) {
    return { ok: false, status: 400, message: "Each image must be a base64 string." };
  }
  let s = input.trim();
  if (s.startsWith("data:")) {
    const m = /^data:image\/(?:jpeg|jpg|png);base64,/i.exec(s);
    if (!m) return { ok: false, status: 400, message: "Only JPEG or PNG images are accepted." };
    s = s.slice(m[0].length);
  }
  s = s.replace(/\s+/g, "");
  if (s.length < 16 || s.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(s)) {
    return { ok: false, status: 400, message: "Image is not valid base64." };
  }
  const pad = s.endsWith("==") ? 2 : s.endsWith("=") ? 1 : 0;
  const bytes = (s.length / 4) * 3 - pad;
  if (bytes > MAX_IMAGE_BYTES) {
    return { ok: false, status: 413, message: "Image is larger than 2 MB." };
  }
  const head = atob(s.slice(0, 16));
  const b = [0, 1, 2, 3].map((i) => head.charCodeAt(i));
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return { ok: true, mime: "image/jpeg", b64: s };
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return { ok: true, mime: "image/png", b64: s };
  return { ok: false, status: 400, message: "Only JPEG or PNG images are accepted." };
}

export function validateRequest(
  body: unknown,
): { ok: true; patientId: number; images: Image[] } | Fail {
  if (!body || typeof body !== "object") return { ok: false, status: 400, message: "Body must be a JSON object." };
  const { patient_id, images } = body as Record<string, unknown>;
  // patients.id is an integer. Accept 12 or "12".
  const pid = typeof patient_id === "number"
    ? patient_id
    : typeof patient_id === "string" && /^\d{1,10}$/.test(patient_id.trim())
    ? Number(patient_id.trim())
    : NaN;
  if (!Number.isInteger(pid) || pid < 1 || pid > 2147483647) {
    return { ok: false, status: 400, message: "patient_id is missing or invalid." };
  }
  if (!Array.isArray(images) || images.length < 1 || images.length > MAX_IMAGES) {
    return { ok: false, status: 400, message: `Send 1 to ${MAX_IMAGES} images.` };
  }
  const out: Image[] = [];
  for (const img of images) {
    const r = parseImage(img);
    if (!r.ok) return r;
    out.push({ mime: r.mime, b64: r.b64 });
  }
  return { ok: true, patientId: pid, images: out };
}

// ----------------------------------------------------------- model output

export function extractJson(text: string): unknown {
  const s = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();
  try {
    return JSON.parse(s);
  } catch { /* try to cut out the JSON part */ }
  for (const [open, close] of [["{", "}"], ["[", "]"]]) {
    const a = s.indexOf(open);
    const b = s.lastIndexOf(close);
    if (a !== -1 && b > a) {
      try {
        return JSON.parse(s.slice(a, b + 1));
      } catch { /* next */ }
    }
  }
  throw new Error("no JSON found");
}

function str(v: unknown, max: number): string {
  if (typeof v === "string") return v.trim().slice(0, max);
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  return "";
}

function halfStep(n: number): boolean {
  return Number.isFinite(n) && (n * 2) % 1 === 0;
}

function toNumber(v: unknown): number {
  if (typeof v === "number") return v;
  if (typeof v === "string" && /^\d+(\.\d+)?$/.test(v.trim())) return Number(v);
  return NaN;
}

export function normalizeSchedule(raw: unknown): Schedule | null {
  let parts: unknown[] | null = null;
  if (Array.isArray(raw)) {
    parts = raw;
  } else if (typeof raw === "string") {
    parts = raw.trim().split(/\s*[-–—]\s*/);
  } else if (raw && typeof raw === "object") {
    const r = raw as Record<string, unknown>;
    parts = [r.morning ?? 0, r.noon ?? 0, r.evening ?? 0, r.night ?? 0];
  }
  if (!parts) return null;
  if (Array.isArray(raw) || typeof raw === "string") {
    if (parts.length === 3) parts = [parts[0], parts[1], 0, parts[2]]; // morning-noon-night
    else if (parts.length !== 4) return null;
  }
  const nums = parts.map(toNumber);
  if (nums.some((n) => !(n >= 0 && n <= 10) || !halfStep(n))) return null;
  if (nums.every((n) => n === 0)) return null;
  return { morning: nums[0], noon: nums[1], evening: nums[2], night: nums[3] };
}

const WORD_NUMBERS: Record<string, number> = {
  one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
};

export function parseTimesPerDay(frequency: string): number | null {
  let s = frequency.toLowerCase();
  // t.i.d. -> tid, o.d. -> od
  s = s.replace(/\b([a-z])\.([a-z])\.([a-z])\.?/g, "$1$2$3").replace(/\b([a-z])\.([a-z])\.?/g, "$1$2");
  const ok = (n: number) => (Number.isInteger(n) && n >= 1 && n <= 12 ? n : null);
  // Not a per-day rhythm ("once a week", "twice weekly", "every other day"): leave it to the user
  if (/\b(?:a|per|each|every)\s+(?:week|month)\b|\b(?:weekly|monthly|fortnightly|alternate|every other)\b/.test(s)) return null;
  let m = /\bevery\s+(\d{1,2})\s*(?:hours?|hrs?|h)\b/.exec(s);
  if (m) {
    const h = Number(m[1]);
    return h >= 1 && h <= 24 && 24 % h === 0 ? ok(24 / h) : null;
  }
  m = /\b(\d{1,2})\s*(?:times?|x)\s*(?:a|per|\/)?\s*(?:day|daily)\b/.exec(s);
  if (m) return ok(Number(m[1]));
  m = /\b(one|two|three|four|five|six)\s*times?\b/.exec(s);
  if (m) return ok(WORD_NUMBERS[m[1]]);
  if (/\b(?:once|od|qd)\b/.test(s)) return 1;
  if (/\b(?:twice|bid|bd)\b/.test(s)) return 2;
  if (/\b(?:thrice|tid|tds)\b/.test(s)) return 3;
  if (/\b(?:qid|qds)\b/.test(s)) return 4;
  return null;
}

export function parseDurationDays(duration: string | null): number | null {
  if (!duration) return null;
  const s = duration.toLowerCase().trim().replace(/^(?:x|×|for)\s*/, "");
  const m = /^(\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten)\s*(days?|d|weeks?|wks?|w|months?|mos?)$/.exec(s);
  if (!m) return null; // ranges like "5-7 days" and free text are left to the user
  const n = /^\d/.test(m[1]) ? Number(m[1]) : WORD_NUMBERS[m[1]];
  const unit = m[2][0];
  const days = unit === "w" ? n * 7 : unit === "m" ? n * 30 : n;
  return days >= 1 && days <= 365 ? days : null;
}

function normalizeForm(v: unknown): Medicine["form"] {
  const s = str(v, 20).toLowerCase();
  if (["tablet", "tablets", "capsule", "capsules", "pill", "pills"].includes(s)) return "tablet";
  if (s === "other") return "other";
  return null;
}

export function normalizeMedicine(raw: unknown): Medicine | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const name = str(r.name, 120);
  if (!name) return null;

  const frequency = str(r.frequency, 120);
  const duration = str(r.duration, 60) || null;
  const schedule = normalizeSchedule(r.schedule);
  const form = normalizeForm(r.form);

  const tablets = toNumber(r.tablets_per_dose);
  let tabletsPerDose: number | null = tablets > 0 && tablets <= 10 && halfStep(tablets) ? tablets : null;
  if (tabletsPerDose === null && schedule && form !== "other") {
    const used = new Set(Object.values(schedule).filter((n) => n > 0));
    if (used.size === 1) tabletsPerDose = [...used][0];
  }

  const slots = schedule ? Object.values(schedule).filter((n) => n > 0).length : 0;
  return {
    name,
    dose: str(r.dose ?? r.dosage, 60),
    frequency,
    duration,
    schedule,
    tablets_per_dose: tabletsPerDose,
    form,
    notes: str(r.notes, 300),
    times_per_day: parseTimesPerDay(frequency) ?? (slots > 0 ? slots : null),
    duration_days: parseDurationDays(duration),
  };
}

/** Returns the medicines, or null when the text is not usable JSON (caller retries). */
export function parseModelOutput(text: string): Medicine[] | null {
  let data: unknown;
  try {
    data = extractJson(text);
  } catch {
    return null;
  }
  const list = Array.isArray(data)
    ? data
    : data && typeof data === "object"
    ? (data as Record<string, unknown>).medications
    : undefined;
  if (!Array.isArray(list)) return null;
  const meds = list.map(normalizeMedicine).filter((m): m is Medicine => m !== null);
  if (list.length > 0 && meds.length === 0) return null;
  return meds;
}

// ------------------------------------------------------------------ merge

function key(m: Medicine): string {
  return m.name.toLowerCase().replace(/[^a-z0-9؀-ۿ]/g, "") + "|" + m.dose.toLowerCase().replace(/\s+/g, "");
}

/** Joins the pages in order. A medicine is dropped only if an EARLIER page already had the same name and dose. */
export function mergeMedicines(pages: Medicine[][]): Medicine[] {
  const seen = new Set<string>();
  const out: Medicine[] = [];
  for (const page of pages) {
    const pageKeys: string[] = [];
    for (const m of page) {
      const k = key(m);
      if (seen.has(k)) continue;
      out.push(m);
      pageKeys.push(k);
    }
    pageKeys.forEach((k) => seen.add(k));
  }
  return out;
}
