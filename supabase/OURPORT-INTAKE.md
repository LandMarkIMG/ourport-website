# OurPort intake database

Target: the existing **monetize-that-portal** Supabase project, `xpdnhfgfbgcunlmuyjrx`. Apply `migrations/202611150001_ourport_intake.sql` only there. It creates new OurPort objects and does not change portal tables, accounts, grants or workflows.

## Data points and stages

`public.ourport_site_inquiries` stores receipt/request IDs, creation/update times, capture stage, monotonic revision, progress-sharing consent, project type, contact name/email, optional project name, city/state, optional location count, active-branch details and review status (`draft`, `new`, `contacted`, `qualified`, `closed`). Hash columns support safe retries and anonymous draft ownership; raw edit tokens are never stored or returned.

Details accept only:

- Shared: current laundry service, the visitor's note and the fixed source path `/plan-a-site/`.
- Laundromat: order system, staffed processing hours, customer access hours, bag/finished-order size.
- Housing: homes/beds count, provider status and resident/access system.
- Builder: project stage, possible wall dimensions and site constraints.

A draft requires a valid email, role and explicit progress-sharing consent. Name and location may be missing until submission. Submitted inquiries require name, email and location. Unknown fields, inactive-branch fields, invalid enum values and out-of-range numbers are rejected. Do not collect resident identities, laundry orders, payment details or uploaded files here.

## Access and retry contracts

RLS is enabled. `PUBLIC`, `anon` and `authenticated` have no table permissions or RPC execution. Company database administrators review/update inquiries through the existing Supabase dashboard; this release does not grant portal roles access or add a portal inbox.

Only server-side code calls these RPCs:

- `ourport_submit_site_inquiry(p_record jsonb, p_rate_key text, p_edit_token text)` returns `{id, created_at, stage, revision}`. The record includes `stage: draft|submitted`, positive integer `revision` and boolean `progress_consent` alongside the validated inquiry fields.
- `ourport_withdraw_draft_progress(p_request_id uuid, p_edit_token text)` returns `{withdrawn: boolean}`. It stops pending draft notices and further progress sharing without capturing new fields. It does not erase already-shared details, sent notices or completed submissions.
- `ourport_claim_inquiry_notifications(p_limit integer default 10)` returns an array of `{notification_id, kind, lease_token, recipients, inquiry}`. The inquiry contains business fields and timestamps; hash columns are excluded.
- `ourport_finish_inquiry_notification(p_notification_id uuid, p_lease_token uuid, p_sent boolean, p_provider_id text|null)` returns a boolean. A stale/cancelled lease cannot complete.

The browser generates a 32-byte random edit token encoded as 64 lowercase hex characters. Every update requires the same token and normalized email. Only SHA256 of the token is stored. Network buckets may change as visitors move between networks; the edit token is the ownership capability. Exact same-revision/payload retries return the existing receipt. Changed or stale revisions raise `23505`. Draft revisions must increase. Submitted records are immutable through intake.

On opt-out, the frontend must finish/cancel an in-flight progress save before calling withdrawal; otherwise a not-yet-created draft cannot be cancelled. Resuming sharing requires a newer revision. Keep privileged keys and edit tokens out of logs and build artifacts.

## Quotas and notification outbox

New request IDs consume fixed windows atomically: five per hashed-network bucket per 15 minutes, five per normalized email per UTC day and 200 globally per UTC day. Existing draft updates use a separate 60/hour allowance, with one final-submit slot reserved. Network buckets are best-effort proxy signals; email/global limits remain authoritative. The private counter table contains hashes/counts, never raw IP addresses. Expired buckets are removed on the next intake, so idle periods delay physical cleanup. Inquiry records are retained for manual staff review; no automatic inquiry deletion policy is introduced.

`ourport_private.inquiry_notifications` contains at most one draft and one submitted event per inquiry. Recipients are fixed to **mike@monetize-that.com** and **Joe@monetize-that.com**; visitors cannot set them. Pending draft notices coalesce to the latest details and become due 90 seconds after the last save. Submitting cancels unsent draft notices and queues the submitted summary immediately. Withdrawing progress cancels unsent draft notices. Already-sent notices are retained. A claim racing an already-started provider send cannot retract that email.

Claims use five-minute leases and at most 10 attempts. Failed attempts retry after five minutes. A provider idempotency key must derive from `notification_id`, so lease recovery cannot duplicate an accepted email. Claiming/finishing SQL itself sends no email. Dispatch remains inactive until a provider and scheduled worker are configured.

## Verification

Run `tests/ourport_intake.sql` as a database administrator after applying the migration and **before enabling notification dispatch**. It verifies grants, all three submitted role shapes, consented draft minimums, ownership, monotonic revisions, retry identity, final submission, opt-out, outbox coalescing/leases and all quotas. Synthetic writes, test leases and temporary counter/outbox resets occur in one transaction ending in `ROLLBACK`; no email provider is invoked. The script briefly serializes intake while its checks run.

The verification also reports whether `pg_cron`, `pg_net` and `supabase_vault` are installed. It does not install extensions or activate a schedule. Source files are not proof of live deployment: record actual migration and rollback-test results separately before enabling online intake.

References: [PostgreSQL function security](https://www.postgresql.org/docs/current/sql-createfunction.html), [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).

## Email dispatch deployment

`migrations/202611150002_ourport_notifications.sql` adds a database-owned dispatcher using `pg_net`, `pg_cron` and Supabase Vault. Applying that migration creates functions/tables but does **not** schedule a job or call Resend. Existing cron jobs are untouched. Queued requests contain a provider authorization header and inquiry text. The migration attempts restrictive `pg_net` revokes, but hosted Supabase owns those grants as `supabase_admin`; project `postgres` can receive a no-op warning. Do not treat those statements as proof that the platform ACL changed. The supported boundary is that `net` is excluded from the Data API, client roles cannot log in to Postgres, and app-owned notification helpers/bridges are not executable by client roles.

Provision these secrets through the trusted administrative setup, without committing or printing values:

- `ourport_resend_api_key`: the Resend key scoped to the verified sending domain where supported.
- `ourport_email_from`: exactly `OurPort <inquiries@notify.ourport.us>`.

Verify the sending domain in Resend before activation. Tracking should remain off for these transactional summaries. `inquiry_notification_configuration_ready()` reports a boolean only; it checks key shape and the exact sender, not external DNS/provider verification.

Run `tests/ourport_notifications.sql` after migration002 and before activation. It creates synthetic HTTP responses inside a rollback-only transaction, testing private access, human-readable payloads, fixed recipients, sanitized subjects, validated reply-to and response acknowledgement. It does not invoke `net.http_post`, create a cron schedule or contact any provider. Run `tests/ourport_notifications_isolation.sql` for owner/ACL, NOLOGIN roles, app-owned helper grants and exposed-schema metadata. Complete its external anonymous REST checks: profiles selecting `net` must be rejected with `406 PGRST106`. A zero-row PostgreSQL schema-setting query alone is not proof of API isolation. The rollback suite continues to enforce all app-owned private table/function denials and rejects any client-executable SECURITY DEFINER bridge into `net` or the private dispatcher. Execute `tests/ourport_notifications_status.sql` for operational metadata without secrets or message bodies.

Only after the provider/domain and Vault configuration are verified, run `activate-notifications.sql`. It starts the single database cron job **ourport-notifications** every minute. It refuses activation with missing credentials/sender and refuses to overwrite a different command using that name. Pausing this specific integration can be done by setting only that job's `active` flag to false in the Supabase Cron dashboard; no other jobs need changes.

The worker first collects its own asynchronous HTTP responses, then claims up to 10 due notices. It sends plain text to Mike/Joe, with the visitor's validated email as Reply-To. It acknowledges a notice only after a 2xx response containing a valid Resend UUID. A timeout, malformed response, absent response or provider error never counts as receipt. `pg_net` starts HTTP only after transaction commit; status collection normally happens on the next minute tick.

The first actual send freezes the email body privately so every retry under `Idempotency-Key: ourport-{notification_id}` is identical. An accepted provider receipt can complete a renewed lease without another HTTP request. Resend's idempotency window is 24 hours, so ambiguous automatic retries stop conservatively after 23 hours. Such records are marked `needs_review` in private delivery metadata and their outbox event is cancelled to prevent a late duplicate. A staff member must inspect the provider before manually retrying them. Up to 10 leased attempts are otherwise allowed; exhausted events remain visible in the status query.

HTTP attempt metadata is purged after two days. Frozen message copies are cleared after two days while first-attempt time/provider acknowledgement metadata remains, preventing a long outage from resetting the deduplication clock. Inquiry/outbox records are retained for staff review. `pg_net`'s own response table follows the extension's normal retention; only this integration's attempt metadata and expired OurPort counters are cleaned by the worker.

A provider-accepted send is not proof of mailbox delivery. Record an actual live submitted and consented unfinished test separately, including provider receipt/delivery evidence, before declaring notifications verified.

References: [Supabase pg_net](https://supabase.com/docs/guides/database/extensions/pg_net), [Supabase Vault](https://supabase.com/docs/guides/database/vault), [Resend send-email API](https://resend.com/docs/api-reference/emails/send-email), [Resend idempotency](https://resend.com/docs/dashboard/emails/idempotency-keys).
