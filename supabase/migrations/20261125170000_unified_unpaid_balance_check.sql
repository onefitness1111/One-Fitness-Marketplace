-- O4: Replace the overlapping unpaid-balance checks (two triggers, two RLS
-- policies, book_single_session inline check, and separate read helpers) with
-- ONE shared unpaid-balance rule used everywhere.
-- Not applied to the live database by this change.
--
-- Behavior preserved:
--   * Clients cannot book or join a waitlist while balance_cents < 0 (BALANCE_DUE).
--   * Owner can always override the balance block (for bookings and waitlists)
--     without consuming the coach's grace booking.
--   * Coaches keep their one-time grace booking for a client who owes money;
--     a second booking by a coach while still unpaid is blocked (BALANCE_GRACE_USED).
--   * Staff adding a client to a waitlist does not consume the grace booking.
--   * Paid single-session purchases (purchase / staff_charge) already include and
--     settle the unpaid balance on the card charge, so they are not blocked.
--   * No automatic late-cancel/no-show fee charging is added.

-- 1. The single canonical decision rule. Every trigger, policy, RPC, and edge
--    function routes through this logic so messages and rules cannot drift.
create or replace function public.unpaid_balance_rule(
  p_balance_cents integer,
  p_grace_used boolean,
  p_client uuid,
  p_actor_id uuid,
  p_actor_role text,
  p_target text default 'booking'
)
returns table (
  allowed boolean,
  code text,
  message text,
  consume_grace boolean,
  can_override boolean
)
language plpgsql
immutable
set search_path = public
as $$
declare
  owed integer := coalesce(p_balance_cents, 0);
  used boolean := coalesce(p_grace_used, false);
  target text := coalesce(nullif(lower(trim(p_target)), ''), 'booking');
  dollars text;
begin
  if owed >= 0 then
    return query select true, 'OK'::text, null::text, false, false;
    return;
  end if;

  dollars := to_char((-owed)::numeric / 100, 'FM999990.00');

  -- Waitlist: staff can add a client without consuming the coach grace booking.
  if target = 'waitlist' then
    if p_actor_role in ('owner', 'coach') and p_actor_id is distinct from p_client then
      return query select true, 'OK'::text, null::text, false, true;
      return;
    end if;
    return query select
      false,
      'BALANCE_DUE'::text,
      'You have an outstanding balance of $' || dollars || '. Please pay your balance to book sessions.',
      false,
      false;
    return;
  end if;

  -- Booking: owner always overrides; coach gets one grace booking per unpaid period.
  if p_actor_role = 'owner' and p_actor_id is distinct from p_client then
    return query select
      true,
      'BALANCE_OWNER_OVERRIDE'::text,
      'This client has an outstanding balance of $' || dollars || '.',
      false,
      true;
    return;
  end if;

  if p_actor_role = 'coach' and p_actor_id is distinct from p_client then
    if used then
      return query select
        false,
        'BALANCE_GRACE_USED'::text,
        'This client has an outstanding balance of $' || dollars || '.',
        false,
        false;
      return;
    end if;
    return query select
      true,
      'BALANCE_COACH_GRACE'::text,
      'This client has an outstanding balance of $' || dollars || '.',
      true,
      true;
    return;
  end if;

  return query select
    false,
    'BALANCE_DUE'::text,
    'You have an outstanding balance of $' || dollars || '. Please pay your balance to book sessions.',
    false,
    false;
end;
$$;

revoke all on function public.unpaid_balance_rule(integer, boolean, uuid, uuid, text, text) from public, anon;
grant execute on function public.unpaid_balance_rule(integer, boolean, uuid, uuid, text, text) to authenticated, service_role;

-- 2. The single table-reading RPC used by the app, Edge Functions, and RLS.
--    Signed-in callers always evaluate as themselves (auth.uid() /
--    current_user_role()); only pure service_role callers may pass an actor.
create or replace function public.check_booking_balance(
  p_client uuid,
  p_target text default 'booking',
  p_actor_id uuid default null,
  p_actor_role text default null
)
returns table (
  allowed boolean,
  code text,
  message text,
  balance_cents integer,
  grace_booking_used boolean,
  consume_grace boolean,
  can_override boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  eff_actor_id uuid;
  eff_actor_role text;
  owed integer := 0;
  used boolean := false;
begin
  if auth.role() = 'service_role' and auth.uid() is null then
    eff_actor_id := p_actor_id;
    eff_actor_role := nullif(trim(coalesce(p_actor_role, '')), '');
    if eff_actor_role is null and eff_actor_id is not null then
      select p.role into eff_actor_role from public.profiles p where p.id = eff_actor_id;
    end if;
  else
    eff_actor_id := auth.uid();
    eff_actor_role := public.current_user_role();
    if p_client is distinct from eff_actor_id
       and eff_actor_role is distinct from 'owner'
       and eff_actor_role is distinct from 'coach' then
      return query select false, 'NOT_AUTHORIZED'::text, 'Not authorized.'::text, null::integer, null::boolean, false, false;
      return;
    end if;
  end if;

  select coalesce(c.balance_cents, 0), coalesce(c.grace_booking_used, false)
    into owed, used
  from public.clients c
  where c.profile_id = p_client;

  if not found then
    owed := 0;
    used := false;
  end if;

  return query
    select r.allowed, r.code, r.message, owed, used, r.consume_grace, r.can_override
    from public.unpaid_balance_rule(owed, used, p_client, eff_actor_id, eff_actor_role, p_target) r;
end;
$$;

revoke all on function public.check_booking_balance(uuid, text, uuid, text) from public, anon;
grant execute on function public.check_booking_balance(uuid, text, uuid, text) to authenticated, service_role;

comment on function public.check_booking_balance(uuid, text, uuid, text) is
  'O4: Single shared unpaid-balance check used by the app, Edge Functions, RLS policies, and triggers. No phone or billing address.';

-- 3. Thin boolean wrapper for RLS policies, plus legacy compatibility wrappers
--    delegating to the shared check so nothing duplicates the rule.
create or replace function public.booking_balance_allowed(
  p_client uuid,
  p_target text default 'booking'
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select b.allowed
    from public.check_booking_balance(p_client, p_target) b
    limit 1
  ), false);
$$;

revoke all on function public.booking_balance_allowed(uuid, text) from public, anon;
grant execute on function public.booking_balance_allowed(uuid, text) to authenticated, service_role;

create or replace function public.client_booking_hold(p_client uuid)
returns table (balance_cents integer, grace_booking_used boolean)
language sql
stable
security definer
set search_path = public
as $$
  select b.balance_cents, b.grace_booking_used
  from public.check_booking_balance(p_client, 'booking') b
  where b.balance_cents is not null;
$$;

revoke all on function public.client_booking_hold(uuid) from public, anon;
grant execute on function public.client_booking_hold(uuid) to authenticated, service_role;

create or replace function public.client_balance_ok(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select b.balance_cents >= 0
    from public.check_booking_balance(p_client, 'booking') b
    where b.balance_cents is not null
  ), true);
$$;

create or replace function public.client_grace_unused(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not coalesce((
    select b.grace_booking_used
    from public.check_booking_balance(p_client, 'booking') b
    where b.balance_cents is not null
  ), false);
$$;

revoke all on function public.client_balance_ok(uuid) from public, anon;
revoke all on function public.client_grace_unused(uuid) from public, anon;
grant execute on function public.client_balance_ok(uuid) to authenticated;
grant execute on function public.client_grace_unused(uuid) to authenticated;

-- 4. RLS policies on bookings and waitlist delegate to the single shared check.
drop policy if exists bookings_block_negative_balance on public.bookings;
create policy bookings_block_negative_balance
  on public.bookings
  as restrictive
  for insert
  to authenticated
  with check (public.booking_balance_allowed(client_id, 'booking'));

do $$
begin
  if to_regclass('public.waitlist') is null then
    return;
  end if;
  if exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'waitlist' and c.relrowsecurity
  ) then
    execute 'drop policy if exists waitlist_block_negative_balance on public.waitlist';
    execute $policy$
      create policy waitlist_block_negative_balance
        on public.waitlist
        as restrictive
        for insert
        to authenticated
        with check (public.booking_balance_allowed(client_id, 'waitlist'))
    $policy$;
  end if;
end $$;

-- 5. Single BEFORE INSERT trigger function for both bookings and waitlist,
--    locking the client row FOR UPDATE and calling unpaid_balance_rule.
create or replace function public.block_unpaid_balance_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  owed integer := 0;
  used boolean := false;
  r record;
  target text;
begin
  -- Pure service_role calls (book_single_session / webhooks) already enforce
  -- the shared rule explicitly so paid single sessions can settle the balance.
  if auth.role() = 'service_role' and auth.uid() is null then
    return new;
  end if;

  select coalesce(c.balance_cents, 0), coalesce(c.grace_booking_used, false)
    into owed, used
  from public.clients c
  where c.profile_id = new.client_id
  for update;

  if not found then
    owed := 0;
    used := false;
  end if;

  target := case when tg_table_name = 'waitlist' then 'waitlist' else 'booking' end;

  select * into r
  from public.unpaid_balance_rule(owed, used, new.client_id, auth.uid(), public.current_user_role(), target);

  if not r.allowed then
    raise exception '%: %', r.code, r.message;
  end if;

  return new;
end;
$$;

revoke all on function public.block_unpaid_balance_booking() from public, anon;
grant execute on function public.block_unpaid_balance_booking() to authenticated, service_role;

-- 6. book_single_session uses the exact same rule (with FOR UPDATE lock) for
--    unpaid single-session bookings and consumes the coach's grace atomically
--    once the insert succeeds. Paid single sessions (purchase / staff_charge)
--    collect and settle the balance in the same payment, so they bypass it.
create or replace function public.book_single_session(
  p_credit_id uuid,
  p_trainer_id uuid,
  p_date date,
  p_slot integer,
  p_session_type text,
  p_discipline text,
  p_location_name text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  c public.single_session_credits%rowtype;
  new_id uuid := gen_random_uuid();
  creator_role text;
  week_start date;
  used_count integer;
  pay_it boolean := true;
  owed integer := 0;
  grace_used boolean := false;
  eff_actor_id uuid;
  eff_actor_role text;
  bal_check record;
  should_consume_grace boolean := false;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_trainer_id::text || p_date::text || p_slot::text, 0));
  select * into c from public.single_session_credits where id = p_credit_id for update;
  if not found then return jsonb_build_object('status', 'error', 'message', 'Credit not found.'); end if;
  if c.status = 'refunded' then return jsonb_build_object('status', 'error', 'message', 'This session was refunded.'); end if;
  if c.booking_id is not null then
    return jsonb_build_object('status', 'booked', 'booking_id', c.booking_id);
  end if;

  if c.source not in ('purchase', 'staff_charge') then
    select coalesce(cl.balance_cents, 0), coalesce(cl.grace_booking_used, false)
      into owed, grace_used
    from public.clients cl
    where cl.profile_id = c.client_id
    for update;

    if not found then
      owed := 0;
      grace_used := false;
    end if;

    if auth.uid() is not null then
      eff_actor_id := auth.uid();
      eff_actor_role := public.current_user_role();
    elsif c.source = 'staff_free' and c.created_by is not null then
      select p.role into creator_role from public.profiles p where p.id = c.created_by;
      eff_actor_id := c.created_by;
      eff_actor_role := creator_role;
    else
      eff_actor_id := c.client_id;
      eff_actor_role := 'client';
    end if;

    select * into bal_check
    from public.unpaid_balance_rule(owed, grace_used, c.client_id, eff_actor_id, eff_actor_role, 'booking');

    if not bal_check.allowed then
      return jsonb_build_object(
        'status', 'error',
        'code', bal_check.code,
        'message', bal_check.code || ': ' || bal_check.message
      );
    end if;
    should_consume_grace := coalesce(bal_check.consume_grace, false);
  end if;

  if c.source = 'staff_free' then
    pay_it := false;
    select role into creator_role from public.profiles where id = c.created_by;
    if creator_role is distinct from 'owner' then
      week_start := date_trunc('week', timezone('America/Los_Angeles', now()))::date;
      select count(*) into used_count
      from public.single_session_credits sc
      join public.bookings b on b.plan_id = 'single:' || sc.id::text
      where sc.source = 'staff_free'
        and sc.created_by = c.created_by
        and sc.id <> c.id
        and sc.purchased_at >= (week_start::timestamp at time zone 'America/Los_Angeles')
        and sc.purchased_at < ((week_start + 7)::timestamp at time zone 'America/Los_Angeles');
      if used_count >= 1 then
        return jsonb_build_object(
          'status', 'error',
          'code', 'FREE_ADD_LIMIT',
          'message', 'This coach already used the one free session add for this week. Ask the owner to approve another.'
        );
      end if;
    end if;
  end if;

  begin
    insert into public.bookings (
      id, client_id, trainer_id, date, slot_min, session_type, discipline, location, plan_id, counts_toward_pay
    )
    values (
      new_id, c.client_id, p_trainer_id, p_date, p_slot, p_session_type, p_discipline,
      case when p_location_name is null or p_location_name = '' then null else jsonb_build_object('name', p_location_name) end,
      'single:' || p_credit_id::text,
      pay_it
    );
  exception
    when others then
      if sqlerrm like '%BALANCE_GRACE_USED%' or sqlerrm like '%BALANCE_DUE%' then
        return jsonb_build_object('status', 'error', 'code', case when sqlerrm like '%BALANCE_GRACE_USED%' then 'BALANCE_GRACE_USED' else 'BALANCE_DUE' end, 'message', sqlerrm);
      end if;
      if sqlerrm like '%capacity%' or sqlerrm like '%overlaps%' or sqlerrm like '%restricted%' then
        return jsonb_build_object('status', 'full', 'message', sqlerrm);
      end if;
      return jsonb_build_object('status', 'error', 'message', sqlerrm);
  end;

  if should_consume_grace then
    perform set_config('app.allow_grace', '1', true);
    update public.clients
       set grace_booking_used = true
     where profile_id = c.client_id
       and coalesce(balance_cents, 0) < 0
       and grace_booking_used = false;
  end if;

  return jsonb_build_object('status', 'booked', 'booking_id', new_id);
end;
$function$;
