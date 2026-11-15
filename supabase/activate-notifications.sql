-- Run only after notify.ourport.us is verified in Resend and both Vault secrets
-- exist. This starts real email delivery to Mike and Joe; no secret is returned.
-- Also complete the isolation metadata and anonymous REST-rejection checks.
begin;
do $$
begin
  if not ourport_private.inquiry_notification_configuration_ready() then
    raise exception 'OurPort notification secrets or sender are not configured';
  end if;
  if exists (select 1 from cron.job where jobname = 'ourport-notifications'
    and command <> 'select ourport_private.dispatch_inquiry_notifications();') then
    raise exception 'The OurPort cron name is already used by another command';
  end if;
  perform cron.schedule('ourport-notifications','* * * * *','select ourport_private.dispatch_inquiry_notifications();');
end;
$$;
commit;
select jobid,jobname,schedule,command,active from cron.job where jobname = 'ourport-notifications';
