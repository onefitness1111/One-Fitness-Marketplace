-- Per-plan session overrides, and the job that rolls unused membership
-- sessions into the next month.
--
-- A session-count override used to sit on the client, so it followed them
-- onto whatever they bought next. It now lives on that one plan entry.
-- This moves any override already stored on the client onto the plan in
-- their membership slot, then clears the columns.

create or replace function public.stamp_plan_session_override(
  p_plans jsonb,
  p_plan text,
  p_override integer,
  p_month text
) returns jsonb
language plpgsql
immutable
as $$
declare
  result jsonb := '[]'::jsonb;
  elem jsonb;
  stamped boolean := false;
  i integer;
  n integer;
begin
  if p_plan is null or p_override is null then
    return coalesce(p_plans, '[]'::jsonb);
  end if;
  n := jsonb_array_length(coalesce(p_plans, '[]'::jsonb));
  for i in 0 .. n - 1
  loop
    elem := p_plans -> i;
    if not stamped
       and coalesce(elem->>'status', '') = 'active'
       and elem->>'planId' = p_plan then
      if elem->>'maxSessionsOverride' is null then
        elem := elem || jsonb_strip_nulls(jsonb_build_object(
          'maxSessionsOverride', p_override,
          'maxSessionsOverrideMonth', p_month
        ));
      end if;
      stamped := true;
    end if;
    result := result || jsonb_build_array(elem);
  end loop;
  return result;
end;
$$;

revoke all on function public.stamp_plan_session_override(jsonb, text, integer, text) from public, anon, authenticated;

-- When the membership slot changes, a leftover client-wide override stays
-- on the plan that was in the slot. The plan being switched to does not
-- inherit it. stripe-webhook is not in this repo; this covers that path.
create or replace function public.preserve_session_override_on_plan_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.session_count_override is null then
    return new;
  end if;
  if old.membership_plan_id is null then
    return new;
  end if;
  if new.membership_plan_id is not distinct from old.membership_plan_id then
    return new;
  end if;
  new.plans := public.stamp_plan_session_override(
    coalesce(new.plans, '[]'::jsonb),
    old.membership_plan_id,
    new.session_count_override,
    new.session_count_override_month
  );
  new.session_count_override := null;
  new.session_count_override_month := null;
  return new;
end;
$$;

revoke all on function public.preserve_session_override_on_plan_change() from public, anon, authenticated;

do $$
declare
  r record;
  target text;
  elem jsonb;
  new_plans jsonb;
  stamped boolean;
  i integer;
  n integer;
begin
  for r in
    select profile_id,
           coalesce(plans, '[]'::jsonb) as plans,
           membership_plan_id,
           session_count_override,
           session_count_override_month
    from public.clients
    where session_count_override is not null
  loop
    target := r.membership_plan_id;
    if target is null then
      select e->>'planId' into target
      from jsonb_array_elements(r.plans) e
      where coalesce(e->>'status', '') = 'active'
      order by coalesce(e->>'startDate', '') desc
      limit 1;
    end if;

    new_plans := r.plans;
    if target is not null then
      new_plans := '[]'::jsonb;
      stamped := false;
      n := jsonb_array_length(r.plans);
      for i in 0 .. n - 1
      loop
        elem := r.plans -> i;
        if not stamped
           and coalesce(elem->>'status', '') = 'active'
           and elem->>'planId' = target then
          if elem->>'maxSessionsOverride' is null then
            elem := elem || jsonb_strip_nulls(jsonb_build_object(
              'maxSessionsOverride', r.session_count_override,
              'maxSessionsOverrideMonth', r.session_count_override_month
            ));
          end if;
          stamped := true;
        end if;
        new_plans := new_plans || jsonb_build_array(elem);
      end loop;
      -- The slot already grants this plan. Give the override a row to live
      -- on when the client was assigned the plan without an enrolment.
      if not stamped and r.membership_plan_id is not null then
        new_plans := new_plans || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
          'planId', r.membership_plan_id,
          'status', 'active',
          'startDate', to_char(timezone('America/Los_Angeles', now()), 'YYYY-MM-DD'),
          'maxSessionsOverride', r.session_count_override,
          'maxSessionsOverrideMonth', r.session_count_override_month
        )));
      end if;
    end if;

    update public.clients
       set plans = new_plans,
           session_count_override = null,
           session_count_override_month = null
     where profile_id = r.profile_id;
  end loop;
end $$;

drop trigger if exists trg_preserve_session_override on public.clients;
create trigger trg_preserve_session_override
  before update of membership_plan_id
  on public.clients
  for each row
  execute function public.preserve_session_override_on_plan_change();

create or replace function public.client_plan_allowance(p_client uuid, p_plan text)
returns integer
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  plan jsonb;
  kind text;
  base integer;
  limited boolean;
  enrollment jsonb;
  override integer;
  override_month text;
  slot text;
  month text := to_char(timezone('America/Los_Angeles', now()), 'YYYY-MM');
  rollover integer := 0;
begin
  if p_plan is null or p_plan like 'single:%' then
    return null;
  end if;
  select data into plan from public.membership_plans where id = p_plan;
  if plan is null then
    return null;
  end if;
  kind := coalesce(plan->>'kind', '');
  if kind in ('program', 'nutritionProgram') then
    return null;
  end if;
  base := coalesce((plan->>'maxSessions')::int, 0);
  limited := base > 0;

  select e into enrollment
  from public.clients c
  cross join lateral jsonb_array_elements(coalesce(c.plans, '[]'::jsonb)) e
  where c.profile_id = p_client
    and e->>'planId' = p_plan
    and coalesce(e->>'status', '') = 'active'
  limit 1;

  if enrollment is not null
     and nullif(enrollment->>'maxSessionsOverride', '') is not null then
    override := (enrollment->>'maxSessionsOverride')::int;
    override_month := nullif(enrollment->>'maxSessionsOverrideMonth', '');
    if not (kind = 'membership' and override_month is not null and override_month <> month) then
      base := greatest(override, 0);
      limited := true;
    end if;
  else
    select c.session_count_override, nullif(c.session_count_override_month, ''), c.membership_plan_id
      into override, override_month, slot
    from public.clients c
    where c.profile_id = p_client;
    if override is not null and slot = p_plan then
      if not (kind = 'membership' and override_month is not null and override_month <> month) then
        base := greatest(override, 0);
        limited := true;
      end if;
    end if;
  end if;

  if kind = 'membership'
     and enrollment is not null
     and enrollment->>'rolloverMonth' = month then
    rollover := greatest(coalesce((enrollment->>'rolloverSessions')::int, 0), 0);
    base := base + rollover;
    if rollover > 0 then
      limited := true;
    end if;
  end if;
  -- A plan with no session count stays unlimited. An override of 0 is a
  -- real cap: the client cannot book.
  if not limited then
    return null;
  end if;
  return greatest(base, 0);
end;
$$;

revoke all on function public.client_plan_allowance(uuid, text) from public, anon;
grant execute on function public.client_plan_allowance(uuid, text) to authenticated, service_role;

-- Same Pacific month as the allowance, so a session dated on the last
-- evening of the month is not counted in the next one.
create or replace function public.sessions_toward_booking_limit(
  p_client uuid,
  p_plan text,
  p_except uuid
)
returns integer
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  kind text;
  month text := to_char(timezone('America/Los_Angeles', now()), 'YYYY-MM');
  n integer;
begin
  select coalesce(data->>'kind', '') into kind
  from public.membership_plans where id = p_plan;

  select count(*) into n
  from public.bookings b
  where b.client_id = p_client
    and (p_except is null or b.id is distinct from p_except)
    and b.cancelled_at is null
    and coalesce(b.is_physical_assessment, false) = false
    and coalesce(b.attendance_status, '') not in ('early-cancel', 'late-cancel')
    and coalesce(b.plan_id, '') not like 'single:%'
    and b.plan_id = p_plan
    and (kind is distinct from 'membership' or to_char(b.date, 'YYYY-MM') = month);
  return coalesce(n, 0);
end;
$$;

revoke all on function public.sessions_toward_booking_limit(uuid, text, uuid) from public, anon;
grant execute on function public.sessions_toward_booking_limit(uuid, text, uuid) to authenticated, service_role;

-- 12:15am Pacific on the 1st. The clock stays on UTC, so the job wakes
-- hourly and only calls out during that Pacific hour, on that day.
-- The function rolls unused membership sessions and is safe to run twice.
do $$
declare
  existing bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_extension where extname = 'pg_net') then
    select jobid into existing from cron.job where jobname = 'membership-month-rollover';
    if existing is not null then
      perform cron.unschedule(existing);
    end if;
    perform cron.schedule(
      'membership-month-rollover',
      '15 * * * *',
      $cron$
      select net.http_post(
        url := 'https://rivhgutksyddeckieknc.supabase.co/functions/v1/rollover-membership-sessions',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select public.cron_vault_secret())
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 60000
      )
      where extract(hour from timezone('America/Los_Angeles', now())) = 0
        and extract(day from timezone('America/Los_Angeles', now())) = 1;
      $cron$
    );
  else
    raise notice 'pg_cron or pg_net is not enabled, so the membership rollover job was not scheduled. Enable both extensions, then run this file again.';
  end if;
end $$;

notify pgrst, 'reload schema';
