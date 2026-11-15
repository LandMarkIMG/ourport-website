-- Apply only to the shared company project xpdnhfgfbgcunlmuyjrx.
-- New OurPort objects only. Browser/portal roles receive no direct access.
begin;
create schema if not exists ourport_private;
revoke all on schema ourport_private from public, anon, authenticated;

create table public.ourport_site_inquiries (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  stage text not null check (stage in ('draft','submitted')),
  revision integer not null check (revision between 1 and 1000000),
  progress_consent boolean not null default false,
  role text not null check (role in ('laundromat','housing','builder')),
  contact_name text check (contact_name is null or length(btrim(contact_name)) between 1 and 120),
  contact_email text not null check (length(contact_email) between 3 and 254),
  project_name text check (length(project_name) <= 180),
  location text check (location is null or length(btrim(location)) between 1 and 180),
  location_count integer check (location_count between 1 and 10000),
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  edit_token_hash text not null check (edit_token_hash ~ '^[0-9a-f]{64}$'),
  status text not null check (status in ('draft','new','contacted','qualified','closed')),
  check ((stage = 'draft' and status = 'draft') or
    (stage = 'submitted' and status <> 'draft' and contact_name is not null and location is not null))
);
create index ourport_site_inquiries_created_at_idx on public.ourport_site_inquiries (created_at desc);
alter table public.ourport_site_inquiries enable row level security;
revoke all on public.ourport_site_inquiries from public, anon, authenticated;
grant select, insert, update on public.ourport_site_inquiries to service_role;
comment on table public.ourport_site_inquiries is 'OurPort business inquiries and explicitly consented progress. Company database administrators review through Supabase; no public or portal-user access.';

-- Fixed UTC windows; hashes/counts only, never raw network addresses.
create table ourport_private.intake_limits (
  bucket_key text not null,
  window_start timestamptz not null,
  expires_at timestamptz not null,
  attempts integer not null check (attempts between 1 and 200),
  primary key (bucket_key, window_start)
);
alter table ourport_private.intake_limits enable row level security;
revoke all on ourport_private.intake_limits from public, anon, authenticated;

create table ourport_private.inquiry_notifications (
  id uuid primary key default gen_random_uuid(),
  inquiry_id uuid not null references public.ourport_site_inquiries(id) on delete cascade,
  kind text not null check (kind in ('draft','submitted')),
  recipients text[] not null default array['mike@monetize-that.com','Joe@monetize-that.com']
    check (recipients = array['mike@monetize-that.com','Joe@monetize-that.com']),
  state text not null default 'pending' check (state in ('pending','sending','sent','cancelled')),
  available_at timestamptz not null,
  created_at timestamptz not null default now(),
  lease_token uuid,
  lease_expires_at timestamptz,
  attempts integer not null default 0 check (attempts between 0 and 10),
  sent_at timestamptz,
  provider_id text check (length(provider_id) <= 200),
  unique (inquiry_id, kind)
);
create index ourport_inquiry_notifications_due_idx on ourport_private.inquiry_notifications (available_at) where state in ('pending','sending');
alter table ourport_private.inquiry_notifications enable row level security;
revoke all on ourport_private.inquiry_notifications from public, anon, authenticated;

create function public.ourport_submit_site_inquiry(p_record jsonb, p_rate_key text, p_edit_token text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare
  k text; v jsonb; max_length integer; role_name text; stage_name text; new_revision integer;
  detail_limits jsonb; clean_details jsonb := '{}'::jsonb; clean_record jsonb;
  fingerprint text; token_hash text; prior public.ourport_site_inquiries%rowtype;
  saved public.ourport_site_inquiries%rowtype; record_id uuid; location_count_value integer;
  v_now timestamptz := clock_timestamp(); quarter_start timestamptz; hour_start timestamptz; day_start timestamptz;
  bucket_keys text[]; bucket_starts timestamptz[]; bucket_ends timestamptz[];
  bucket_caps integer[]; i integer; used integer; is_existing boolean;
begin
  if p_record is null or jsonb_typeof(p_record) <> 'object' or octet_length(p_record::text) > 16384
     or p_rate_key is null or p_rate_key !~ '^[0-9a-f]{64}$'
     or p_edit_token is null or p_edit_token !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'invalid_inquiry';
  end if;
  for k in select jsonb_object_keys(p_record) loop
    if k <> all(array['request_id','stage','revision','progress_consent','role','contact_name','contact_email','project_name','location','location_count','details']) then
      raise exception using errcode = '22023', message = 'invalid_inquiry';
    end if;
  end loop;
  if jsonb_typeof(p_record->'request_id') is distinct from 'string'
     or p_record->>'request_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     or jsonb_typeof(p_record->'stage') is distinct from 'string' or p_record->>'stage' not in ('draft','submitted')
     or jsonb_typeof(p_record->'revision') is distinct from 'number'
     or jsonb_typeof(p_record->'progress_consent') is distinct from 'boolean'
     or jsonb_typeof(p_record->'role') is distinct from 'string' or p_record->>'role' not in ('laundromat','housing','builder')
     or jsonb_typeof(p_record->'details') is distinct from 'object' then
    raise exception using errcode = '22023', message = 'invalid_inquiry';
  end if;
  if (p_record->>'revision')::numeric not between 1 and 1000000
     or trunc((p_record->>'revision')::numeric) <> (p_record->>'revision')::numeric then
    raise exception using errcode = '22023', message = 'invalid_inquiry';
  end if;
  role_name := p_record->>'role'; stage_name := p_record->>'stage';
  new_revision := (p_record->>'revision')::numeric::integer;
  record_id := (p_record->>'request_id')::uuid;
  if stage_name = 'draft' and (p_record->>'progress_consent')::boolean is not true then
    raise exception using errcode = '22023', message = 'progress_consent_required';
  end if;
  for k, max_length in select * from (values ('contact_name',120),('contact_email',254),('project_name',180),('location',180)) as bounds(name, bound) loop
    if p_record ? k and p_record->k <> 'null'::jsonb and
       (jsonb_typeof(p_record->k) <> 'string' or length(p_record->>k) > max_length) then
      raise exception using errcode = '22023', message = 'invalid_inquiry';
    end if;
  end loop;
  if jsonb_typeof(p_record->'contact_email') is distinct from 'string'
     or length(btrim(p_record->>'contact_email')) not between 3 and 254
     or btrim(p_record->>'contact_email') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or (stage_name = 'submitted' and
       (coalesce(length(btrim(p_record->>'contact_name')),0) = 0 or coalesce(length(btrim(p_record->>'location')),0) = 0)) then
    raise exception using errcode = '22023', message = 'invalid_inquiry';
  end if;
  if p_record ? 'location_count' and p_record->'location_count' <> 'null'::jsonb then
    if jsonb_typeof(p_record->'location_count') <> 'number' then
      raise exception using errcode = '22023', message = 'invalid_inquiry';
    end if;
    if (p_record->>'location_count')::numeric not between 1 and 10000
       or trunc((p_record->>'location_count')::numeric) <> (p_record->>'location_count')::numeric then
      raise exception using errcode = '22023', message = 'invalid_inquiry';
    end if;
    location_count_value := (p_record->>'location_count')::numeric::integer;
  end if;
  detail_limits := '{"currentService":180,"note":2000,"sourcePath":180}'::jsonb || case role_name
    when 'laundromat' then '{"dashboard":180,"processingHours":180,"accessHours":180,"bagSize":300}'::jsonb
    when 'housing' then '{"providerStatus":180,"residentSystem":180,"homesOrBeds":100000}'::jsonb
    else '{"siteStage":180,"wallDimensions":200,"siteConstraints":1000}'::jsonb end;
  for k, v in select * from jsonb_each(p_record->'details') loop
    if not detail_limits ? k then
      raise exception using errcode = '22023', message = 'invalid_inquiry';
    end if;
    if k = 'homesOrBeds' then
      if jsonb_typeof(v) <> 'number' then raise exception using errcode = '22023', message = 'invalid_inquiry'; end if;
      if (v #>> '{}')::numeric not between 1 and 100000 or trunc((v #>> '{}')::numeric) <> (v #>> '{}')::numeric then
        raise exception using errcode = '22023', message = 'invalid_inquiry';
      end if;
      clean_details := clean_details || jsonb_build_object(k, (v #>> '{}')::numeric::integer);
    else
      if jsonb_typeof(v) <> 'string' or length(v #>> '{}') > (detail_limits->>k)::integer then
        raise exception using errcode = '22023', message = 'invalid_inquiry';
      end if;
      if length(btrim(v #>> '{}')) > 0 then clean_details := clean_details || jsonb_build_object(k, btrim(v #>> '{}')); end if;
    end if;
  end loop;
  if clean_details->>'sourcePath' is distinct from '/plan-a-site/'
     or (clean_details ? 'currentService' and clean_details->>'currentService' not in ('Wash-and-fold in place','Planning wash-and-fold','Pickup and delivery','No laundry service yet'))
     or (clean_details ? 'providerStatus' and clean_details->>'providerStatus' not in ('Already selected','In discussion','Looking for a provider'))
     or (clean_details ? 'siteStage' and clean_details->>'siteStage' not in ('Early planning','Design development','Under construction','Existing-site retrofit')) then
    raise exception using errcode = '22023', message = 'invalid_inquiry';
  end if;
  clean_record := jsonb_build_object('request_id',record_id,'stage',stage_name,'revision',new_revision,
    'progress_consent',(p_record->>'progress_consent')::boolean,'role',role_name,
    'contact_name',nullif(btrim(p_record->>'contact_name'),''),'contact_email',lower(btrim(p_record->>'contact_email')),
    'project_name',nullif(btrim(p_record->>'project_name'),''),'location',nullif(btrim(p_record->>'location'),''),
    'location_count',location_count_value,'details',clean_details);
  fingerprint := encode(sha256(convert_to(clean_record::text,'UTF8')),'hex');
  token_hash := encode(sha256(convert_to(p_edit_token,'UTF8')),'hex');
  perform pg_advisory_xact_lock(750032611150001::bigint);
  select * into prior from public.ourport_site_inquiries where request_id = record_id;
  is_existing := found;
  if is_existing then
    if prior.edit_token_hash <> token_hash or prior.contact_email <> clean_record->>'contact_email' then
      raise exception using errcode = '23505', message = 'request_id_conflict';
    end if;
    if prior.revision = new_revision and prior.payload_hash = fingerprint then
      return jsonb_build_object('id',prior.id,'created_at',prior.created_at,'stage',prior.stage,'revision',prior.revision);
    end if;
    if prior.stage = 'submitted' or new_revision <= prior.revision then
      raise exception using errcode = '23505', message = 'request_id_conflict';
    end if;
  end if;
  delete from ourport_private.intake_limits where expires_at <= v_now;
  quarter_start := to_timestamp(floor(extract(epoch from v_now)/900)*900);
  hour_start := to_timestamp(floor(extract(epoch from v_now)/3600)*3600);
  day_start := date_trunc('day',v_now at time zone 'UTC') at time zone 'UTC';
  if is_existing then
    bucket_keys := array['edit:'||record_id::text]; bucket_starts := array[hour_start];
    bucket_ends := array[hour_start+interval '1 hour'];
    -- Preserve one final-submit slot after the progress-save allowance is used.
    bucket_caps := array[case when stage_name = 'submitted' then 61 else 60 end];
  else
    bucket_keys := array['ip:'||p_rate_key,'email:'||encode(sha256(convert_to(clean_record->>'contact_email','UTF8')),'hex'),'global'];
    bucket_starts := array[quarter_start,day_start,day_start];
    bucket_ends := array[quarter_start+interval '15 minutes',day_start+interval '1 day',day_start+interval '1 day'];
    bucket_caps := array[5,5,200];
  end if;
  for i in 1..array_length(bucket_keys,1) loop
    select attempts into used from ourport_private.intake_limits where bucket_key = bucket_keys[i] and window_start = bucket_starts[i];
    if coalesce(used,0) >= bucket_caps[i] then raise exception using errcode = 'P0001', message = 'rate_limit'; end if;
  end loop;
  for i in 1..array_length(bucket_keys,1) loop
    insert into ourport_private.intake_limits(bucket_key,window_start,expires_at,attempts) values(bucket_keys[i],bucket_starts[i],bucket_ends[i],1)
      on conflict(bucket_key,window_start) do update set attempts = ourport_private.intake_limits.attempts + 1;
  end loop;
  if is_existing then
    update public.ourport_site_inquiries set updated_at = v_now, stage = stage_name, revision = new_revision,
      progress_consent = (clean_record->>'progress_consent')::boolean, role = role_name, contact_name = clean_record->>'contact_name',
      project_name = clean_record->>'project_name', location = clean_record->>'location', location_count = location_count_value,
      details = clean_details, payload_hash = fingerprint, status = case when stage_name = 'draft' then 'draft' else 'new' end
      where id = prior.id returning * into saved;
  else
    insert into public.ourport_site_inquiries(request_id,stage,revision,progress_consent,role,contact_name,contact_email,project_name,location,location_count,details,payload_hash,edit_token_hash,status)
      values(record_id,stage_name,new_revision,(clean_record->>'progress_consent')::boolean,role_name,clean_record->>'contact_name',
        clean_record->>'contact_email',clean_record->>'project_name',clean_record->>'location',location_count_value,clean_details,fingerprint,token_hash,
        case when stage_name = 'draft' then 'draft' else 'new' end) returning * into saved;
  end if;
  if stage_name = 'submitted' then
    update ourport_private.inquiry_notifications set state = 'cancelled', lease_token = null, lease_expires_at = null
      where inquiry_id = saved.id and kind = 'draft' and state <> 'sent';
    insert into ourport_private.inquiry_notifications(inquiry_id,kind,available_at) values(saved.id,'submitted',v_now)
      on conflict(inquiry_id,kind) do nothing;
  else
    insert into ourport_private.inquiry_notifications(inquiry_id,kind,available_at) values(saved.id,'draft',v_now+interval '90 seconds')
      on conflict(inquiry_id,kind) do update set state = 'pending', available_at = excluded.available_at
        where ourport_private.inquiry_notifications.state in ('pending','cancelled');
  end if;
  return jsonb_build_object('id',saved.id,'created_at',saved.created_at,'stage',saved.stage,'revision',saved.revision);
end;
$$;
revoke all on function public.ourport_submit_site_inquiry(jsonb,text,text) from public, anon, authenticated;
grant execute on function public.ourport_submit_site_inquiry(jsonb,text,text) to service_role;

create function public.ourport_withdraw_draft_progress(p_request_id uuid, p_edit_token text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare target public.ourport_site_inquiries%rowtype;
begin
  if p_edit_token is null or p_edit_token !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'invalid_inquiry';
  end if;
  perform pg_advisory_xact_lock(750032611150001::bigint);
  select * into target from public.ourport_site_inquiries where request_id = p_request_id;
  if not found or target.edit_token_hash <> encode(sha256(convert_to(p_edit_token,'UTF8')),'hex') or target.stage <> 'draft' then
    return jsonb_build_object('withdrawn',false);
  end if;
  update public.ourport_site_inquiries set progress_consent = false, updated_at = clock_timestamp() where id = target.id;
  update ourport_private.inquiry_notifications set state = 'cancelled', lease_token = null, lease_expires_at = null
    where inquiry_id = target.id and kind = 'draft' and state <> 'sent';
  return jsonb_build_object('withdrawn',true);
end;
$$;
revoke all on function public.ourport_withdraw_draft_progress(uuid,text) from public, anon, authenticated;
grant execute on function public.ourport_withdraw_draft_progress(uuid,text) to service_role;

-- Provider dispatch is deliberately separate from intake. Claiming does not send.
create function public.ourport_claim_inquiry_notifications(p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare row_notice ourport_private.inquiry_notifications%rowtype; row_inquiry public.ourport_site_inquiries%rowtype;
  lease uuid; result jsonb := '[]'::jsonb; v_now timestamptz := clock_timestamp();
begin
  if p_limit is null or p_limit not between 1 and 25 then raise exception using errcode = '22023', message = 'invalid_limit'; end if;
  for row_notice in
    select n.* from ourport_private.inquiry_notifications n join public.ourport_site_inquiries q on q.id = n.inquiry_id
    where n.attempts < 10 and n.available_at <= v_now
      and (n.state = 'pending' or (n.state = 'sending' and n.lease_expires_at <= v_now))
      and ((n.kind = 'draft' and q.stage = 'draft' and q.progress_consent) or (n.kind = 'submitted' and q.stage = 'submitted'))
    order by n.available_at, n.id limit p_limit for update of n skip locked
  loop
    select * into row_inquiry from public.ourport_site_inquiries where id = row_notice.inquiry_id;
    lease := gen_random_uuid();
    update ourport_private.inquiry_notifications set state = 'sending', lease_token = lease,
      lease_expires_at = v_now+interval '5 minutes', attempts = attempts+1 where id = row_notice.id;
    result := result || jsonb_build_array(jsonb_build_object('notification_id',row_notice.id,'kind',row_notice.kind,
      'lease_token',lease,'recipients',row_notice.recipients,'inquiry',jsonb_build_object(
        'id',row_inquiry.id,'request_id',row_inquiry.request_id,'created_at',row_inquiry.created_at,'updated_at',row_inquiry.updated_at,
        'stage',row_inquiry.stage,'revision',row_inquiry.revision,'role',row_inquiry.role,'contact_name',row_inquiry.contact_name,
        'contact_email',row_inquiry.contact_email,'project_name',row_inquiry.project_name,'location',row_inquiry.location,
        'location_count',row_inquiry.location_count,'details',row_inquiry.details)));
  end loop;
  return result;
end;
$$;
revoke all on function public.ourport_claim_inquiry_notifications(integer) from public, anon, authenticated;
grant execute on function public.ourport_claim_inquiry_notifications(integer) to service_role;

create function public.ourport_finish_inquiry_notification(p_notification_id uuid, p_lease_token uuid, p_sent boolean, p_provider_id text default null)
returns boolean language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
begin
  if p_sent is null or length(p_provider_id) > 200 then raise exception using errcode = '22023', message = 'invalid_notification'; end if;
  update ourport_private.inquiry_notifications set state = case when p_sent then 'sent' else 'pending' end,
    sent_at = case when p_sent then clock_timestamp() else null end, provider_id = case when p_sent then p_provider_id else null end,
    available_at = case when p_sent then available_at else clock_timestamp()+interval '5 minutes' end,
    lease_token = null, lease_expires_at = null
    where id = p_notification_id and state = 'sending' and lease_token = p_lease_token and lease_expires_at > clock_timestamp();
  return found;
end;
$$;
revoke all on function public.ourport_finish_inquiry_notification(uuid,uuid,boolean,text) from public, anon, authenticated;
grant execute on function public.ourport_finish_inquiry_notification(uuid,uuid,boolean,text) to service_role;
commit;
