-- Read-only operational status. No API key, message body, edit token or raw IP
-- is selected. A provider-accepted email is not proof of mailbox delivery.
select extname from pg_extension where extname in ('pg_cron','pg_net','supabase_vault') order by extname;
select ourport_private.inquiry_notification_configuration_ready() as configuration_ready;
select jobid,jobname,schedule,active from cron.job where jobname = 'ourport-notifications';
select kind,state,count(*) as notifications from ourport_private.inquiry_notifications group by kind,state order by kind,state;
select state,last_error,count(*) as deliveries from ourport_private.notification_deliveries group by state,last_error order by state,last_error;
select outcome,status_code,count(*) as http_attempts from ourport_private.notification_http_attempts group by outcome,status_code order by outcome,status_code;
select count(*) as overdue_or_exhausted from ourport_private.inquiry_notifications
  where state = 'pending' and (attempts >= 10 or available_at < clock_timestamp()-interval '10 minutes');
select status,return_message,start_time,end_time from cron.job_run_details
  where jobid in (select jobid from cron.job where jobname = 'ourport-notifications') order by start_time desc limit 5;
