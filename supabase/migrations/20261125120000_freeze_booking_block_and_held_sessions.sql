-- Membership freeze: server-side booking block (C6) and held sessions.
--
-- Review only. Not applied to the live database until you run it.
-- Safe to run more than once. Does not change any rows.
--
-- 1. client_frozen_until(client, day): the day a freeze covering [day] ends,
--    or null when [day] is not frozen. It reads the freeze on the client row
--    (running now, or scheduled by the owner for a later start day) and
--    freeze requests the owner approved that have not started yet.
--    A freeze covers its start day up to, not including, its end day.
--
-- 2. block_frozen_client_booking: a booking for a frozen day is refused,
--    whoever makes it: the client app, a coach, a recurring series, or an
--    edge function. Only the owner can still book a frozen day. Cancelled
--    rows and rows that keep their date are not checked.
--
-- 3. Held sessions. When a freeze starts, each active membership entry in
--    clients.plans gets heldSessions, frozenFrom, heldFrom and heldUntil
--    (written by the freeze edge functions). From heldFrom (the end day) up
--    to heldUntil (the next billing day) the client's allowance on that plan
--    is heldSessions plus any sessions rolled into this month, and only
--    bookings dated in that window count against it. Outside the window the
--    monthly count leaves out bookings dated in it, so the normal allowance
--    starts fresh on the billing day.
--
-- Coaches and the owner still skip the allowance check, same as before.
-- Nothing here reads or depends on the old coach-assignment field.

create or replace function public.client_frozen_until(p_client uuid, p_day date)
returns date
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  paused boolean;
  from_day date;
  until_day date;
  req_until date;
begin
  if p_client is null or p_day is null then
    return null;
  end if;

  select coalesce(c.membership_paused, false),
         nullif(c.membership_paused_at::text, '')::date,
         nullif(c.membership_freeze_ends_at::text, '')::date
    into paused, from_day, until_day
  from public.clients c
  where c.profile_id = p_client;

  if found and (paused or from_day is not null) then
    if (from_day is null or p_day >= from_day)
       and (until_day is null or p_day < until_day) then
      return coalesce(until_day, 'infinity'::date);
    end if;
  end if;

  select max((r.payload->>'to')::date)
    into req_until
  from public.coach_requests r
  where r.client_id = p_client
    and r.kind = 'freeze_membership'
    and r.status = 'approved'
    and r.applied_at is null
    and coalesce(r.payload->>'from', '') ~ '^\d{4}-\d{2}-\d{2}$'
    and coalesce(r.payload->>'to', '') ~ '^\d{4}-\d{2}-\d{2}$'
    and p_day >= (r.payload->>'from')::date
    and p_day < (r.payload->>'to')::date;

  return req_until;
end;
$$;

revoke all on function public.client_frozen_until(uuid, date) from public, anon;
grant execute on function public.client_frozen_until(uuid, date) to authenticated, service_role;

create or replace function public.block_frozen_client_booking()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  until_day date;
  when_text text;
begin
  if new.cancelled_at is not null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.date is not distinct from old.date
     and new.client_id is not distinct from old.client_id
     and old.cancelled_at is null then
    return new;
  end if;
  -- The owner is the only one who can still book a frozen day.
  if auth.role() is distinct from 'service_role'
     and public.current_user_role() = 'owner' then
    return new;
  end if;

  until_day := public.client_frozen_until(new.client_id, new.date);
  if until_day is null then
    return new;
  end if;

  if until_day = 'infinity'::date then
    if auth.uid() = new.client_id then
      raise exception using
        message = 'Your account is frozen. Message ONE Fitness to resume it.',
        hint = 'membership-frozen';
    end if;
    raise exception using
      message = 'This client''s account is frozen, so they can''t be booked.',
      hint = 'membership-frozen';
  end if;

  when_text := to_char(until_day, 'FMMon FMDD');
  if auth.uid() = new.client_id then
    raise exception using
      message = format('Your account is frozen until %s. You can book sessions starting that day.', when_text),
      hint = 'membership-frozen';
  end if;
  raise exception using
    message = format('This client''s account is frozen until %s. They can be booked starting that day.', when_text),
    hint = 'membership-frozen';
end;
$$;

drop trigger if exists block_frozen_client_booking on public.bookings;
create trigger block_frozen_client_booking
  before insert or update of date, client_id, cancelled_at
  on public.bookings
  for each row
  execute function public.block_frozen_client_booking();

-- The held-sessions window on this client's active entry for [p_plan], or
-- nulls when there is none.
create or replace function public.client_plan_hold(
  p_client uuid,
  p_plan text,
  out held integer,
  out held_from date,
  out held_until date
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  enrollment jsonb;
begin
  select e into enrollment
  from public.clients c
  cross join lateral jsonb_array_elements(coalesce(c.plans, '[]'::jsonb)) e
  where c.profile_id = p_client
    and e->>'planId' = p_plan
    and coalesce(e->>'status', '') = 'active'
  limit 1;

  if enrollment is null
     or coalesce(enrollment->>'heldFrom', '') !~ '^\d{4}-\d{2}-\d{2}$'
     or coalesce(enrollment->>'heldUntil', '') !~ '^\d{4}-\d{2}-\d{2}$' then
    return;
  end if;
  held := greatest(coalesce(nullif(enrollment->>'heldSessions', '')::int, 0), 0);
  held_from := (enrollment->>'heldFrom')::date;
  held_until := (enrollment->>'heldUntil')::date;
end;
$$;

revoke all on function public.client_plan_hold(uuid, text) from public, anon;
grant execute on function public.client_plan_hold(uuid, text) to authenticated, service_role;

-- Same as 20261122120000_membership_rollover.sql, plus the held window.
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
  today date := timezone('America/Los_Angeles', now())::date;
  rollover integer := 0;
  h_held integer;
  h_from date;
  h_until date;
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

  if kind = 'membership'
     and enrollment is not null
     and enrollment->>'rolloverMonth' = month then
    rollover := greatest(coalesce((enrollment->>'rolloverSessions')::int, 0), 0);
  end if;

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

  -- Sessions held through a freeze replace the monthly count until the
  -- next billing day. Rolled sessions for this month still count on top.
  -- An unlimited plan stays unlimited.
  if kind = 'membership' and limited then
    select h.held, h.held_from, h.held_until into h_held, h_from, h_until
    from public.client_plan_hold(p_client, p_plan) h;
    if h_from is not null and today >= h_from and today < h_until then
      return greatest(h_held, 0) + rollover;
    end if;
  end if;

  base := base + rollover;
  if rollover > 0 then
    limited := true;
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

-- Same as 20261122120000_membership_rollover.sql, plus the held window.
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
  today date := timezone('America/Los_Angeles', now())::date;
  h_from date;
  h_until date;
  in_hold boolean := false;
  n integer;
begin
  select coalesce(data->>'kind', '') into kind
  from public.membership_plans where id = p_plan;

  if kind = 'membership' then
    select h.held_from, h.held_until into h_from, h_until
    from public.client_plan_hold(p_client, p_plan) h;
    in_hold := h_from is not null and today >= h_from and today < h_until;
  end if;

  select count(*) into n
  from public.bookings b
  where b.client_id = p_client
    and (p_except is null or b.id is distinct from p_except)
    and b.cancelled_at is null
    and coalesce(b.is_physical_assessment, false) = false
    and coalesce(b.attendance_status, '') not in ('early-cancel', 'late-cancel')
    and coalesce(b.plan_id, '') not like 'single:%'
    and b.plan_id = p_plan
    and (
      kind is distinct from 'membership'
      or (in_hold and b.date >= h_from and b.date < h_until)
      or (
        not in_hold
        and to_char(b.date, 'YYYY-MM') = month
        and not (h_from is not null and b.date >= h_from and b.date < h_until)
      )
    );
  return coalesce(n, 0);
end;
$$;

revoke all on function public.sessions_toward_booking_limit(uuid, text, uuid) from public, anon;
grant execute on function public.sessions_toward_booking_limit(uuid, text, uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
