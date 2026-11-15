// Unit tests use synthetic RPC responses only. They do not verify live database
// grants, deployed rate limits, notification delivery, or production storage.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createIntakeHandler, normalizeInput, serverKey } from '../supabase/functions/ourport-intake/index.ts';

const PROJECT = 'https://xpdnhfgfbgcunlmuyjrx.supabase.co';
const ENDPOINT = PROJECT + '/functions/v1/ourport-intake';
const REQUEST_ID = '11111111-1111-4111-8111-111111111111';
const RECEIPT_ID = '22222222-2222-4222-8222-222222222222';
const EDIT_TOKEN = 'a'.repeat(64);
const RUNTIME_CREDENTIAL = 'synthetic-runtime-credential';
const LEGACY_CREDENTIAL = 'eyJsynthetic.legacy.signature';
const env = { SUPABASE_URL: PROJECT, SUPABASE_SECRET_KEYS: JSON.stringify({ default: RUNTIME_CREDENTIAL }) };

function inquiry(overrides = {}) {
  return { requestId: REQUEST_ID, editToken: EDIT_TOKEN, role: 'laundromat', stage: 'submitted', revision: 1, progressConsent: false, contactName: 'Unit Test', email: 'test@example.com', location: 'Tucson, AZ', ...overrides };
}

function receipt(overrides = {}) {
  return { id: RECEIPT_ID, created_at: '2026-11-15T18:00:00.000Z', revision: 1, stage: 'submitted', ...overrides };
}

function request(payload, { origin = 'https://ourport.us', method = 'POST', headers = {}, raw } = {}) {
  const values = new Headers({ 'Content-Type': 'application/json', ...headers });
  if (origin !== null) values.set('Origin', origin);
  const body = raw ?? (payload === undefined ? undefined : JSON.stringify(payload));
  return new Request(ENDPOINT, { method, headers: values, ...(body !== undefined ? { body } : {}) });
}

function fixture(reply = receipt(), { status = 200, environment = env, fetchError } = {}) {
  const calls = [];
  const handler = createIntakeHandler({
    env: environment,
    fetcher: async (url, options) => {
      calls.push({ url, options, payload: JSON.parse(options.body) });
      if (fetchError) throw fetchError;
      return reply instanceof Response ? reply : Response.json(reply, { status });
    },
  });
  return { handler, calls };
}

function assertSafeHeaders(response, origin = 'https://ourport.us') {
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), origin);
  assert.equal(response.headers.get('Access-Control-Allow-Credentials'), null);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
  assert.equal(response.headers.get('Vary'), 'Origin');
}

test('rejects missing, deceptive, non-HTTPS and local origins before contacting storage', async () => {
  for (const origin of [null, 'null', 'http://ourport.us', 'https://ourport.us.evil.example', 'https://evil.example', 'http://127.0.0.1:4321']) {
    const { handler, calls } = fixture();
    const response = await handler(request(inquiry(), { origin }));
    assert.equal(response.status, 403);
    assert.equal(response.headers.get('Access-Control-Allow-Origin'), null);
    assert.equal(response.headers.get('Access-Control-Allow-Credentials'), null);
    assert.equal(calls.length, 0);
  }
});

test('preflight permits only POST with the content-type header for each production origin', async () => {
  for (const origin of ['https://ourport.us', 'https://www.ourport.us']) {
    const { handler, calls } = fixture();
    const response = await handler(request(undefined, { origin, method: 'OPTIONS', headers: { 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'Content-Type' } }));
    assert.equal(response.status, 204);
    assertSafeHeaders(response, origin);
    assert.equal(await response.text(), '');
    assert.equal(response.headers.get('Access-Control-Allow-Methods'), 'POST, OPTIONS');
    assert.equal(response.headers.get('Access-Control-Allow-Headers'), 'content-type');
    assert.equal(response.headers.get('Access-Control-Max-Age'), '600');
    assert.equal(calls.length, 0);
  }
});

test('preflight rejects other methods and authorization or custom headers', async () => {
  for (const headers of [
    { 'Access-Control-Request-Method': 'GET' },
    { 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'authorization' },
    { 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'content-type, x-admin' },
    {},
  ]) {
    const { handler, calls } = fixture();
    const response = await handler(request(undefined, { method: 'OPTIONS', headers }));
    assert.equal(response.status, 403);
    assert.equal(calls.length, 0);
  }
});

test('rejects non-POST requests and non-JSON content without contacting storage', async () => {
  const { handler, calls } = fixture();
  const get = await handler(request(undefined, { method: 'GET' }));
  assert.equal(get.status, 405);
  assert.equal(get.headers.get('Allow'), 'POST, OPTIONS');
  const text = await handler(request(inquiry(), { headers: { 'Content-Type': 'text/plain' } }));
  assert.equal(text.status, 415);
  assertSafeHeaders(text);
  assert.equal(calls.length, 0);
});

test('fails closed when privileged configuration is absent or targets another project', async () => {
  for (const environment of [{}, { SUPABASE_URL: PROJECT }, { ...env, SUPABASE_URL: 'https://other-project.supabase.co' }, { ...env, SUPABASE_URL: undefined }]) {
    const { handler, calls } = fixture(receipt(), { environment });
    const response = await handler(request(inquiry()));
    assert.equal(response.status, 503);
    assertSafeHeaders(response);
    assert.equal(calls.length, 0);
  }
});

test('prefers the legacy service-role credential and otherwise selects the default runtime API key', () => {
  assert.ok(serverKey({ ...env, SUPABASE_SERVICE_ROLE_KEY: LEGACY_CREDENTIAL }) === LEGACY_CREDENTIAL, 'prefer the configured legacy service-role credential');
  assert.ok(serverKey(env) === RUNTIME_CREDENTIAL, 'use the default runtime API key when no legacy credential exists');
  for (const SUPABASE_SECRET_KEYS of ['invalid JSON', '{}', '{"default":123}', '{"default":""}']) {
    assert.ok(serverKey({ SUPABASE_SECRET_KEYS, SUPABASE_SERVICE_ROLE_KEY: LEGACY_CREDENTIAL }) === LEGACY_CREDENTIAL, 'a malformed optional key collection must not override the legacy credential');
  }
  assert.equal(serverKey({ SUPABASE_SECRET_KEYS: 'invalid JSON' }), '');
  assert.equal(serverKey({}), '');
});

test('bounds declared and actual UTF-8 body size before parsing or RPC calls', async () => {
  const { handler, calls } = fixture();
  const declared = await handler(request(inquiry(), { headers: { 'Content-Length': '16385' } }));
  assert.equal(declared.status, 413);
  const actual = await handler(request(inquiry({ note: 'é'.repeat(9000) })));
  assert.equal(actual.status, 413);
  const bytes = new TextEncoder().encode('x'.repeat(16385));
  const streamed = new Request(ENDPOINT, { method: 'POST', headers: { Origin: 'https://ourport.us', 'Content-Type': 'application/json' }, duplex: 'half', body: new ReadableStream({ start(controller) { controller.enqueue(bytes.subarray(0, 10000)); controller.enqueue(bytes.subarray(10000)); controller.close(); } }) });
  assert.equal((await handler(streamed)).status, 413);
  assert.equal(calls.length, 0);
});

test('rejects missing, malformed and non-object JSON without RPC calls', async () => {
  for (const raw of [undefined, '{', 'null', '[]', 'true']) {
    const { handler, calls } = fixture();
    const response = await handler(request(undefined, { raw }));
    assert.equal(response.status, 400);
    assert.equal(calls.length, 0);
  }
});

test('rejects honeypots, unknown fields and mixed project-role fields', async () => {
  for (const input of [
    inquiry({ website: 'https://spam.example' }), inquiry({ website: ' ' }), inquiry({ website: false }),
    inquiry({ status: 'qualified' }), inquiry({ residentId: 'private-resident-data' }),
    inquiry({ role: 'laundromat', homesOrBeds: 200 }), inquiry({ role: 'housing', dashboard: 'Wrong branch' }),
    inquiry({ role: 'builder', providerStatus: 'Already selected' }), inquiry({ role: '__proto__' }),
  ]) {
    const { handler, calls } = fixture();
    assert.equal((await handler(request(input))).status, 400);
    assert.equal(calls.length, 0);
  }
});

test('requires strictly typed UUID, edit token and revision values', () => {
  for (const overrides of [
    { requestId: 'not-a-uuid' }, { requestId: [REQUEST_ID] }, { editToken: [EDIT_TOKEN] },
    { editToken: 'b'.repeat(63) }, { editToken: 'Z'.repeat(64) },
    { revision: '1' }, { revision: 0 }, { revision: 1.5 }, { revision: 100001 },
  ]) assert.throws(() => normalizeInput(inquiry(overrides)));
});

test('normalizes all three roles and fixes the source path instead of trusting the browser', () => {
  const cases = [
    { role: 'laundromat', dashboard: 'Current POS', bagSize: '24 × 18 inches', processingHours: '9–5', accessHours: '7–9' },
    { role: 'housing', providerStatus: 'In discussion', residentSystem: 'Resident app', homesOrBeds: '240' },
    { role: 'builder', siteStage: 'Design development', wallDimensions: '10 feet', siteConstraints: 'Power review needed' },
  ];
  for (const branch of cases) {
    const normalized = normalizeInput(inquiry({ ...branch, contactName: '  Unit Test  ', email: ' TEST@EXAMPLE.COM ', location: '  Tucson, AZ ', locationCount: '2', sourcePath: 'https://evil.example/not-the-form' }));
    assert.equal(normalized.record.role, branch.role);
    assert.equal(normalized.record.contact_name, 'Unit Test');
    assert.equal(normalized.record.contact_email, 'test@example.com');
    assert.equal(normalized.record.location, 'Tucson, AZ');
    assert.equal(normalized.record.location_count, 2);
    assert.equal(normalized.record.details.sourcePath, '/plan-a-site/');
    assert.ok(normalized.editToken === EDIT_TOKEN, 'keep the edit token in the RPC envelope');
    assert.equal(Object.hasOwn(normalized.record, 'edit_token'), false);
    if (branch.role === 'housing') assert.equal(normalized.record.details.homesOrBeds, 240);
    for (const [key, value] of Object.entries(branch)) if (!['role', 'homesOrBeds'].includes(key)) assert.equal(normalized.record.details[key], value);
  }
});

test('requires explicit progress consent for partial drafts and valid email for every save', () => {
  const draft = normalizeInput(inquiry({ stage: 'draft', progressConsent: true, contactName: '', location: '' }));
  assert.equal(draft.record.stage, 'draft');
  assert.equal(draft.record.contact_name, null);
  assert.equal(draft.record.location, null);
  for (const overrides of [
    { stage: 'draft', progressConsent: false }, { stage: 'draft', progressConsent: undefined },
    { stage: 'draft', progressConsent: 'true' }, { progressConsent: undefined },
    { stage: 'draft', progressConsent: true, email: '' }, { email: 'bad address' },
    { contactName: ' ' }, { location: ' ' },
  ]) assert.throws(() => normalizeInput(inquiry(overrides)));
  assert.equal(normalizeInput(inquiry({ progressConsent: false })).record.stage, 'submitted');
});

test('enforces string lengths, control-character rejection, numeric bounds and listed options', () => {
  for (const overrides of [
    { contactName: 'x'.repeat(121) }, { projectName: 'x'.repeat(181) }, { note: 'x'.repeat(2001) },
    { bagSize: 'x'.repeat(301) }, { role: 'housing', residentSystem: 'x'.repeat(181) },
    { role: 'builder', siteConstraints: 'x'.repeat(1001) }, { note: { html: '<script>' } }, { note: 'bad\u0001value' },
    { locationCount: 0 }, { locationCount: 10001 }, { locationCount: 1.5 }, { locationCount: true },
    { role: 'housing', homesOrBeds: 100001 }, { role: 'housing', homesOrBeds: '1.5' },
    { currentService: 'Unlisted option' }, { role: 'housing', providerStatus: 'Unlisted option' },
    { role: 'builder', siteStage: 'Unlisted option' },
  ]) assert.throws(() => normalizeInput(inquiry(overrides)));
});

test('writes only the normalized RPC envelope and never forwards browser credentials', async () => {
  const { handler, calls } = fixture();
  const response = await handler(request(inquiry(), { headers: { Authorization: 'Bearer synthetic-browser-token', Cookie: 'session=synthetic-browser-cookie', 'x-forwarded-for': '192.0.2.4' } }));
  assert.equal(response.status, 201);
  assertSafeHeaders(response);
  assert.equal(calls.length, 1);
  const call = calls[0];
  assert.equal(call.url, PROJECT + '/rest/v1/rpc/ourport_submit_site_inquiry');
  assert.equal(call.options.method, 'POST');
  assert.ok(call.options.headers.apikey === RUNTIME_CREDENTIAL, 'RPC uses the runtime API key');
  assert.equal(Object.hasOwn(call.options.headers, 'Authorization'), false, 'an opaque runtime API key must not be sent as a Bearer JWT');
  assert.equal(Object.hasOwn(call.options.headers, 'Cookie'), false);
  assert.equal(Object.hasOwn(call.options, 'credentials'), false);
  assert.deepEqual(Object.keys(call.payload).sort(), ['p_edit_token', 'p_rate_key', 'p_record']);
  assert.match(call.payload.p_rate_key, /^[0-9a-f]{64}$/);
  assert.ok(!call.payload.p_rate_key.includes('192.0.2.4'), 'do not store a raw network address');
  assert.ok(call.payload.p_edit_token === EDIT_TOKEN, 'forward the edit token only to the privileged RPC');
  assert.ok(!JSON.stringify(call.payload.p_record).includes(EDIT_TOKEN), 'exclude the edit token from the saved record');
  const output = await response.text();
  assert.ok(!output.includes(RUNTIME_CREDENTIAL), 'never expose runtime credentials');
  assert.ok(!output.includes(EDIT_TOKEN), 'never echo the edit token');
});

test('uses legacy JWT authentication when configured without forwarding browser credentials', async () => {
  const { handler, calls } = fixture(receipt(), { environment: { ...env, SUPABASE_SERVICE_ROLE_KEY: LEGACY_CREDENTIAL } });
  const response = await handler(request(inquiry(), { headers: { Authorization: 'Bearer synthetic-browser-token', Cookie: 'session=synthetic-browser-cookie' } }));
  assert.equal(response.status, 201);
  assertSafeHeaders(response);
  assert.ok(calls[0].options.headers.apikey === LEGACY_CREDENTIAL, 'use the selected legacy runtime credential as the API key');
  assert.ok(calls[0].options.headers.Authorization === 'Bearer ' + LEGACY_CREDENTIAL, 'the runtime JWT may authenticate the privileged RPC');
  assert.equal(Object.hasOwn(calls[0].options.headers, 'Cookie'), false);
  const output = await response.text();
  assert.ok(!output.includes(LEGACY_CREDENTIAL) && !output.includes(RUNTIME_CREDENTIAL), 'never expose either configured runtime credential');
});

test('forwards stable request ID, revision and token for retries and revision updates', async () => {
  const calls = [];
  const handler = createIntakeHandler({ env, fetcher: async (url, options) => {
    const payload = JSON.parse(options.body); calls.push(payload);
    return Response.json(receipt({ revision: payload.p_record.revision, stage: payload.p_record.stage }));
  } });
  for (const revision of [1, 1, 2]) assert.equal((await handler(request(inquiry({ stage: 'draft', progressConsent: true, revision })))).status, 201);
  assert.deepEqual(calls[0], calls[1], 'an identical retry must reach SQL with an identical idempotency envelope');
  assert.equal(calls[2].p_record.request_id, REQUEST_ID);
  assert.equal(calls[2].p_record.revision, 2);
  assert.ok(calls.every(call => call.p_edit_token === EDIT_TOKEN), 'retain the token across revisions');
});

test('reports success only for a valid receipt matching the saved stage and revision', async () => {
  for (const invalid of [null, true, {}, receipt({ id: 'not-a-uuid' }), receipt({ created_at: 'not-a-date' }), receipt({ revision: 2 }), receipt({ revision: '1' }), receipt({ stage: 'draft' })]) {
    const { handler } = fixture(invalid);
    const response = await handler(request(inquiry()));
    assert.equal(response.status, 502);
    assert.notEqual((await response.json()).ok, true);
  }
  const malformed = fixture(new Response('not JSON', { status: 200 }));
  assert.equal((await malformed.handler(request(inquiry()))).status, 502);
  const { handler } = fixture();
  const success = await handler(request(inquiry()));
  assert.deepEqual(await success.json(), { ok: true, receipt: receipt(), notifications: 'queued' });
});

test('returns only public receipt fields even if the RPC includes internal fields', async () => {
  const { handler } = fixture(receipt({ internal_note: RUNTIME_CREDENTIAL, contact_email: 'private@example.com', edit_token_hash: 'b'.repeat(64) }));
  const response = await handler(request(inquiry()));
  assert.equal(response.status, 201);
  const output = await response.text();
  assert.ok(!output.includes(RUNTIME_CREDENTIAL), 'never expose runtime or upstream private values');
  const data = JSON.parse(output);
  assert.deepEqual(Object.keys(data.receipt).sort(), ['created_at', 'id', 'revision', 'stage']);
});

test('maps rate, conflict and validation failures without returning database error details', async () => {
  for (const [code, message, expected] of [['P0001', 'rate_limit', 429], ['23505', 'request_id_conflict', 409], ['40001', 'retry_conflict', 409], ['22023', 'invalid_inquiry', 400], ['XX000', RUNTIME_CREDENTIAL, 502]]) {
    const { handler } = fixture({ code, message, details: RUNTIME_CREDENTIAL }, { status: 400 });
    const response = await handler(request(inquiry()));
    assert.equal(response.status, expected);
    assertSafeHeaders(response);
    if (expected === 429) assert.equal(response.headers.get('Retry-After'), '900');
    assert.ok(!(await response.text()).includes(RUNTIME_CREDENTIAL), 'database errors must not expose private details');
  }
});

test('reports storage/network failure honestly and preserves a generic response', async () => {
  const { handler } = fixture(null, { fetchError: new Error(RUNTIME_CREDENTIAL) });
  const response = await handler(request(inquiry()));
  assert.equal(response.status, 502);
  const output = await response.text();
  assert.ok(!output.includes(RUNTIME_CREDENTIAL), 'network errors must not expose private details');
  assert.match(JSON.parse(output).error, /could not confirm receipt/i);
});

test('withdraws progress using the SQL object receipt without an inquiry payload', async () => {
  const { handler, calls } = fixture({ withdrawn: true });
  const response = await handler(request({ stage: 'withdraw', requestId: REQUEST_ID, editToken: EDIT_TOKEN }));
  assert.equal(response.status, 200);
  assertSafeHeaders(response);
  assert.deepEqual(await response.json(), { ok: true, withdrawn: true });
  assert.equal(calls[0].url, PROJECT + '/rest/v1/rpc/ourport_withdraw_draft_progress');
  assert.deepEqual(Object.keys(calls[0].payload).sort(), ['p_edit_token', 'p_request_id']);
  assert.equal(calls[0].payload.p_request_id, REQUEST_ID);
  assert.ok(calls[0].payload.p_edit_token === EDIT_TOKEN, 'withdrawal must require the edit capability');
});

test('preserves a negative SQL withdrawal result without claiming that progress was paused', async () => {
  const { handler } = fixture({ withdrawn: false });
  const response = await handler(request({ stage: 'withdraw', requestId: REQUEST_ID, editToken: EDIT_TOKEN }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, withdrawn: false });
});

test('rejects malformed withdrawal receipts, unknown fields and invalid tokens', async () => {
  for (const reply of [true, false, null, {}, { withdrawn: 'true' }]) {
    const { handler } = fixture(reply);
    const response = await handler(request({ stage: 'withdraw', requestId: REQUEST_ID, editToken: EDIT_TOKEN }));
    assert.equal(response.status, 502);
  }
  for (const overrides of [{ email: 'test@example.com' }, { editToken: '' }, { requestId: 'not-a-uuid' }]) {
    const { handler, calls } = fixture({ withdrawn: true });
    assert.equal((await handler(request({ stage: 'withdraw', requestId: REQUEST_ID, editToken: EDIT_TOKEN, ...overrides }))).status, 400);
    assert.equal(calls.length, 0);
  }
});
