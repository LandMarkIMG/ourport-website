-- Run after migration002, before activation. No net.http_post, scheduler or
-- provider is invoked. Synthetic provider responses and data are rolled back.
begin;
do $$
declare
  notice jsonb; payload jsonb; q jsonb; receipt jsonb; row_id uuid; notice_id uuid; lease_id uuid;
  request_number bigint; response_code integer; response_body text; timed_out_value boolean; error_value text;
  row_state text; delivery_state text; last_error_value text; i integer; fn text; client_role text; private_table text;
begin
  foreach fn in array array['ourport_private.inquiry_notification_configuration_ready()',
    'ourport_private.inquiry_notification_payload(jsonb,text)','ourport_private.collect_inquiry_notification_responses()',
    'ourport_private.dispatch_inquiry_notifications()'] loop
    if has_function_privilege('anon',fn,'EXECUTE') or has_function_privilege('authenticated',fn,'EXECUTE')
       or has_function_privilege('service_role',fn,'EXECUTE') then raise exception 'Notification helper grant is too broad'; end if;
  end loop;
  foreach client_role in array array['anon','authenticated'] loop
    if has_schema_privilege(client_role,'ourport_private','USAGE')
       or (select rolcanlogin from pg_roles where rolname = client_role) then raise exception 'Client role can reach private notification objects'; end if;
    foreach private_table in array array['ourport_private.notification_deliveries','ourport_private.notification_http_attempts'] loop
      if has_table_privilege(client_role,private_table,'SELECT,INSERT,UPDATE,DELETE') then raise exception 'Private notification data is exposed'; end if;
    end loop;
  end loop;
  -- Hosted Supabase owns pg_net and may retain PUBLIC grants that project
  -- postgres cannot revoke. Verify its API-schema rejection separately using
  -- ourport_notifications_isolation.sql and anonymous REST requests.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','graphql_public') and p.prokind = 'f' and p.prosecdef
      and (p.prosrc ~* '(^|[^a-z0-9_])"?net"?[[:space:]]*[.]' or p.prosrc ~* '(^|[^a-z0-9_])"?ourport_private"?[[:space:]]*[.]')
      and (has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE'))) then
    raise exception 'Client-executable notification/HTTP bridge is exposed';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'ourport_private.notification_deliveries'::regclass)
     or not (select relrowsecurity from pg_class where oid = 'ourport_private.notification_http_attempts'::regclass) then raise exception 'Private notification RLS missing'; end if;
  q := jsonb_build_object('id',gen_random_uuid(),'role','housing','contact_name','Synthetic verification',
    'contact_email','synthetic@example.com','project_name',E'Project\nBcc: injected@example.com','location','Test city',
    'location_count',2,'updated_at',now(),'details','{"sourcePath":"/plan-a-site/","homesOrBeds":42,"providerStatus":"Looking for a provider"}'::jsonb);
  notice := jsonb_build_object('kind','draft','recipients',jsonb_build_array('mike@monetize-that.com','Joe@monetize-that.com'),'inquiry',q);
  payload := ourport_private.inquiry_notification_payload(notice,'OurPort <inquiries@notify.ourport.us>');
  if payload->'to' <> '["mike@monetize-that.com","Joe@monetize-that.com"]'::jsonb
     or payload->>'reply_to' <> 'synthetic@example.com' or payload->>'subject' not like 'OurPort unfinished inquiry%'
     or payload->>'subject' ~ '[[:cntrl:]]' or payload->>'text' not like '%Homes / student beds:%'
     or payload ? 'html' or (select count(*) from jsonb_object_keys(payload)) <> 5 then raise exception 'Unsafe/incomplete email payload'; end if;
  payload := ourport_private.inquiry_notification_payload(notice || '{"kind":"submitted"}'::jsonb,'OurPort <inquiries@notify.ourport.us>');
  if payload->>'subject' not like 'OurPort inquiry%' then raise exception 'Submitted subject incorrect'; end if;
  begin
    perform ourport_private.inquiry_notification_payload(notice || '{"recipients":["other@example.com"]}'::jsonb,'OurPort <inquiries@notify.ourport.us>');
    raise exception 'Unapproved recipient accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform ourport_private.inquiry_notification_payload(jsonb_set(notice,'{inquiry,contact_email}',to_jsonb(E'a@example.com\nInjected'::text)),'OurPort <inquiries@notify.ourport.us>');
    raise exception 'Unsafe reply-to accepted';
  exception when invalid_parameter_value then null; end;

  -- Each scenario creates a private fake attempt with a negative request ID,
  -- which cannot collide with pg_net's positive request sequence.
  for i in 1..8 loop
    row_id := gen_random_uuid(); notice_id := gen_random_uuid(); lease_id := gen_random_uuid(); request_number := -750032611150000-i;
    insert into public.ourport_site_inquiries(id,request_id,stage,revision,progress_consent,role,contact_name,contact_email,location,details,payload_hash,edit_token_hash,status)
      values(row_id,gen_random_uuid(),'submitted',1,false,'housing','Synthetic notification check','synthetic@example.com','Test city','{"sourcePath":"/plan-a-site/"}',repeat('0',64),repeat('1',64),'new');
    insert into ourport_private.inquiry_notifications(id,inquiry_id,kind,state,available_at,lease_token,lease_expires_at,attempts)
      values(notice_id,row_id,'submitted','sending',now(),lease_id,now()+interval '5 minutes',1);
    insert into ourport_private.notification_deliveries(notification_id,payload) values(notice_id,payload);
    insert into ourport_private.notification_http_attempts(http_request_id,notification_id,lease_token,created_at)
      values(request_number,notice_id,lease_id,case when i = 8 then now()-interval '4 minutes 30 seconds' else now() end);
    response_code := case when i = 1 then 201 when i in (2,3,4) then 200 when i = 5 then 429 when i = 6 then 500 else null end;
    response_body := case when i = 2 then 'not JSON' when i = 3 then '{"id":"invalid"}' when i = 4 then '{"id":123}'
      else '{"id":"49a3999c-0ce1-4ea6-ab68-afcd6dc2e794"}' end;
    timed_out_value := i = 7; error_value := case when i = 7 then 'synthetic timeout' else null end;
    if i <> 8 then
      insert into net._http_response(id,status_code,content_type,headers,content,timed_out,error_msg)
        values(request_number,response_code,'application/json','{}',response_body,timed_out_value,error_value);
    end if;
    receipt := ourport_private.collect_inquiry_notification_responses();
    select state into row_state from ourport_private.inquiry_notifications where id = notice_id;
    select state,last_error into delivery_state,last_error_value from ourport_private.notification_deliveries where notification_id = notice_id;
    if i = 1 then
      if row_state <> 'sent' or delivery_state <> 'accepted' or receipt->>'accepted' <> '1' then raise exception 'Valid provider receipt not acknowledged'; end if;
    else
      if row_state <> 'pending' or delivery_state <> 'pending' or last_error_value is null then raise exception 'Failure incorrectly acknowledged'; end if;
    end if;
    if (select processed_at is null from ourport_private.notification_http_attempts where http_request_id = request_number) then raise exception 'HTTP attempt not collected'; end if;
  end loop;
end;
$$;
rollback;
select 'OurPort email payload, recipient restrictions, private grants and HTTP response acknowledgement checks passed; no provider called.' as verification;
