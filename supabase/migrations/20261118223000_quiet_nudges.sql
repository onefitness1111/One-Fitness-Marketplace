-- Quiet-client nudges.
-- Not applied to the live database by this change. Apply it when this
-- update goes live, after the quiet-nudges function is deployed.
--
-- Each morning at 8:10 Pacific the job calls that function. The password
-- is the same Vault secret the freeze job already reads (apply_requests_cron),
-- through public.cron_vault_secret(). Nothing in this file is that password.
--
-- Day 2 with no food log and no workout: one phone notification.
-- Day 3, still quiet: one text, plus an in-app and phone alert for the
-- coach they last chatted with (or their most recent coach) and the owner.
-- Logging again clears the streak so the same client can be nudged later,
-- and a streak is never nudged twice.

create table if not exists public.quiet_nudges (
  client_id uuid primary key references public.profiles(id) on delete cascade,
  last_activity_on date not null,
  push_sent_on date,
  text_sent_on date,
  coach_id uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

comment on table public.quiet_nudges is
  'Which quiet-streak nudges have already gone out. Cleared when the client logs again.';

alter table public.quiet_nudges enable row level security;

revoke all on table public.quiet_nudges from public, anon, authenticated;
grant select on table public.quiet_nudges to authenticated;

drop policy if exists quiet_nudges_select on public.quiet_nudges;
create policy quiet_nudges_select on public.quiet_nudges
  for select to authenticated
  using (public.is_owner() or coach_id = auth.uid());

-- Latest food-log day or workout day. A day with no lines does not count.
-- Someone who has never logged is measured from the day they joined,
-- in Pacific time.
create or replace function public.client_last_log_on(p_data jsonb, p_signup timestamptz)
returns date
language sql
stable
security invoker
set search_path to 'public'
as $$
  select coalesce(
    (
      select max(d)
      from (
        select day_key::date as d
        from jsonb_each(coalesce(p_data->'foodLog'->'days', '{}'::jsonb)) as day(day_key, slots)
        where day_key ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
          and jsonb_typeof(slots) = 'object'
          and exists (
            select 1
            from jsonb_each(slots) as slot(slot_key, lines)
            where jsonb_typeof(lines) = 'array'
              and jsonb_array_length(lines) > 0
          )
        union all
        select (entry->>'date')::date as d
        from jsonb_array_elements(
          case
            when jsonb_typeof(p_data->'workoutLogs') = 'array' then p_data->'workoutLogs'
            else '[]'::jsonb
          end
        ) as entry
        where coalesce(entry->>'date', '') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
          and exists (
            select 1
            from jsonb_array_elements(
              case
                when jsonb_typeof(entry->'exercises') = 'array' then entry->'exercises'
                else '[]'::jsonb
              end
            ) as ex
            cross join jsonb_array_elements(
              case
                when jsonb_typeof(ex->'sets') = 'array' then ex->'sets'
                else '[]'::jsonb
              end
            ) as s
            where coalesce(s->>'completed', '') in ('true', 't')
               or (
                 coalesce(s->>'completedReps', '') ~ '^[0-9]+(\.[0-9]+)?$'
                 and (s->>'completedReps')::numeric > 0
               )
               or (
                 coalesce(s->>'completedWeight', '') ~ '^[0-9]+(\.[0-9]+)?$'
                 and (s->>'completedWeight')::numeric > 0
               )
          )
      ) as logged
    ),
    (p_signup at time zone 'America/Los_Angeles')::date
  );
$$;

revoke all on function public.client_last_log_on(jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.client_last_log_on(jsonb, timestamptz) to service_role;

create or replace function public.quiet_nudge_roster(p_today date)
returns table (
  client_id uuid,
  first_name text,
  phone text,
  may_text boolean,
  last_activity_on date,
  quiet_days integer,
  push_sent boolean,
  text_sent boolean,
  coach_id uuid
)
language plpgsql
volatile
security invoker
set search_path to 'public'
as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Not allowed.';
  end if;

  return query
  select
    p.id,
    nullif(btrim(coalesce(nullif(btrim(p.first_name), ''), split_part(btrim(p.name), ' ', 1))), ''),
    nullif(btrim(p.phone), ''),
    (
      c.sms_opt_in is true
      and c.marketing_opt_out is not true
      and (
        c.sms_opt_in_at is not null
        or nullif(btrim(c.sms_consent_text), '') is not null
      )
      and nullif(btrim(p.phone), '') is not null
    ),
    logged.last_on,
    (p_today - logged.last_on)::integer,
    (q.push_sent_on is not null and q.last_activity_on = logged.last_on),
    (q.text_sent_on is not null and q.last_activity_on = logged.last_on),
    coalesce(chat.coach, booked.coach, primary_coach.coach)
  from public.profiles p
  join public.clients c on c.profile_id = p.id
  left join public.client_records cr on cr.profile_id = p.id
  left join public.quiet_nudges q on q.client_id = p.id
  cross join lateral (
    select public.client_last_log_on(cr.data, p.created_at) as last_on
  ) as logged
  left join lateral (
    select m.trainer_id as coach
    from public.messages m
    join public.profiles tp on tp.id = m.trainer_id
    where m.client_id = p.id
      and tp.role = 'coach'
      and tp.deleted_at is null
      and tp.banned_at is null
    order by m.created_at desc
    limit 1
  ) as chat on true
  left join lateral (
    select b.trainer_id as coach
    from public.bookings b
    join public.profiles tp on tp.id = b.trainer_id
    where b.client_id = p.id
      and b.cancelled_at is null
      and tp.role = 'coach'
      and tp.deleted_at is null
      and tp.banned_at is null
    order by b.date desc, b.slot_min desc
    limit 1
  ) as booked on true
  left join lateral (
    select tp.id as coach
    from public.profiles tp
    where tp.id = c.primary_trainer_id
      and tp.role = 'coach'
      and tp.deleted_at is null
      and tp.banned_at is null
  ) as primary_coach on true
  where p.role = 'client'
    and p.deleted_at is null
    and p.banned_at is null;
end;
$$;

revoke all on function public.quiet_nudge_roster(date) from public, anon, authenticated;
grant execute on function public.quiet_nudge_roster(date) to service_role;

-- Marks one nudge as sent for this streak. Returns false when that nudge
-- was already recorded, so a second run the same morning does not send again.
-- A newer log date starts the streak over.
create or replace function public.claim_quiet_nudge(
  p_client uuid,
  p_last date,
  p_kind text,
  p_today date,
  p_coach uuid
)
returns boolean
language plpgsql
volatile
security invoker
set search_path to 'public'
as $$
declare
  claimed boolean := false;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Not allowed.';
  end if;
  if p_kind not in ('push', 'text') then
    raise exception 'Unknown nudge.';
  end if;

  with upsert as (
    insert into public.quiet_nudges as q (
      client_id, last_activity_on, push_sent_on, text_sent_on, coach_id, updated_at
    ) values (
      p_client,
      p_last,
      case when p_kind = 'push' then p_today else null end,
      case when p_kind = 'text' then p_today else null end,
      case when p_kind = 'text' then p_coach else null end,
      now()
    )
    on conflict (client_id) do update set
      last_activity_on = excluded.last_activity_on,
      push_sent_on = case
        when q.last_activity_on is distinct from excluded.last_activity_on then excluded.push_sent_on
        when p_kind = 'push' and q.push_sent_on is null then excluded.push_sent_on
        else q.push_sent_on
      end,
      text_sent_on = case
        when q.last_activity_on is distinct from excluded.last_activity_on then excluded.text_sent_on
        when p_kind = 'text' and q.text_sent_on is null then excluded.text_sent_on
        else q.text_sent_on
      end,
      coach_id = case
        when p_kind = 'text' then excluded.coach_id
        when q.last_activity_on is distinct from excluded.last_activity_on then null
        else q.coach_id
      end,
      updated_at = now()
    where q.last_activity_on is distinct from excluded.last_activity_on
       or (p_kind = 'push' and q.push_sent_on is null)
       or (p_kind = 'text' and q.text_sent_on is null)
    returning client_id
  )
  select exists(select 1 from upsert) into claimed;

  return claimed;
end;
$$;

revoke all on function public.claim_quiet_nudge(uuid, date, text, date, uuid) from public, anon, authenticated;
grant execute on function public.claim_quiet_nudge(uuid, date, text, date, uuid) to service_role;

create or replace function public.clear_quiet_nudge(p_client uuid, p_last date)
returns void
language plpgsql
volatile
security invoker
set search_path to 'public'
as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Not allowed.';
  end if;
  update public.quiet_nudges
     set last_activity_on = p_last,
         push_sent_on = null,
         text_sent_on = null,
         coach_id = null,
         updated_at = now()
   where client_id = p_client
     and (
       push_sent_on is not null
       or text_sent_on is not null
       or coach_id is not null
       or last_activity_on is distinct from p_last
     );
end;
$$;

revoke all on function public.clear_quiet_nudge(uuid, date) from public, anon, authenticated;
grant execute on function public.clear_quiet_nudge(uuid, date) to service_role;

-- 8:10am Pacific, including daylight saving. The database clock stays on
-- UTC, so the job wakes hourly and only calls out during that Pacific hour.
do $$
declare
  existing bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_extension where extname = 'pg_net') then
    select jobid into existing from cron.job where jobname = 'quiet-client-nudges';
    if existing is not null then
      perform cron.unschedule(existing);
    end if;
    perform cron.schedule(
      'quiet-client-nudges',
      '10 * * * *',
      $cron$
      select net.http_post(
        url := 'https://rivhgutksyddeckieknc.supabase.co/functions/v1/quiet-nudges',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select public.cron_vault_secret())
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 20000
      )
      where extract(hour from timezone('America/Los_Angeles', now())) = 8;
      $cron$
    );
  else
    raise notice 'pg_cron or pg_net is not enabled, so the quiet-nudge job was not scheduled. Enable both extensions, then run this file again.';
  end if;
end $$;

notify pgrst, 'reload schema';
