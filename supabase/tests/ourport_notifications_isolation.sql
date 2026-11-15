-- Read-only. Do not select net queue headers/bodies or Vault values.
-- On hosted Supabase, pg_net's supabase_admin-owned PUBLIC grants can remain
-- despite project-level REVOKE. That ACL alone is not Data API reachability.
select rolname,rolcanlogin from pg_roles where rolname in ('anon','authenticated') order by rolname;

select n.nspname,c.relname,pg_get_userbyid(c.relowner) as object_owner,c.relacl,
  has_table_privilege('anon',c.oid,'SELECT') as anon_select,
  has_table_privilege('authenticated',c.oid,'SELECT') as authenticated_select
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'net' and c.relname in ('http_request_queue','_http_response') order by c.relname;

-- These are schema names only, not other authenticator settings. Some hosted
-- installations configure PostgREST outside pg_db_role_setting; zero rows here
-- means the external REST rejection is authoritative, not that net is exposed.
select coalesce(r.rolname,'all_roles') as configured_role,coalesce(d.datname,'all_databases') as configured_database,
  substring(config_value from length('pgrst.db_schemas=')+1) as api_exposed_schemas
from pg_db_role_setting s
left join pg_roles r on r.oid = s.setrole left join pg_database d on d.oid = s.setdatabase
cross join lateral unnest(s.setconfig) as config(config_value)
where config_value like 'pgrst.db_schemas=%';

-- Expected zero rows: no client-executable SECURITY DEFINER in the normal API
-- schemas may bridge directly into net or the private OurPort dispatcher.
-- This deliberately prints identity/grants, never function bodies.
select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
  has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public','graphql_public') and p.prokind = 'f' and p.prosecdef
  and (p.prosrc ~* '(^|[^a-z0-9_])"?net"?[[:space:]]*[.]' or p.prosrc ~* '(^|[^a-z0-9_])"?ourport_private"?[[:space:]]*[.]')
  and (has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE'));

select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
  has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute,
  has_function_privilege('service_role',p.oid,'EXECUTE') as service_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'ourport_private' and p.proname in
  ('dispatch_inquiry_notifications','collect_inquiry_notification_responses','inquiry_notification_payload','inquiry_notification_configuration_ready')
order by p.proname;

-- Required external checks with an anon/publishable key (keep its value out of
-- shell output): GET /rest/v1/_http_response with Accept-Profile: net and
-- GET /rest/v1/http_request_queue with Accept-Profile: net must return 406
-- PGRST106 (net absent from exposed schemas). POST /rest/v1/rpc/http_post with
-- Content-Profile: net must likewise be rejected before executing anything.
-- Do not invoke an exposed HTTP bridge or send an actual provider request.
