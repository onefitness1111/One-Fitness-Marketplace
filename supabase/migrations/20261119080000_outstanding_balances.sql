-- Unpaid late-cancel and no-show fees.
-- Not applied to the live database by this change. Run it in the SQL editor
-- when this update goes live, after 20261119070000_coach_contact_privacy.sql,
-- and before 20261119090000_thread_reads.sql.
--
-- A fee that cannot be collected (no card, a decline, or a bank check the
-- client never finishes) is an unpaid ledger row and a negative balance.
-- The client cannot book while that balance is below zero. Paying or an
-- owner waive clears it. Coaches can read the amount for their own clients
-- and nothing else.

create table if not exists public.client_balance_ledger (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles (id) on delete cascade,
  fee_type text not null,
  amount_cents integer not null,
  booking_id uuid,
  created_by uuid,
  status text not null default 'unpaid',
  stripe_payment_intent_id text,
  stripe_payment_method_id text,
  stripe_charge_id text,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  waived_by uuid,
  waived_at timestamptz,
  constraint client_balance_ledger_type check (fee_type in ('late', 'close', 'noshow')),
  constraint client_balance_ledger_amount check (amount_cents > 0),
  constraint client_balance_ledger_status check (status in ('unpaid', 'paid', 'waived'))
);

create unique index if not exists client_balance_ledger_one_booking
  on public.client_balance_ledger (booking_id)
  where booking_id is not null and status <> 'waived';

create index if not exists client_balance_ledger_client_idx
  on public.client_balance_ledger (client_id, status);

comment on table public.client_balance_ledger is
  'One row per late-cancel or no-show fee. Unpaid rows are the negative balance. Stripe ids are filled when a card is tried or when the client pays.';

alter table public.client_balance_ledger enable row level security;

revoke all on table public.client_balance_ledger from public, anon, authenticated;

-- The client sees their own rows. The owner sees every row. A coach sees
-- the amount for their own clients and none of the Stripe ids.
create or replace function public.client_ledger_for(p_client uuid)
returns table (
  id uuid,
  fee_type text,
  amount_cents integer,
  booking_id uuid,
  created_by uuid,
  status text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    l.id,
    l.fee_type,
    l.amount_cents,
    l.booking_id,
    l.created_by,
    l.status,
    l.created_at
  from public.client_balance_ledger l
  join public.clients c on c.profile_id = l.client_id
  where l.client_id = p_client
    and (
      l.client_id = auth.uid()
      or public.is_owner()
      or (public.current_user_role() = 'coach' and c.primary_trainer_id = auth.uid())
    );
$$;

revoke all on function public.client_ledger_for(uuid) from public, anon;
grant execute on function public.client_ledger_for(uuid) to authenticated;

-- Amount only. No phone, no street, no Stripe customer.
create or replace function public.client_balances_for(p_ids uuid[])
returns table (profile_id uuid, balance_cents integer)
language sql
stable
security definer
set search_path to 'public'
as $$
  select c.profile_id, coalesce(c.balance_cents, 0)
  from public.clients c
  where c.profile_id = any (coalesce(p_ids, array[]::uuid[]))
    and (
      c.profile_id = auth.uid()
      or public.is_owner()
      or (public.current_user_role() = 'coach' and c.primary_trainer_id = auth.uid())
    );
$$;

revoke all on function public.client_balances_for(uuid[]) from public, anon;
grant execute on function public.client_balances_for(uuid[]) to authenticated;

-- In-app notice when a balance is added. The phone push is sent by the
-- edge function that records the fee.
alter table public.client_notices drop constraint if exists client_notices_kind;
alter table public.client_notices
  add constraint client_notices_kind
  check (kind in ('package_discount', 'package_full', 'package_confirmed', 'balance_due'));

create or replace function public.record_unpaid_fee(
  p_client uuid,
  p_type text,
  p_amount_cents integer,
  p_booking uuid,
  p_created_by uuid,
  p_stripe_payment_intent text,
  p_stripe_payment_method text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  existing uuid;
  new_id uuid;
  new_balance integer;
  dollars text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the server can record a fee.';
  end if;
  if p_client is null then
    raise exception 'Choose a client.';
  end if;
  if p_type not in ('late', 'close', 'noshow') then
    raise exception 'That is not a session fee.';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'The fee amount is missing.';
  end if;

  if p_booking is not null then
    select id into existing
    from public.client_balance_ledger
    where booking_id = p_booking
      and status <> 'waived'
    limit 1;
    if existing is not null then
      select coalesce(balance_cents, 0) into new_balance
      from public.clients where profile_id = p_client;
      return jsonb_build_object(
        'ledgerId', existing,
        'balanceCents', coalesce(new_balance, 0),
        'amountCents', p_amount_cents,
        'alreadyRecorded', true
      );
    end if;
  end if;

  insert into public.client_balance_ledger (
    client_id, fee_type, amount_cents, booking_id, created_by, status,
    stripe_payment_intent_id, stripe_payment_method_id
  ) values (
    p_client, p_type, p_amount_cents, p_booking, p_created_by, 'unpaid',
    nullif(p_stripe_payment_intent, ''), nullif(p_stripe_payment_method, '')
  )
  returning id into new_id;

  update public.clients
     set balance_cents = coalesce(balance_cents, 0) - p_amount_cents
   where profile_id = p_client
  returning balance_cents into new_balance;

  dollars := to_char((abs(coalesce(new_balance, 0)))::numeric / 100, 'FM999990.00');
  insert into public.client_notices (client_id, kind, plan_id, title, body)
  values (
    p_client,
    'balance_due',
    new_id::text,
    'Outstanding balance',
    'You have an outstanding balance of $' || dollars || '. Please pay your balance to book sessions.'
  );

  return jsonb_build_object(
    'ledgerId', new_id,
    'balanceCents', coalesce(new_balance, 0),
    'amountCents', p_amount_cents,
    'alreadyRecorded', false
  );
end;
$$;

revoke all on function public.record_unpaid_fee(uuid, text, integer, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.record_unpaid_fee(uuid, text, integer, uuid, uuid, text, text) to service_role;

create or replace function public.settle_ledger_paid(
  p_id uuid,
  p_payment_intent text,
  p_payment_method text
)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  row public.client_balance_ledger%rowtype;
  new_balance integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the server can mark a fee paid.';
  end if;
  select * into row from public.client_balance_ledger where id = p_id for update;
  if not found then
    raise exception 'That fee was not found.';
  end if;
  if row.status = 'unpaid' then
    update public.client_balance_ledger
       set status = 'paid',
           paid_at = now(),
           stripe_payment_intent_id = coalesce(nullif(p_payment_intent, ''), stripe_payment_intent_id),
           stripe_payment_method_id = coalesce(nullif(p_payment_method, ''), stripe_payment_method_id)
     where id = row.id;
    update public.clients
       set balance_cents = coalesce(balance_cents, 0) + row.amount_cents
     where profile_id = row.client_id
    returning balance_cents into new_balance;
  else
    select coalesce(balance_cents, 0) into new_balance
    from public.clients where profile_id = row.client_id;
  end if;
  return coalesce(new_balance, 0);
end;
$$;

revoke all on function public.settle_ledger_paid(uuid, text, text) from public, anon, authenticated;
grant execute on function public.settle_ledger_paid(uuid, text, text) to service_role;

-- The client paid the whole negative balance. Every unpaid row is paid.
create or replace function public.apply_balance_payment(
  p_client uuid,
  p_amount_cents integer,
  p_payment_intent text,
  p_payment_method text
)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  new_balance integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the server can apply a balance payment.';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Nothing was paid.';
  end if;

  update public.client_balance_ledger
     set status = 'paid',
         paid_at = now(),
         stripe_payment_intent_id = coalesce(nullif(p_payment_intent, ''), stripe_payment_intent_id),
         stripe_payment_method_id = coalesce(nullif(p_payment_method, ''), stripe_payment_method_id)
   where client_id = p_client
     and status = 'unpaid';

  update public.clients
     set balance_cents = coalesce(balance_cents, 0) + p_amount_cents
   where profile_id = p_client
  returning balance_cents into new_balance;

  return coalesce(new_balance, 0);
end;
$$;

revoke all on function public.apply_balance_payment(uuid, integer, text, text) from public, anon, authenticated;
grant execute on function public.apply_balance_payment(uuid, integer, text, text) to service_role;

create or replace function public.waive_client_balance(p_client uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  new_balance integer;
begin
  if public.current_user_role() is distinct from 'owner' then
    raise exception 'Only the owner can waive a balance.';
  end if;
  update public.client_balance_ledger
     set status = 'waived',
         waived_by = auth.uid(),
         waived_at = now()
   where client_id = p_client
     and status = 'unpaid';
  update public.clients
     set balance_cents = greatest(coalesce(balance_cents, 0), 0)
   where profile_id = p_client
  returning balance_cents into new_balance;
  return coalesce(new_balance, 0);
end;
$$;

revoke all on function public.waive_client_balance(uuid) from public, anon;
grant execute on function public.waive_client_balance(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- The client cannot book, join a waitlist, or start a recurring series
-- while their balance is below zero. A coach or the owner placing them on
-- a session is still allowed. Direct inserts are refused by the trigger and
-- by a restrictive policy.
-- ---------------------------------------------------------------------------

create or replace function public.block_unpaid_balance_booking()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  owed integer;
  dollars text;
begin
  if auth.uid() is not null
     and public.current_user_role() in ('owner', 'coach')
     and auth.uid() is distinct from new.client_id then
    return new;
  end if;
  if auth.role() = 'service_role' and auth.uid() is null then
    return new;
  end if;
  select coalesce(balance_cents, 0) into owed
  from public.clients
  where profile_id = new.client_id;
  if coalesce(owed, 0) < 0 then
    dollars := to_char((-owed)::numeric / 100, 'FM999990.00');
    raise exception 'BALANCE_DUE: You have an outstanding balance of $%. Please pay your balance to book sessions.', dollars;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_block_unpaid_balance_booking on public.bookings;
create trigger trg_block_unpaid_balance_booking
  before insert on public.bookings
  for each row
  execute function public.block_unpaid_balance_booking();

drop policy if exists bookings_block_negative_balance on public.bookings;
create policy bookings_block_negative_balance
  on public.bookings
  as restrictive
  for insert
  to authenticated
  with check (
        client_id is distinct from auth.uid()
        or coalesce((select c.balance_cents from public.clients c where c.profile_id = client_id), 0) >= 0
  );

do $$
begin
  if to_regclass('public.waitlist') is null then
    return;
  end if;
  execute 'drop trigger if exists trg_block_unpaid_balance_waitlist on public.waitlist';
  execute 'create trigger trg_block_unpaid_balance_waitlist before insert on public.waitlist for each row execute function public.block_unpaid_balance_booking()';
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
        with check (
          client_id is distinct from auth.uid()
          or coalesce((select c.balance_cents from public.clients c where c.profile_id = waitlist.client_id), 0) >= 0
        )
    $policy$;
  end if;
end $$;

-- book_single_session is the booking RPC. The same balance rule runs before
-- it inserts, so a client cannot spend a single-session credit while they owe.
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
  dollars text;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_trainer_id::text || p_date::text || p_slot::text, 0));
  select * into c from public.single_session_credits where id = p_credit_id for update;
  if not found then return jsonb_build_object('status', 'error', 'message', 'Credit not found.'); end if;
  if c.status = 'refunded' then return jsonb_build_object('status', 'error', 'message', 'This session was refunded.'); end if;
  if c.booking_id is not null then
    return jsonb_build_object('status', 'booked', 'booking_id', c.booking_id);
  end if;

  select coalesce(balance_cents, 0) into owed from public.clients where profile_id = c.client_id;
  if coalesce(owed, 0) < 0
     and (auth.uid() = c.client_id or public.current_user_role() = 'client') then
    dollars := to_char((-owed)::numeric / 100, 'FM999990.00');
    return jsonb_build_object(
      'status', 'error',
      'code', 'BALANCE_DUE',
      'message', 'BALANCE_DUE: You have an outstanding balance of $' || dollars || '. Please pay your balance to book sessions.'
    );
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
      if sqlerrm like '%BALANCE_DUE%' then
        return jsonb_build_object('status', 'error', 'code', 'BALANCE_DUE', 'message', sqlerrm);
      end if;
      if sqlerrm like '%capacity%' or sqlerrm like '%overlaps%' or sqlerrm like '%restricted%' then
        return jsonb_build_object('status', 'full', 'message', sqlerrm);
      end if;
      return jsonb_build_object('status', 'error', 'message', sqlerrm);
  end;

  return jsonb_build_object('status', 'booked', 'booking_id', new_id);
end;
$function$;
