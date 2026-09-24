-- Apply only to the confirmed sales-inquiry project. No resident or order data.
create table public.site_inquiries (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  created_at timestamptz not null default now(),
  role text not null check (role in ('laundromat','housing','builder')),
  contact_name text not null check (length(contact_name) between 1 and 120),
  contact_email text not null check (length(contact_email) between 3 and 254),
  project_name text check (length(project_name) <= 180),
  location text not null check (length(location) between 1 and 180),
  location_count integer check (location_count between 1 and 10000),
  details jsonb not null default '{}'::jsonb,
  status text not null default 'new' check (status in ('new','contacted','qualified','closed'))
);
alter table public.site_inquiries enable row level security;
revoke all on public.site_inquiries from anon, authenticated;
grant select, insert, update on public.site_inquiries to service_role;
-- No public policies: only the server-side service role may access this table.
-- Staff workflow, retention and recipient access must be agreed before activation.
