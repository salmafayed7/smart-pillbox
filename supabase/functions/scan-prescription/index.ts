// scan-prescription: reads prescription photos with a vision-language model and
// returns a medicine list. It saves NOTHING and does not log model output.
//
// POST /functions/v1/scan-prescription
// Authorization: Bearer <user access token>
// Body: { "patient_id": "...", "images": ["<base64 JPEG or PNG>", ...] }   (1 to 3 images)

import { createClient } from "npm:@supabase/supabase-js@2.117.3";
import {
  DEFAULT_MODEL,
  MAX_BODY_CHARS,
  mergeMedicines,
  parseModelOutput,
  PROMPT,
  validateRequest,
} from "./logic.ts";
import type { Image, Medicine } from "./logic.ts";

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const CALL_TIMEOUT_MS = 45_000;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
function fail(status: number, error: string, message: string): Response {
  return json(status, { error, message });
}

type ModelReply = { kind: "ok"; text: string } | { kind: "retry" } | { kind: "fatal" };

async function callModel(img: Image, apiKey: string, model: string, page: number): Promise<ModelReply> {
  let res: Response;
  try {
    res = await fetch(OPENROUTER_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model,
        temperature: 0,
        max_tokens: 4000, // ~100 tokens per medicine, so room for 30; this is a cap, not a cost
        // Medical data: only use providers that do not store or train on prompts.
        provider: { data_collection: "deny" },
        messages: [{
          role: "user",
          content: [
            { type: "image_url", image_url: { url: `data:${img.mime};base64,${img.b64}` } },
            { type: "text", text: PROMPT },
          ],
        }],
      }),
      signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
    });
  } catch {
    console.error(`page ${page}: OpenRouter request failed or timed out`);
    return { kind: "retry" };
  }
  if (res.status === 429 || res.status >= 500) {
    console.error(`page ${page}: OpenRouter status ${res.status}`);
    return { kind: "retry" };
  }
  if (!res.ok) {
    // 400/401/402/404...: bad key, no credit, unknown model, no provider. Retrying will not help.
    console.error(`page ${page}: OpenRouter status ${res.status}`);
    return { kind: "fatal" };
  }
  try {
    const data = await res.json();
    const text = data?.choices?.[0]?.message?.content;
    return typeof text === "string" ? { kind: "ok", text } : { kind: "retry" };
  } catch {
    return { kind: "retry" };
  }
}

type PageResult = { ok: true; medicines: Medicine[] } | { ok: false; reason: "unreadable" | "upstream" };

/** One model call per page, with one retry when the reply is unusable or the service hiccups. */
async function scanPage(img: Image, apiKey: string, model: string, page: number): Promise<PageResult> {
  let reason: "unreadable" | "upstream" = "upstream";
  for (let attempt = 0; attempt < 2; attempt++) {
    const r = await callModel(img, apiKey, model, page);
    if (r.kind === "fatal") return { ok: false, reason: "upstream" };
    if (r.kind === "retry") {
      reason = "upstream";
      continue;
    }
    const medicines = parseModelOutput(r.text);
    if (medicines) return { ok: true, medicines };
    reason = "unreadable";
  }
  return { ok: false, reason };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return fail(405, "method_not_allowed", "Use POST.");

  // 1. Logged in? (before the body is read, so anonymous callers cost nothing)
  const auth = req.headers.get("Authorization") ?? "";
  const token = /^Bearer\s+(\S+)$/i.exec(auth)?.[1];
  if (!token) return fail(401, "unauthorized", "Login required.");

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!supabaseUrl || !anonKey || !apiKey) {
    console.error("missing environment variables");
    return fail(500, "server_error", "Server is not configured.");
  }

  // The caller's own token is used, so RLS and the permission helpers apply to them.
  const supabase = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await supabase.auth.getUser(token);
  if (userError || !userData?.user) return fail(401, "unauthorized", "Login required.");

  // 2. Body: patient_id, 1 to 3 images, type and size.
  if (Number(req.headers.get("content-length") ?? 0) > MAX_BODY_CHARS) {
    return fail(413, "payload_too_large", "Request is too large.");
  }
  let raw: string;
  try {
    raw = await req.text();
  } catch {
    return fail(400, "bad_request", "Could not read the request body.");
  }
  if (raw.length > MAX_BODY_CHARS) return fail(413, "payload_too_large", "Request is too large.");
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return fail(400, "bad_request", "Body must be valid JSON.");
  }
  const v = validateRequest(body);
  if (!v.ok) {
    return fail(v.status, v.status === 413 ? "payload_too_large" : "bad_request", v.message);
  }

  // 3. Can this user manage this patient?
  const { data: allowed, error: rpcError } = await supabase.rpc("can_manage_patient", { pid: v.patientId });
  if (rpcError) {
    // 22P02 = patient_id is not the right type for the database
    if (rpcError.code === "22P02") return fail(400, "bad_request", "patient_id is invalid.");
    console.error(`can_manage_patient failed: ${rpcError.code}`);
    return fail(500, "server_error", "Permission check failed.");
  }
  if (allowed !== true) return fail(403, "forbidden", "You cannot scan prescriptions for this patient.");

  // 4. One model call per page, in parallel.
  const model = Deno.env.get("OPENROUTER_MODEL") ?? DEFAULT_MODEL;
  const results = await Promise.all(v.images.map((img, i) => scanPage(img, apiKey, model, i + 1)));

  // 5. Merge and answer. Nothing is stored.
  const failedPages = results.flatMap((r, i) => (r.ok ? [] : [i + 1])); // 1-based page numbers
  const medicines = mergeMedicines(results.map((r) => (r.ok ? r.medicines : [])));
  if (medicines.length === 0) {
    if (results.every((r) => !r.ok && r.reason === "upstream")) {
      return fail(502, "upstream_error", "The scanning service is unavailable. Try again later.");
    }
    return fail(422, "nothing_readable", "No medicines could be read from the image.");
  }
  return json(200, { medicines, failed_pages: failedPages });
});
