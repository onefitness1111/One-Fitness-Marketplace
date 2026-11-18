-- One grace booking for a coach while a client owes money.
-- Not applied to the live database by this change. Run it after
-- 20261119090000_thread_reads.sql.
--
-- The client still cannot book at all. A coach can add them to one session,
-- then no more, until the balance is back to zero. The owner can add them
-- any number of times and can waive the balance. The owner's bookings do
-- not use up the coach's one grace booking.

alter table public.clients
  add column if not exists grace_booking_used boolean not null default false;

comment on column public.clients.grace_booking_used is
  'True after a coach has used the one session they may add during this unpaid balance. Clears when the balance is no longer negative.';

-- A coach cannot flip this flag themselves. The booking trigger sets a
-- local flag for the one update it is allowed to make.
create or replace function public.clients_guard_billing()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  caller uuid := auth.uid();
  allowed boolean := auth.role() = 'service_role'
    or public.current_user_role() = 'owner'
    or caller = old.profile_id;
begin
  if current_setting('app.allow_grace', true) = '1' then
    new.stripe_customer_id := old.stripe_customer_id;
    new.stripe_subscription_id := old.stripe_subscription_id;
    new.stripe_schedule_id := old.stripe_schedule_id;
    new.pending_plan_price_id := old.pending_plan_price_id;
    new.billing_address := old.billing_address;
    new.billing_anchor_day := old.billing_anchor_day;
    new.balance_cents := old.balance_cents;
    new.has_outstanding_balance := old.has_outstanding_balance;
    new.outstanding_balance_cents := old.outstanding_balance_cents;
    new.outstanding_invoice_id := old.outstanding_invoice_id;
    new.outstanding_invoice_url := old.outstanding_invoice_url;
    new.outstanding_since := old.outstanding_since;
    return new;
  end if;
  if allowed then
    return new;
  end if;
  new.stripe_customer_id := old.stripe_customer_id;
  new.stripe_subscription_id := old.stripe_subscription_id;
  new.stripe_schedule_id := old.stripe_schedule_id;
  new.pending_plan_price_id := old.pending_plan_price_id;
  new.billing_address := old.billing_address;
  new.billing_anchor_day := old.billing_anchor_day;
  new.balance_cents := old.balance_cents;
  new.has_outstanding_balance := old.has_outstanding_balance;
  new.outstanding_balance_cents := old.outstanding_balance_cents;
  new.outstanding_invoice_id := old.outstanding_invoice_id;
  new.outstanding_invoice_url := old.outstanding_invoice_url;
  new.outstanding_since := old.outstanding_since;
  new.grace_booking_used := old.grace_booking_used;
  return new;
end;
$function$;

-- Back to zero, by payment, waive, or the owner editing the amount.
-- That starts a new unpaid period the next time a fee is recorded.
create or replace function public.reset_grace_when_balance_clear()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if coalesce(new.balance_cents, 0) >= 0 then
    new.grace_booking_used := false;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_reset_grace_when_balance_clear on public.clients;
create trigger trg_reset_grace_when_balance_clear
  before update of balance_cents on public.clients
  for each row
  when (coalesce(new.balance_cents, 0) >= 0)
  execute function public.reset_grace_when_balance_clear();

-- Amount and the grace flag. No phone, no street, no Stripe ids.
create or replace function public.client_booking_hold(p_client uuid)
returns table (balance_cents integer, grace_booking_used boolean)
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(c.balance_cents, 0), coalesce(c.grace_booking_used, false)
  from public.clients c
  where c.profile_id = p_client
    and (
      c.profile_id = auth.uid()
      or public.is_owner()
      or (public.current_user_role() = 'coach' and c.primary_trainer_id = auth.uid())
      or public.current_user_role() = 'coach'
    );
$$;

revoke all on function public.client_booking_hold(uuid) from public, anon;
grant execute on function public.client_booking_hold(uuid) to authenticated;

comment on function public.client_booking_hold(uuid) is
  'Balance and whether the coach grace booking is used. Coaches may read any client they are about to book. No phone or address.';

-- A coach on the schedule can book a client who is not their primary
-- client. The hold is only the amount and the grace flag, so any coach
-- or the owner can read it while adding someone to a session. The client
-- can read their own. The line above allows every coach. That is the
-- amount only.

create or replace function public.block_unpaid_balance_booking()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  owed integer;
  used boolean;
  dollars text;
  role text;
begin
  if auth.role() = 'service_role' and auth.uid() is null then
    return new;
  end if;

  select coalesce(balance_cents, 0), coalesce(grace_booking_used, false)
    into owed, used
  from public.clients
  where profile_id = new.client_id
  for update;

  if coalesce(owed, 0) >= 0 then
    return new;
  end if;

  dollars := to_char((-owed)::numeric / 100, 'FM999990.00');
  role := public.current_user_role();

  -- A waitlist row is not a session. Clients still cannot join one.
  -- Staff can. The grace booking is counted when a real booking is inserted.
  if tg_table_name = 'waitlist' then
    if auth.uid() = new.client_id or role is distinct from 'owner' and role is distinct from 'coach' then
      raise exception 'BALANCE_DUE: You have an outstanding balance of $%. Please pay your balance to book sessions.', dollars;
    end if;
    return new;
  end if;

  if role = 'owner' and auth.uid() is distinct from new.client_id then
    return new;
  end if;

  if role = 'coach' and auth.uid() is distinct from new.client_id then
    if used then
      raise exception 'BALANCE_GRACE_USED: This client has an outstanding balance of $%.', dollars;
    end if;
    return new;
  end if;

  raise exception 'BALANCE_DUE: You have an outstanding balance of $%. Please pay your balance to book sessions.', dollars;
end;
$$;

create or replace function public.mark_grace_booking()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if public.current_user_role() is distinct from 'coach' then
    return new;
  end if;
  if auth.uid() is not distinct from new.client_id then
    return new;
  end if;
  perform set_config('app.allow_grace', '1', true);
  update public.clients
     set grace_booking_used = true
   where profile_id = new.client_id
     and coalesce(balance_cents, 0) < 0
     and grace_booking_used = false;
  return new;
end;
$$;

drop trigger if exists trg_mark_grace_booking on public.bookings;
create trigger trg_mark_grace_booking
  after insert on public.bookings
  for each row
  execute function public.mark_grace_booking();

drop policy if exists bookings_block_negative_balance on public.bookings;
create policy bookings_block_negative_balance
  on public.bookings
  as restrictive
  for insert
  to authenticated
  with check (
    (
      public.current_user_role() = 'owner'
      and client_id is distinct from auth.uid()
    )
    or (
      public.current_user_role() = 'coach'
      and client_id is distinct from auth.uid()
      and (
        coalesce((select c.balance_cents from public.clients c where c.profile_id = client_id), 0) >= 0
        or not coalesce((select c.grace_booking_used from public.clients c where c.profile_id = client_id), false)
      )
    )
    or (
      client_id = auth.uid()
      and coalesce((select c.balance_cents from public.clients c where c.profile_id = client_id), 0) >= 0
    )
  );

-- The booking RPC uses the same rule before it inserts.
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
  owed integer;
  grace_used boolean;
  dollars text;
  caller_role text;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_trainer_id::text || p_date::text || p_slot::text, 0));
  select * into c from public.single_session_credits where id = p_credit_id for update;
  if not found then return jsonb_build_object('status', 'error', 'message', 'Credit not found.'); end if;
  if c.status = 'refunded' then return jsonb_build_object('status', 'error', 'message', 'This session was refunded.'); end if;
  if c.booking_id is not null then
    return jsonb_build_object('status', 'booked', 'booking_id', c.booking_id);
  end if;

  select coalesce(balance_cents, 0), coalesce(grace_booking_used, false)
    into owed, grace_used
  from public.clients
  where profile_id = c.client_id;
  caller_role := public.current_user_role();
  if coalesce(owed, 0) < 0 then
    dollars := to_char((-owed)::numeric / 100, 'FM999990.00');
    if auth.uid() = c.client_id or caller_role = 'client' then
      return jsonb_build_object(
        'status', 'error',
        'code', 'BALANCE_DUE',
        'message', 'BALANCE_DUE: You have an outstanding balance of $' || dollars || '. Please pay your balance to book sessions.'
      );
    end if;
    if caller_role = 'coach' and grace_used then
      return jsonb_build_object(
        'status', 'error',
        'code', 'BALANCE_GRACE_USED',
        'message', 'BALANCE_GRACE_USED: This client has an outstanding balance of $' || dollars || '.'
      );
    end if;
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

  return jsonb_build_object('status', 'booked', 'booking_id', new_id);
end;
$function$;
