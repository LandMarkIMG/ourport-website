-- Run after the migration as database administrator, before enabling dispatch.
-- All synthetic inquiries, outbox leases and quota changes end in ROLLBACK.
-- Claim/finish RPC calls below DO NOT call an email provider.
begin;
do $$
declare
  rec jsonb; first_receipt jsonb; receipt jsonb; notices jsonb; notice jsonb;
  v_inquiry_id uuid; request_id_value uuid; role_name text; fn text; i integer;
  rate_key text := repeat('a',64); token text := repeat('b',64);
begin
  if not (select relrowsecurity from pg_class where oid = 'public.ourport_site_inquiries'::regclass) then
    raise exception 'OurPort inquiry RLS is disabled';
  end if;
  if has_table_privilege('anon','public.ourport_site_inquiries','SELECT,INSERT,UPDATE,DELETE')
     or has_table_privilege('authenticated','public.ourport_site_inquiries','SELECT,INSERT,UPDATE,DELETE')
     or has_schema_privilege('anon','ourport_private','USAGE')
     or has_schema_privilege('authenticated','ourport_private','USAGE') then
    raise exception 'Public or portal-user access was granted';
  end if;
  foreach fn in array array['public.ourport_submit_site_inquiry(jsonb,text,text)',
    'public.ourport_withdraw_draft_progress(uuid,text)','public.ourport_claim_inquiry_notifications(integer)',
    'public.ourport_finish_inquiry_notification(uuid,uuid,boolean,text)'] loop
    if has_function_privilege('anon',fn,'EXECUTE') or has_function_privilege('authenticated',fn,'EXECUTE')
       or not has_function_privilege('service_role',fn,'EXECUTE') then
      raise exception 'Incorrect OurPort function grants';
    end if;
  end loop;
  perform pg_advisory_xact_lock(750032611150001::bigint);
  delete from ourport_private.intake_limits;
  delete from ourport_private.inquiry_notifications;
  foreach role_name in array array['laundromat','housing','builder'] loop
    rec := jsonb_build_object('request_id',gen_random_uuid(),'stage','submitted','revision',1,'progress_consent',false,'role',role_name,
      'contact_name','Synthetic SQL verification','contact_email',gen_random_uuid()::text||'@example.com',
      'location','Test city','project_name',null,'location_count',1,'details',jsonb_build_object('sourcePath','/plan-a-site/') || case role_name
        when 'laundromat' then '{"dashboard":"Test POS","bagSize":"To be confirmed"}'::jsonb
        when 'housing' then '{"homesOrBeds":100,"providerStatus":"Looking for a provider"}'::jsonb
        else '{"siteStage":"Early planning","siteConstraints":"Test only"}'::jsonb end);
    first_receipt := public.ourport_submit_site_inquiry(rec,rate_key,token);
    receipt := public.ourport_submit_site_inquiry(rec,rate_key,token);
    if first_receipt is distinct from receipt or not (receipt ?& array['id','created_at','stage','revision'])
       or (select count(*) from jsonb_object_keys(receipt)) <> 4 then raise exception 'Receipt/retry mismatch'; end if;
    begin
      perform public.ourport_submit_site_inquiry(rec,rate_key,repeat('c',64));
      raise exception 'Wrong edit token was accepted';
    exception when unique_violation then null; end;
    begin
      perform public.ourport_submit_site_inquiry(rec || '{"location":"Different"}'::jsonb,rate_key,token);
      raise exception 'Same revision with changed payload was accepted';
    exception when unique_violation then null; end;
    begin
      perform public.ourport_submit_site_inquiry(rec || '{"revision":2}'::jsonb,rate_key,token);
      raise exception 'Submitted record was changed';
    exception when unique_violation then null; end;
    begin
      perform public.ourport_submit_site_inquiry(rec || '{"status":"qualified"}'::jsonb,rate_key,token);
      raise exception 'Unexpected top-level field was accepted';
    exception when invalid_parameter_value then null; end;
    begin
      perform public.ourport_submit_site_inquiry(jsonb_set(rec,'{details,unknown}',to_jsonb('Test'::text)),rate_key,token);
      raise exception 'Unexpected detail field was accepted';
    exception when invalid_parameter_value then null; end;
  end loop;
  begin
    perform public.ourport_submit_site_inquiry(rec,'',token);
    raise exception 'Missing network bucket was accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.ourport_submit_site_inquiry(jsonb_set(rec,'{location_count}',to_jsonb('x'::text)),rate_key,token);
    raise exception 'Non-numeric location count was accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.ourport_submit_site_inquiry(jsonb_set(rec,'{details}',
      '{"sourcePath":"/plan-a-site/","homesOrBeds":2}'::jsonb),rate_key,token);
    raise exception 'Inactive housing fields were accepted for builder';
  exception when invalid_parameter_value then null; end;

  -- Draft minimum, consent, updates and final submission on one request ID.
  delete from ourport_private.intake_limits;
  delete from ourport_private.inquiry_notifications;
  request_id_value := gen_random_uuid();
  rec := jsonb_build_object('request_id',request_id_value,'stage','draft','revision',1,'progress_consent',true,
    'role','housing','contact_name',null,'contact_email','draft-'||gen_random_uuid()::text||'@example.com',
    'location',null,'details','{"sourcePath":"/plan-a-site/","homesOrBeds":100}'::jsonb);
  begin
    perform public.ourport_submit_site_inquiry(rec || '{"progress_consent":false}'::jsonb,rate_key,token);
    raise exception 'Unconsented draft was accepted';
  exception when invalid_parameter_value then null; end;
  receipt := public.ourport_submit_site_inquiry(rec,rate_key,token); v_inquiry_id := (receipt->>'id')::uuid;
  if (select edit_token_hash from public.ourport_site_inquiries where id = v_inquiry_id) = token then raise exception 'Raw edit token stored'; end if;
  if jsonb_array_length(public.ourport_claim_inquiry_notifications()) <> 0 then raise exception 'Draft email became due too soon'; end if;
  rec := rec || '{"revision":2,"contact_name":"Updated progress"}'::jsonb;
  perform public.ourport_submit_site_inquiry(rec,repeat('c',64),token);
  if (select count(*) from ourport_private.inquiry_notifications where inquiry_id = v_inquiry_id and kind = 'draft') <> 1 then
    raise exception 'Draft notifications did not coalesce';
  end if;
  begin
    perform public.ourport_submit_site_inquiry(rec || '{"revision":3,"contact_email":"changed@example.com"}'::jsonb,rate_key,token);
    raise exception 'Draft email ownership changed';
  exception when unique_violation then null; end;
  if public.ourport_withdraw_draft_progress(request_id_value,token)->>'withdrawn' <> 'true' then raise exception 'Withdrawal failed'; end if;
  if (select progress_consent from public.ourport_site_inquiries where id = v_inquiry_id) then raise exception 'Consent was not cleared'; end if;
  perform public.ourport_submit_site_inquiry(rec,rate_key,token);
  if (select progress_consent from public.ourport_site_inquiries where id = v_inquiry_id) then raise exception 'Old retry re-enabled consent'; end if;
  update ourport_private.inquiry_notifications set available_at = now()-interval '1 minute';
  if jsonb_array_length(public.ourport_claim_inquiry_notifications()) <> 0 then raise exception 'Withdrawn progress was dispatched'; end if;
  rec := rec || '{"revision":3,"progress_consent":true}'::jsonb;
  perform public.ourport_submit_site_inquiry(rec,rate_key,token);
  update ourport_private.inquiry_notifications set available_at = now()-interval '1 minute' where inquiry_id = v_inquiry_id;
  notices := public.ourport_claim_inquiry_notifications(); notice := notices->0;
  if jsonb_array_length(notices) <> 1 or notice->>'kind' <> 'draft'
     or notice->'inquiry'->>'contact_name' <> 'Updated progress'
     or notice->'recipients' <> '["mike@monetize-that.com","Joe@monetize-that.com"]'::jsonb then raise exception 'Incorrect draft notification'; end if;
  if jsonb_array_length(public.ourport_claim_inquiry_notifications()) <> 0 then raise exception 'Active lease was claimed twice'; end if;
  if not public.ourport_finish_inquiry_notification((notice->>'notification_id')::uuid,(notice->>'lease_token')::uuid,true,'synthetic-provider-id') then
    raise exception 'Notification completion failed';
  end if;
  -- Two progress updates have already used revision2/revision3. The next58
  -- exhaust the60/hour budget; final submission retains one reserved slot.
  for i in 4..61 loop
    rec := rec || jsonb_build_object('revision',i);
    perform public.ourport_submit_site_inquiry(rec,rate_key,token);
  end loop;
  begin
    perform public.ourport_submit_site_inquiry(rec || '{"revision":62}'::jsonb,rate_key,token);
    raise exception 'Progress update quota missing';
  exception when raise_exception then if sqlerrm <> 'rate_limit' then raise; end if; end;
  rec := rec || '{"stage":"submitted","revision":62,"location":"Test city"}'::jsonb;
  receipt := public.ourport_submit_site_inquiry(rec,rate_key,token);
  if receipt->>'stage' <> 'submitted' then raise exception 'Draft submission failed'; end if;
  notices := public.ourport_claim_inquiry_notifications();
  if jsonb_array_length(notices) <> 1 or notices->0->>'kind' <> 'submitted' then raise exception 'Submitted notice missing'; end if;
  if public.ourport_withdraw_draft_progress(request_id_value,token)->>'withdrawn' <> 'false' then raise exception 'Submitted inquiry was withdrawn'; end if;

  -- New-inquiry quotas are separate from owner-authorized draft update quotas.
  delete from ourport_private.intake_limits;
  for i in 1..5 loop
    perform public.ourport_submit_site_inquiry(rec || jsonb_build_object('request_id',gen_random_uuid(),'contact_email',gen_random_uuid()::text||'@example.com'),rate_key,token);
  end loop;
  begin
    perform public.ourport_submit_site_inquiry(rec || jsonb_build_object('request_id',gen_random_uuid()),rate_key,token);
    raise exception 'Network quota missing';
  exception when raise_exception then if sqlerrm <> 'rate_limit' then raise; end if; end;
  delete from ourport_private.intake_limits;
  rec := rec || jsonb_build_object('contact_email','quota-'||gen_random_uuid()::text||'@example.com');
  for i in 1..5 loop
    perform public.ourport_submit_site_inquiry(rec || jsonb_build_object('request_id',gen_random_uuid()),lpad(i::text,64,'0'),token);
  end loop;
  begin
    perform public.ourport_submit_site_inquiry(rec || jsonb_build_object('request_id',gen_random_uuid()),repeat('c',64),token);
    raise exception 'Email quota missing';
  exception when raise_exception then if sqlerrm <> 'rate_limit' then raise; end if; end;
  update ourport_private.intake_limits set attempts = 200 where bucket_key = 'global';
  begin
    perform public.ourport_submit_site_inquiry(rec || jsonb_build_object('request_id',gen_random_uuid(),'contact_email',gen_random_uuid()::text||'@example.com'),repeat('c',64),token);
    raise exception 'Global quota missing';
  exception when raise_exception then if sqlerrm <> 'rate_limit' then raise; end if; end;
end;
$$;
rollback;
select extname from pg_extension where extname in ('pg_cron','pg_net','supabase_vault') order by extname;
select 'OurPort grants, validation, draft consent/ownership, revisions, receipts, outbox leases and quotas verified; synthetic changes rolled back.' as verification;
