-- Reminders on Coach Chris's schedule (Nov 27, 2026), replacing the 5am
-- daily batch:
--   * send-scheduled-reminders runs every hour on the hour and decides in
--     Pacific time what is due (session reminders ~24h ahead, habits at
--     7pm, challenge notes, 1st-of-month at 9am). Quiet hours 9pm-8am.
--   * scheduled_notices records each reminder so a booking, challenge or
--     month is only ever reminded once.
--   * Jobs 1 and 2 read the timer secret from Vault through
--     public.cron_vault_secret(), like every other job, instead of carrying
--     it in the job text.
--
-- Deploy send-scheduled-reminders and waitlist-sweep BEFORE running this
-- file: the new code accepts the Vault secret, the old code does not.

create table if not exists public.scheduled_notices (
  kind text not null,
  ref text not null,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (kind, ref, profile_id)
);

create index if not exists scheduled_notices_sent_at_idx on public.scheduled_notices (sent_at);

alter table public.scheduled_notices enable row level security;

drop policy if exists scheduled_notices_owner_select on public.scheduled_notices;
create policy scheduled_notices_owner_select on public.scheduled_notices
  for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'owner'));

revoke all on public.scheduled_notices from anon;
grant select on public.scheduled_notices to authenticated;
grant all on public.scheduled_notices to service_role;

-- Reminders already sent today by the old 5am run must not repeat: mark
-- tomorrow's and today's bookings as reminded.
insert into public.scheduled_notices (kind, ref, profile_id)
select 'session', b.id::text, b.client_id
from public.bookings b
where b.client_id is not null
  and exists (select 1 from public.profiles p where p.id = b.client_id)
  and b.cancelled_at is null
  and b.date between (now() at time zone 'America/Los_Angeles')::date
                 and (now() at time zone 'America/Los_Angeles')::date + 1
on conflict do nothing;

do $$
declare
  existing bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_extension where extname = 'pg_net') then
    for existing in
      select jobid from cron.job
      where jobname in ('send-scheduled-reminders-daily', 'send-scheduled-reminders-hourly')
    loop
      perform cron.unschedule(existing);
    end loop;
    perform cron.schedule(
      'send-scheduled-reminders-hourly',
      '0 * * * *',
      $cron$
      select net.http_post(
        url := 'https://rivhgutksyddeckieknc.supabase.co/functions/v1/send-scheduled-reminders',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select public.cron_vault_secret())
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
      );
      $cron$
    );

    select jobid into existing from cron.job where jobname = 'waitlist-sweep';
    if existing is not null then
      perform cron.unschedule(existing);
    end if;
    perform cron.schedule(
      'waitlist-sweep',
      '*/15 * * * *',
      $cron$
      select net.http_post(
        url := 'https://rivhgutksyddeckieknc.supabase.co/functions/v1/waitlist-sweep',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select public.cron_vault_secret())
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
      );
      $cron$
    );
  else
    raise notice 'pg_cron or pg_net is not enabled, so the reminder jobs were not scheduled.';
  end if;
end $$;

notify pgrst, 'reload schema';
