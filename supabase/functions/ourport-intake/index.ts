// Intentionally public write-only intake. Privileged credentials stay in this runtime.
const PROJECT_URL = 'https://xpdnhfgfbgcunlmuyjrx.supabase.co';
const ORIGINS = new Set(['https://ourport.us', 'https://www.ourport.us']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TOKEN = /^[0-9a-f]{64}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const COMMON = { contactName: 120, email: 254, projectName: 180, location: 180, currentService: 180, note: 2000 };
const BRANCHES = {
  laundromat: { dashboard: 180, processingHours: 180, accessHours: 180, bagSize: 300 },
  housing: { providerStatus: 180, residentSystem: 180 },
  builder: { siteStage: 180, wallDimensions: 200, siteConstraints: 1000 },
};
const ENUMS = {
  currentService: ['Wash-and-fold in place', 'Planning wash-and-fold', 'Pickup and delivery', 'No laundry service yet'],
  providerStatus: ['Already selected', 'In discussion', 'Looking for a provider'],
  siteStage: ['Early planning', 'Design development', 'Under construction', 'Existing-site retrofit'],
};
const MAX_BYTES = 16384;

export function normalizeInput(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Check the inquiry details.');
  if (typeof input.requestId !== 'string' || typeof input.editToken !== 'string' || !UUID.test(input.requestId) || !TOKEN.test(input.editToken)) throw new Error('Start a new inquiry and try again.');
  if (input.stage === 'withdraw') {
    if (Object.keys(input).some(key => !['stage', 'requestId', 'editToken'].includes(key))) throw new Error('Check the inquiry details.');
    return { withdraw: true, requestId: input.requestId, editToken: input.editToken };
  }
  if (!['draft', 'submitted'].includes(input.stage) || typeof input.role !== 'string' || !Object.hasOwn(BRANCHES, input.role)) throw new Error('Choose a project type.');
  if (!Number.isSafeInteger(input.revision) || input.revision < 1 || input.revision > 100000) throw new Error('Start a new inquiry and try again.');
  if (typeof input.progressConsent !== 'boolean' || (input.stage === 'draft' && !input.progressConsent)) throw new Error('Choose whether to share your progress.');
  const limits = { ...COMMON, ...BRANCHES[input.role] };
  const allowed = new Set([...Object.keys(limits), 'requestId', 'editToken', 'role', 'stage', 'revision', 'progressConsent', 'website', 'sourcePath', 'locationCount', ...(input.role === 'housing' ? ['homesOrBeds'] : [])]);
  if (Object.keys(input).some(key => !allowed.has(key)) || (input.website !== undefined && typeof input.website !== 'string') || input.website) throw new Error('Check the inquiry details.');
  const values = {};
  for (const [key, maximum] of Object.entries(limits)) {
    if (input[key] === undefined || input[key] === '') continue;
    if (typeof input[key] !== 'string' || input[key].length > maximum || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(input[key])) throw new Error('Check the inquiry details.');
    const value = input[key].trim();
    if (!value) continue;
    if (ENUMS[key] && !ENUMS[key].includes(value)) throw new Error('Choose one of the listed options.');
    values[key] = value;
  }
  if (!values.email || !EMAIL.test(values.email)) throw new Error('Please enter a valid email address.');
  values.email = values.email.toLowerCase();
  if (input.stage === 'submitted' && (!values.contactName || !values.location)) throw new Error('Your name, email, and city/state are required.');
  for (const [key, maximum] of Object.entries({ locationCount: 10000, ...(input.role === 'housing' ? { homesOrBeds: 100000 } : {}) })) {
    if (input[key] === undefined || input[key] === '') continue;
    if (!['string', 'number'].includes(typeof input[key]) || !Number.isSafeInteger(Number(input[key])) || Number(input[key]) < 1 || Number(input[key]) > maximum) throw new Error('Check the number of locations, homes, or beds.');
    values[key] = Number(input[key]);
  }
  const details = { sourcePath: '/plan-a-site/' };
  for (const [key, value] of Object.entries(values)) if (!['contactName', 'email', 'projectName', 'location', 'locationCount'].includes(key)) details[key] = value;
  return {
    editToken: input.editToken,
    record: {
      request_id: input.requestId,
      stage: input.stage,
      revision: input.revision,
      progress_consent: input.progressConsent,
      role: input.role,
      contact_name: values.contactName || null,
      contact_email: values.email,
      project_name: values.projectName || null,
      location: values.location || null,
      location_count: values.locationCount || null,
      details,
    },
  };
}

async function readBounded(request) {
  if (Number(request.headers.get('content-length')) > MAX_BYTES) throw new RangeError('Inquiry too large.');
  const reader = request.body?.getReader();
  if (!reader) throw new Error('Missing inquiry.');
  let size = 0;
  const parts = [];
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BYTES) { await reader.cancel(); throw new RangeError('Inquiry too large.'); }
    parts.push(value);
  }
  const buffer = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) { buffer.set(part, offset); offset += part.length; }
  return JSON.parse(new TextDecoder().decode(buffer));
}

export function serverKey(env) {
  if (env.SUPABASE_SERVICE_ROLE_KEY) return env.SUPABASE_SERVICE_ROLE_KEY;
  try {
    const keys = JSON.parse(env.SUPABASE_SECRET_KEYS || '{}');
    if (typeof keys.default === 'string' && keys.default) return keys.default;
  } catch { /* Legacy hosted projects expose the service-role variable instead. */ }
  return env.SUPABASE_SERVICE_ROLE_KEY || '';
}

async function networkKey(request, secret) {
  // This is a best-effort network bucket, not authentication. SQL also enforces
  // email and global quotas independently of all client-controlled headers.
  const forwarded = request.headers.get('x-forwarded-for')?.split(',').at(-1)?.trim();
  const candidate = request.headers.get('cf-connecting-ip') || forwarded || 'unavailable';
  const address = /^[a-f0-9:.]{3,64}$/i.test(candidate) ? candidate : 'unavailable';
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const bytes = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode('ourport-intake-network:' + address));
  return Array.from(new Uint8Array(bytes), value => value.toString(16).padStart(2, '0')).join('');
}

export function createIntakeHandler({ env, fetcher = fetch }) {
  return async request => {
    const origin = request.headers.get('origin') || '';
    const permitted = ORIGINS.has(origin);
    const headers = {
      'Content-Type': 'application/json', 'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff', 'Vary': 'Origin',
      ...(permitted ? { 'Access-Control-Allow-Origin': origin } : {}),
    };
    const json = (status, value, extra = {}) => Response.json(value, { status, headers: { ...headers, ...extra } });
    if (!permitted) return json(403, { error: 'Open the inquiry form on OurPort.us.' });
    if (request.method === 'OPTIONS') {
      const requestedHeaders = (request.headers.get('access-control-request-headers') || '').toLowerCase().split(',').map(value => value.trim()).filter(Boolean);
      if (request.headers.get('access-control-request-method') !== 'POST' || requestedHeaders.some(value => value !== 'content-type')) return json(403, { error: 'Request not allowed.' });
      return new Response(null, { status: 204, headers: { ...headers, 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'content-type', 'Access-Control-Max-Age': '600' } });
    }
    if (request.method !== 'POST') return json(405, { error: 'Method not allowed.' }, { Allow: 'POST, OPTIONS' });
    if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') return json(415, { error: 'JSON required.' });
    const secret = serverKey(env);
    if (env.SUPABASE_URL !== PROJECT_URL || !secret) return json(503, { error: 'Inquiry storage is unavailable. Please email the team.' });
    let input;
    try { input = normalizeInput(await readBounded(request)); }
    catch (error) { return json(error instanceof RangeError ? 413 : 400, { error: error instanceof SyntaxError ? 'Check the inquiry details.' : error.message }); }
    try {
      const rpc = input.withdraw ? 'ourport_withdraw_draft_progress' : 'ourport_submit_site_inquiry';
      const body = input.withdraw
        ? { p_request_id: input.requestId, p_edit_token: input.editToken }
        : { p_record: input.record, p_rate_key: await networkKey(request, secret), p_edit_token: input.editToken };
      const response = await fetcher(PROJECT_URL + '/rest/v1/rpc/' + rpc, {
        method: 'POST',
        headers: { apikey: secret, ...(secret.startsWith('eyJ') ? { Authorization: 'Bearer ' + secret } : {}), 'Content-Type': 'application/json' },
        body: JSON.stringify(body), signal: AbortSignal.timeout(10000),
      });
      const data = await response.json().catch(() => null);
      if (!response.ok) {
        if (data?.code === 'P0001' && data?.message === 'rate_limit') return json(429, { error: 'Please wait before sending another update.' }, { 'Retry-After': '900' });
        if (data?.code === '23505' || data?.code === '40001') return json(409, { error: 'This inquiry changed. Start a new inquiry or email the team.' });
        if (data?.code === '22023') return json(400, { error: 'Check the inquiry details.' });
        return json(502, { error: 'We could not confirm receipt. Your details are still in the form.' });
      }
      if (input.withdraw) {
        if (!data || typeof data.withdrawn !== 'boolean') return json(502, { error: 'We could not confirm that progress sharing was paused.' });
        return json(200, { ok: true, withdrawn: data.withdrawn });
      }
      if (!data || !UUID.test(data.id || '') || !Number.isFinite(Date.parse(data.created_at)) || data.revision !== input.record.revision || data.stage !== input.record.stage) return json(502, { error: 'We could not confirm receipt. Please retry.' });
      return json(201, { ok: true, receipt: { id: data.id, created_at: data.created_at, revision: data.revision, stage: data.stage }, notifications: 'queued' });
    } catch {
      return json(502, { error: 'We could not confirm receipt. Your details are still in the form.' });
    }
  };
}

if (typeof Deno !== 'undefined') {
  Deno.serve(createIntakeHandler({ env: {
    SUPABASE_URL: Deno.env.get('SUPABASE_URL'),
    SUPABASE_SECRET_KEYS: Deno.env.get('SUPABASE_SECRET_KEYS'),
    SUPABASE_SERVICE_ROLE_KEY: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
  } }));
}
