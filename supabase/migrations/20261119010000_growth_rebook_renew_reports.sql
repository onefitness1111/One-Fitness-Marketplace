-- Package renewal reminders and the monthly progress report.
-- Not applied to the live database by this change. Apply it when this
-- update goes live, after the two functions it calls are deployed.
--
-- The morning jobs use the same Vault secret the freeze job already reads
-- (apply_requests_cron), through public.cron_vault_secret(). Nothing in
-- this file is that password.
--
-- A session package at 8 sessions left gets one "Renew now at 5% off"
-- reminder, by phone notification and in the app. Skipping or dismissing
-- that offer forfeits the 5% for that package. At 2 sessions left the
-- reminder is full price. A renewal that already went through is not
-- offered or charged again.
--
-- The progress report goes out on the 1st, for the month that just ended.

create table if not exists public.client_notices (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  plan_id text not null default '',
  enrollment_start date,
  title text not null,
  body text not null,
  forfeited boolean not null default false,
  dismissed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint client_notices_kind check (kind in ('package_discount', 'package_full', 'package_confirmed')),
  constraint client_notices_one unique (client_id, kind, plan_id, enrollment_start)
);

comment on table public.client_notices is
  'In-app reminders. A package discount row with forfeited set has lost the 5% for that package.';

alter table public.client_notices enable row level security;

revoke all on table public.client_notices from public, anon;
grant select on table public.client_notices to authenticated;

drop policy if exists client_notices_select on public.client_notices;
create policy client_notices_select on public.client_notices
  for select to authenticated
  using (client_id = auth.uid() or public.is_owner());

-- Closing a reminder. The 5% offer, once skipped or dismissed, stays
-- forfeited. The client cannot turn it back on.
create or replace function public.dismiss_package_renewal(
  p_plan text,
  p_start date,
  p_kind text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  me uuid := auth.uid();
  lose boolean;
begin
  if me is null then
    raise exception 'Not signed in.';
  end if;
  if p_kind not in ('package_discount', 'package_full') then
    raise exception 'Unknown reminder.';
  end if;
  if p_plan is null or btrim(p_plan) = '' or p_start is null then
    raise exception 'That package was not found.';
  end if;
  lose := p_kind = 'package_discount';

  insert into public.client_notices (
    client_id, kind, plan_id, enrollment_start, title, body, forfeited, dismissed_at
  ) values (
    me,
    p_kind,
    p_plan,
    p_start,
    case when lose then 'Renew now at 5% off' else 'Renew now' end,
    case when lose
      then 'The 5% renewal discount on this package has been given up.'
      else 'Renewal reminder closed.'
    end,
    lose,
    now()
  )
  on conflict (client_id, kind, plan_id, enrollment_start) do update set
    dismissed_at = now(),
    forfeited = client_notices.forfeited or excluded.forfeited;
end;
$$;

revoke all on function public.dismiss_package_renewal(text, date, text) from public, anon;
grant execute on function public.dismiss_package_renewal(text, date, text) to authenticated;

-- One charge attempt per package and offer. A succeeded row means that
-- package was already renewed, so a second tap cannot charge it again.
create table if not exists public.package_renewal_charges (
  idempotency_key text primary key,
  client_id uuid not null references public.profiles(id) on delete cascade,
  plan_id text not null,
  enrollment_start date not null,
  offer text not null,
  payment_intent_id text,
  amount_cents integer,
  status text not null default 'started',
  confirmed_at timestamptz,
  attempt integer not null default 1,
  created_at timestamptz not null default now(),
  constraint package_renewal_offer check (offer in ('discount', 'full')),
  constraint package_renewal_status check (status in ('started', 'succeeded'))
);

create unique index if not exists package_renewal_one_success
  on public.package_renewal_charges (client_id, plan_id, enrollment_start)
  where status = 'succeeded';

comment on table public.package_renewal_charges is
  'Package renewals already started or paid. The idempotency key is what Stripe uses so a retry is the same charge.';

alter table public.package_renewal_charges enable row level security;

revoke all on table public.package_renewal_charges from public, anon, authenticated;

create table if not exists public.monthly_progress_sends (
  client_id uuid not null references public.profiles(id) on delete cascade,
  month text not null,
  sent_at timestamptz not null default now(),
  primary key (client_id, month)
);

comment on table public.monthly_progress_sends is
  'Which monthly progress reports have already been sent. One row per client per month.';

alter table public.monthly_progress_sends enable row level security;

revoke all on table public.monthly_progress_sends from public, anon, authenticated;

-- A goal the client sets on Log Progress. Same locked patch as the other
-- pieces of the client record, so saving a goal does not rewrite the rest.
create or replace function public.patch_client_record(p_client uuid, p_patch jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  row_data jsonb;
  k text;
begin
  if auth.role() is distinct from 'service_role'
     and auth.uid() is distinct from p_client
     and public.current_user_role() not in ('coach', 'owner') then
    raise exception 'Not allowed.';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'Nothing to save.';
  end if;
  if p_patch ? 'foodLog'
     and auth.role() is distinct from 'service_role'
     and auth.uid() is distinct from p_client
     and public.current_user_role() is distinct from 'owner' then
    raise exception 'Only the client can update their food log.';
  end if;
  for k in select jsonb_object_keys(p_patch) loop
    if k not in (
      'nutrition', 'myMeals', 'savedNutritionPrograms',
      'measurements', 'trainerNotes', 'photos', 'intake',
      'foodLog', 'progressGoal'
    ) then
      raise exception 'That part of the record cannot be saved this way.';
    end if;
  end loop;

  select data into row_data from public.client_records where profile_id = p_client for update;
  if row_data is null then
    insert into public.client_records (profile_id, data) values (p_client, p_patch);
    return;
  end if;
  update public.client_records
     set data = coalesce(row_data, '{}'::jsonb) || p_patch
   where profile_id = p_client;
end;
$$;

revoke all on function public.patch_client_record(uuid, jsonb) from public, anon;
grant execute on function public.patch_client_record(uuid, jsonb) to authenticated;

-- 9:05am Pacific every day. The database clock stays on UTC, so the job
-- wakes hourly and only calls out during that Pacific hour.
do $$
declare
  existing bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_extension where extname = 'pg_net') then
    select jobid into existing from cron.job where jobname = 'package-renewal-alerts';
    if existing is not null then
      perform cron.unschedule(existing);
    end if;
    perform cron.schedule(
      'package-renewal-alerts',
      '5 * * * *',
      $cron$
      select net.http_post(
        url := 'https://rivhgutksyddeckieknc.supabase.co/functions/v1/package-renewal-alerts',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select public.cron_vault_secret())
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 20000
      )
      where extract(hour from timezone('America/Los_Angeles', now())) = 9;
      $cron$
    );

    select jobid into existing from cron.job where jobname = 'monthly-progress-report';
    if existing is not null then
      perform cron.unschedule(existing);
    end if;
    perform cron.schedule(
      'monthly-progress-report',
      '20 * * * *',
      $cron$
      select net.http_post(
        url := 'https://rivhgutksyddeckieknc.supabase.co/functions/v1/monthly-progress-report',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select public.cron_vault_secret())
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 20000
      )
      where extract(hour from timezone('America/Los_Angeles', now())) = 8
        and extract(day from timezone('America/Los_Angeles', now())) = 1;
      $cron$
    );
  else
    raise notice 'pg_cron or pg_net is not enabled, so the renewal and progress jobs were not scheduled. Enable both extensions, then run this file again.';
  end if;
end $$;

notify pgrst, 'reload schema';
