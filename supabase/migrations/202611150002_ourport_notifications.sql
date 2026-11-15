-- Shared company project xpdnhfgfbgcunlmuyjrx. This migration DOES NOT schedule
-- or send mail. Activation is a separate, secret-checked operation.
begin;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
-- Vault is already provisioned by Supabase; fail rather than invent a secret.
do $$ begin
  if to_regclass('vault.decrypted_secrets') is null then raise exception 'Supabase Vault is required'; end if;
end $$;

-- Outbound HTTP queues contain authorization headers and inquiry content.
-- Best-effort revokes: on hosted Supabase, supabase_admin owns these grants
-- and project postgres can receive a no-op warning. Isolation is verified via
-- NOLOGIN client roles, net's API-schema exclusion and closed app-owned RPCs.
revoke all on net.http_request_queue, net._http_response from public, anon, authenticated;
revoke all on function net.http_post(text,jsonb,jsonb,jsonb,integer) from public, anon, authenticated;

create table ourport_private.notification_deliveries (
  notification_id uuid primary key references ourport_private.inquiry_notifications(id) on delete cascade,
  first_attempt_at timestamptz not null default clock_timestamp(),
  payload jsonb check (payload is null or jsonb_typeof(payload) = 'object'),
  state text not null default 'pending' check (state in ('pending','accepted','needs_review')),
  provider_id text check (provider_id is null or provider_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  last_error text check (last_error is null or last_error in ('http_error','network_error','invalid_receipt','response_missing','enqueue_failed','payload_invalid','idempotency_window_expired'))
);
alter table ourport_private.notification_deliveries enable row level security;
revoke all on ourport_private.notification_deliveries from public, anon, authenticated, service_role;

create table ourport_private.notification_http_attempts (
  http_request_id bigint primary key,
  notification_id uuid not null references ourport_private.notification_deliveries(notification_id) on delete cascade,
  lease_token uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  processed_at timestamptz,
  status_code integer,
  outcome text check (outcome is null or outcome in ('accepted','failed','missing')),
  lease_completed boolean
);
create index ourport_notification_attempts_pending_idx on ourport_private.notification_http_attempts(created_at) where processed_at is null;
alter table ourport_private.notification_http_attempts enable row level security;
revoke all on ourport_private.notification_http_attempts from public, anon, authenticated, service_role;

-- Return readiness only; never return provider credentials or Vault records.
create function ourport_private.inquiry_notification_configuration_ready()
returns boolean language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare api_key text; sender text;
begin
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'ourport_resend_api_key';
  select decrypted_secret into sender from vault.decrypted_secrets where name = 'ourport_email_from';
  return coalesce(api_key ~ '^re_[A-Za-z0-9_-]{10,200}$' and sender = 'OurPort <inquiries@notify.ourport.us>',false);
end;
$$;
revoke all on function ourport_private.inquiry_notification_configuration_ready() from public, anon, authenticated, service_role;

create function ourport_private.inquiry_notification_payload(p_notice jsonb, p_sender text)
returns jsonb language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare
  q jsonb := p_notice->'inquiry'; kind_name text := p_notice->>'kind';
  email_address text := q->>'contact_email'; subject_line text; suffix text; body_text text;
  label_key text; human_label text; value_text text; role_label text;
begin
  if p_sender is distinct from 'OurPort <inquiries@notify.ourport.us>'
     or p_notice->'recipients' is distinct from '["mike@monetize-that.com","Joe@monetize-that.com"]'::jsonb
     or kind_name not in ('draft','submitted') or kind_name is null
     or jsonb_typeof(q) is distinct from 'object'
     or email_address is null or length(email_address) > 254
     or email_address !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception using errcode = '22023', message = 'invalid_notification_payload';
  end if;
  role_label := case q->>'role' when 'laundromat' then 'Laundromat' when 'housing' then 'Apartment / student housing' when 'builder' then 'Builder / developer' else null end;
  if role_label is null then raise exception using errcode = '22023', message = 'invalid_notification_payload'; end if;
  suffix := left(regexp_replace(coalesce(nullif(q->>'project_name',''),nullif(q->>'location',''),''),'[[:cntrl:]]',' ','g'),80);
  subject_line := case when kind_name = 'draft' then 'OurPort unfinished inquiry' else 'OurPort inquiry' end;
  if length(suffix) > 0 then subject_line := subject_line || ' — ' || suffix; end if;
  body_text := case when kind_name = 'draft'
    then 'The visitor chose to share their progress. This is an unfinished inquiry, not a completed submission.'
    else 'A visitor submitted an OurPort site inquiry.' end;
  body_text := body_text || E'\n\nProject type: ' || role_label || E'\nContact: ' || coalesce(nullif(q->>'contact_name',''),'Not provided')
    || E'\nEmail: ' || email_address || E'\nProject: ' || coalesce(nullif(q->>'project_name',''),'Not provided')
    || E'\nCity / state: ' || coalesce(nullif(q->>'location',''),'Not provided');
  if q->>'location_count' is not null then body_text := body_text || E'\nLocations: ' || (q->>'location_count'); end if;
  for label_key, human_label in select * from (values
    ('currentService','Current laundry service'),('note','Visitor plans'),('dashboard','Current order system'),
    ('processingHours','Staffed processing hours'),('accessHours','Customer access hours'),('bagSize','Bag / finished-order size'),
    ('homesOrBeds','Homes / student beds'),('providerStatus','Laundry provider'),('residentSystem','Resident / access system'),
    ('siteStage','Project stage'),('wallDimensions','Possible wall dimensions'),('siteConstraints','Site considerations')) as labels(k,label) loop
    value_text := q->'details'->>label_key;
    if value_text is not null and length(value_text) > 0 then body_text := body_text || E'\n\n' || human_label || E':\n' || value_text; end if;
  end loop;
  body_text := body_text || E'\n\nLast shared: ' || coalesce(q->>'updated_at',q->>'created_at','Not recorded')
    || E'\nReference: ' || coalesce(q->>'id','Not recorded') || E'\nSource: https://ourport.us/plan-a-site/'
    || E'\n\nReply to this email to contact the visitor. Review saved inquiries in the company Supabase dashboard.';
  return jsonb_build_object('from',p_sender,'to',p_notice->'recipients','reply_to',email_address,'subject',subject_line,'text',body_text);
end;
$$;
revoke all on function ourport_private.inquiry_notification_payload(jsonb,text) from public, anon, authenticated, service_role;

-- Process only HTTP responses owned by this integration. Successful HTTP alone
-- is insufficient: require a well-formed Resend receipt before acknowledging.
create function ourport_private.collect_inquiry_notification_responses()
returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare item record; parsed jsonb; receipt_id text; success boolean; completed boolean;
  count_done integer := 0; count_accepted integer := 0; count_failed integer := 0; failure_kind text;
begin
  for item in
    select a.*,r.id as response_id,r.status_code as response_status,r.content,r.timed_out,r.error_msg
    from ourport_private.notification_http_attempts a left join net._http_response r on r.id = a.http_request_id
    where a.processed_at is null and (r.id is not null or a.created_at < clock_timestamp()-interval '4 minutes')
    order by a.created_at limit 100 for update of a skip locked
  loop
    receipt_id := null; parsed := null; success := false;
    failure_kind := case when item.response_id is null then 'response_missing'
      when coalesce(item.timed_out,false) or item.error_msg is not null then 'network_error'
      when item.response_status not between 200 and 299 or item.response_status is null then 'http_error'
      else 'invalid_receipt' end;
    if item.response_status between 200 and 299 and not coalesce(item.timed_out,false) and item.error_msg is null then
      begin parsed := item.content::jsonb; exception when others then parsed := null; end;
      if jsonb_typeof(parsed) = 'object' and jsonb_typeof(parsed->'id') = 'string'
         and parsed->>'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        receipt_id := parsed->>'id'; success := true;
      end if;
    end if;
    if success then
      update ourport_private.notification_deliveries set state = 'accepted',provider_id = receipt_id,last_error = null where notification_id = item.notification_id;
      completed := public.ourport_finish_inquiry_notification(item.notification_id,item.lease_token,true,receipt_id);
      count_accepted := count_accepted + 1;
    else
      update ourport_private.notification_deliveries set last_error = failure_kind where notification_id = item.notification_id and state <> 'accepted';
      completed := public.ourport_finish_inquiry_notification(item.notification_id,item.lease_token,false,null);
      count_failed := count_failed + 1;
    end if;
    update ourport_private.notification_http_attempts set processed_at = clock_timestamp(),status_code = item.response_status,
      outcome = case when success then 'accepted' when item.response_id is null then 'missing' else 'failed' end,
      lease_completed = completed where http_request_id = item.http_request_id;
    count_done := count_done + 1;
  end loop;
  return jsonb_build_object('collected',count_done,'accepted',count_accepted,'failed',count_failed);
end;
$$;
revoke all on function ourport_private.collect_inquiry_notification_responses() from public, anon, authenticated, service_role;

create function ourport_private.dispatch_inquiry_notifications()
returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare
  totals jsonb; api_key text; sender text; notices jsonb; notice jsonb; mail_body jsonb;
  delivery ourport_private.notification_deliveries%rowtype; notice_id uuid; lease_id uuid; request_number bigint;
  count_queued integer := 0; count_recovered integer := 0; count_held integer := 0; count_failed integer := 0;
begin
  -- A second invocation never overlaps this worker or spends another lease.
  if not pg_try_advisory_xact_lock(750032611150002::bigint) then return jsonb_build_object('status','busy','queued',0); end if;
  totals := ourport_private.collect_inquiry_notification_responses();
  delete from ourport_private.notification_http_attempts where created_at < clock_timestamp()-interval '2 days';
  update ourport_private.notification_deliveries set payload = null where payload is not null and first_attempt_at < clock_timestamp()-interval '2 days';
  delete from ourport_private.intake_limits where expires_at <= clock_timestamp();
  if not ourport_private.inquiry_notification_configuration_ready() then return totals || jsonb_build_object('status','unconfigured','queued',0); end if;
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'ourport_resend_api_key';
  select decrypted_secret into sender from vault.decrypted_secrets where name = 'ourport_email_from';
  if not coalesce(api_key ~ '^re_[A-Za-z0-9_-]{10,200}$' and sender = 'OurPort <inquiries@notify.ourport.us>',false) then
    return totals || jsonb_build_object('status','unconfigured','queued',0);
  end if;
  notices := public.ourport_claim_inquiry_notifications(10);
  for notice in select value from jsonb_array_elements(notices) loop
    notice_id := (notice->>'notification_id')::uuid; lease_id := (notice->>'lease_token')::uuid;
    select * into delivery from ourport_private.notification_deliveries where notification_id = notice_id;
    if found and delivery.state = 'accepted' and delivery.provider_id is not null then
      perform public.ourport_finish_inquiry_notification(notice_id,lease_id,true,delivery.provider_id);
      count_recovered := count_recovered + 1;
      continue;
    end if;
    if found and (delivery.state = 'needs_review' or delivery.first_attempt_at < clock_timestamp()-interval '23 hours' or delivery.payload is null) then
      update ourport_private.notification_deliveries set state = 'needs_review',last_error = 'idempotency_window_expired' where notification_id = notice_id;
      update ourport_private.inquiry_notifications set state = 'cancelled',lease_token = null,lease_expires_at = null
        where id = notice_id and state = 'sending' and lease_token = lease_id;
      count_held := count_held + 1;
      continue;
    end if;
    begin
      if delivery.notification_id is null then
        mail_body := ourport_private.inquiry_notification_payload(notice,sender);
        insert into ourport_private.notification_deliveries(notification_id,payload) values(notice_id,mail_body) returning * into delivery;
      else
        mail_body := delivery.payload;
      end if;
      -- Body is frozen at first attempt because Resend idempotency requires
      -- identical content. No key or raw edit/network token enters stored mail.
      request_number := net.http_post(url := 'https://api.resend.com/emails',body := mail_body,
        headers := jsonb_build_object('Authorization','Bearer '||api_key,'Content-Type','application/json','Idempotency-Key','ourport-'||notice_id::text),
        timeout_milliseconds := 10000);
      insert into ourport_private.notification_http_attempts(http_request_id,notification_id,lease_token) values(request_number,notice_id,lease_id);
      count_queued := count_queued + 1;
    exception when others then
      -- Return only safe categories; never interpolate SQLERRM/provider bodies.
      perform public.ourport_finish_inquiry_notification(notice_id,lease_id,false,null);
      update ourport_private.notification_deliveries set last_error = 'enqueue_failed' where notification_id = notice_id and state <> 'accepted';
      count_failed := count_failed + 1;
    end;
  end loop;
  return totals || jsonb_build_object('status','ready','queued',count_queued,'recovered',count_recovered,'held',count_held,'enqueue_failed',count_failed);
end;
$$;
revoke all on function ourport_private.dispatch_inquiry_notifications() from public, anon, authenticated, service_role;
commit;
